# Signalen (signalen.org): API, workers and frontend from the upstream
# container images; PostgreSQL/PostGIS, RabbitMQ and nginx native on NixOS.
{ config, lib, pkgs, settings, ... }:
let
  domain = settings.domain;
  api = "api.${domain}";
  oidc = "${settings.oidcIssuer}/protocol/openid-connect";

  searchEnabled = settings.searchBackend == "elasticsearch";

  stateDir = "/var/lib/signalen";
  secrets = "${stateDir}/secrets.env";

  backendImage = "docker.io/signalen/backend:${settings.backendVersion}";
  frontendImage = "docker.io/signalen/frontend:${settings.frontendVersion}";

  backendEnv = {
    DJANGO_DEBUG = "False";
    ALLOWED_HOSTS = api;
    FRONTEND_URL = "https://${domain}";
    CORS_ALLOWED_ORIGINS = "https://${domain}";
    ORGANIZATION_NAME = settings.organization;
    # nginx terminates TLS
    SECURE_SSL_REDIRECT = "False";
    SESSION_COOKIE_SECURE = "True";
    CSRF_COOKIE_SECURE = "True";

    DATABASE_NAME = "signals";
    DATABASE_USER = "signals";
    DATABASE_HOST_OVERRIDE = "127.0.0.1";
    DATABASE_PORT_OVERRIDE = "5432";
    RABBITMQ_HOST = "127.0.0.1";
    RABBITMQ_USER = "signals";
    RABBITMQ_VHOST = "signals";
    ELASTICSEARCH_HOST = "127.0.0.1:9200";

    EMAIL_HOST = settings.smtpHost;
    DEFAULT_FROM_EMAIL = settings.mailFrom;

    OIDC_RP_CLIENT_ID = settings.oidcClientId;
    OIDC_OP_ISSUER = settings.oidcIssuer;
    OIDC_OP_AUTHORIZATION_ENDPOINT = "${oidc}/auth";
    OIDC_OP_TOKEN_ENDPOINT = "${oidc}/token";
    OIDC_OP_USER_ENDPOINT = "${oidc}/userinfo";
    OIDC_OP_JWKS_ENDPOINT = "${oidc}/certs";
    USER_ID_FIELDS = "email";
  };

  backendEnvFile = pkgs.writeText "signalen-backend.env" (
    lib.concatStrings (lib.mapAttrsToList (k: v: "${k}=${v}\n") backendEnv)
  );

  # Host networking: the containers reach Postgres/RabbitMQ/search on
  # 127.0.0.1, and nothing but nginx is reachable from outside.
  backend = cmd: {
    image = backendImage;
    inherit cmd;
    environment = backendEnv;
    environmentFiles = [ secrets ];
    extraOptions = [ "--network=host" ];
    volumes = [ "${stateDir}/media:/app/media" ];
  };

  # Merged over the image's app.base.json at container start.
  appJson = pkgs.writeText "app.json" (builtins.toJSON {
    apiBaseUrl = "https://${api}";
    oidc = {
      authEndpoint = "${oidc}/auth";
      clientId = settings.oidcClientId;
    };
  });
in
{
  # --- secrets: generated once on the data volume, never in the Nix store ---
  systemd.services.signalen-secrets = {
    wantedBy = [ "multi-user.target" ];
    unitConfig.RequiresMountsFor = stateDir;
    serviceConfig = { Type = "oneshot"; RemainAfterExit = true; UMask = "0077"; };
    path = [ pkgs.openssl ];
    script = ''
      mkdir -p ${stateDir}
      if [ ! -s ${secrets} ]; then
        printf 'SECRET_KEY=%s\nDATABASE_PASSWORD=%s\nRABBITMQ_PASSWORD=%s\n' \
          "$(openssl rand -hex 32)" "$(openssl rand -hex 24)" "$(openssl rand -hex 24)" \
          > ${secrets}
      fi
    '';
  };

  systemd.tmpfiles.rules = [
    "d ${stateDir}/media  0750 1000 1000 -"   # uid of `signals` in the backend image
  ];

  # --- PostgreSQL + PostGIS ----------------------------------------------------
  services.postgresql = {
    enable = true;
    package = pkgs.postgresql_16;
    extensions = ps: [ ps.postgis ];
    ensureDatabases = [ "signals" ];
    ensureUsers = [{ name = "signals"; ensureDBOwnership = true; }];
  };

  # --- RabbitMQ (Celery broker), localhost only ----------------------------------
  services.rabbitmq.enable = true;

  # Give the generated passwords to Postgres and RabbitMQ (idempotent).
  systemd.services.signalen-backing-setup = {
    wantedBy = [ "multi-user.target" ];
    after = [ "postgresql.service" "rabbitmq.service" "signalen-secrets.service" ];
    requires = [ "postgresql.service" "rabbitmq.service" "signalen-secrets.service" ];
    serviceConfig = { Type = "oneshot"; RemainAfterExit = true; };
    path = [ pkgs.util-linux config.services.postgresql.package config.services.rabbitmq.package ];
    script = ''
      . ${secrets}
      runuser -u postgres -- psql -v ON_ERROR_STOP=1 -d signals \
        -c "CREATE EXTENSION IF NOT EXISTS postgis" \
        -c "ALTER ROLE signals PASSWORD '$DATABASE_PASSWORD'"

      rmq() { runuser -u rabbitmq -- env HOME=/var/lib/rabbitmq rabbitmqctl "$@"; }
      rmq add_vhost signals || true
      rmq add_user signals "$RABBITMQ_PASSWORD" || rmq change_password signals "$RABBITMQ_PASSWORD"
      rmq set_permissions -p signals signals ".*" ".*" ".*"
    '';
  };

  # --- search (off by default: see searchBackend in flake.nix) ---------------
  # From nixpkgs rather than a container, like PostgreSQL and RabbitMQ: one
  # less image to pull on first boot, a real systemd unit to order against, and
  # vm.max_map_count handled by the module. Its data lands in
  # /var/lib/elasticsearch, which the data volume already covers.
  #
  # With searchBackend = "none" the back office cannot search. Reporting a
  # melding, the public API and the rest of the back office do not go through
  # Elasticsearch and are unaffected.
  assertions = [
    {
      assertion = builtins.elem settings.searchBackend [ "none" "elasticsearch" ];
      message = ''searchBackend must be "none" or "elasticsearch", not "${settings.searchBackend}"'';
    }
  ];

  services.elasticsearch = lib.mkIf searchEnabled {
    enable = true;
    package = pkgs.elasticsearch7;
    single_node = true;
    listenAddress = "127.0.0.1";
    port = 9200;
    extraJavaOptions = [ "-Xms1g" "-Xmx1g" ];
    extraConf = ''
      xpack.security.enabled: false
    '';
  };

  # --- the application -----------------------------------------------------------
  virtualisation.oci-containers.backend = "podman";
  virtualisation.oci-containers.containers = {
    # The image's CMD is a bare `uwsgi`, with no ini file anywhere in it and no
    # UWSGI_* in its environment, so it exits at once with "The -s/--socket
    # option is missing". Every uWSGI option has to come from here. These are
    # upstream's own, from docker-compose/scripts/initialize.sh, minus
    # --py-auto-reload (a development convenience), and bound to localhost
    # because nginx is the only thing that should reach it.
    signalen-api = backend [
      "uwsgi"
      "--master"
      "--http=127.0.0.1:8000"
      "--module=signals.wsgi:application"
      "--callable=application"
      "--static-index=index.html"
      "--static-map=/signals/static=/app/static"
      "--static-map=/signals/media=/app/media"
      "--buffer-size=8192"
      "--harakiri=15"
      "--lazy-apps"
      "--die-on-term"
    ];
    signalen-worker = backend [ "celery" "-A" "signals" "worker" "-l" "warning" ];
    signalen-beat = backend [
      "celery" "-A" "signals" "beat" "-l" "warning" "--pidfile" "/tmp/celerybeat.pid"
    ];

    signalen-frontend = {
      image = frontendImage;
      ports = [ "127.0.0.1:8080:8080" ];
      volumes = [ "${appJson}:/app.json:ro" ];
    };
  };

  # Migrate on every boot of a new image, before the API starts.
  systemd.services.signalen-migrate = {
    requires = [ "signalen-backing-setup.service" ];
    wants = [ "network-online.target" ];
    after = [ "signalen-backing-setup.service" "network-online.target" ]
      ++ lib.optional searchEnabled "elasticsearch.service";
    before = [ "podman-signalen-api.service" "podman-signalen-worker.service" "podman-signalen-beat.service" ];
    requiredBy = [ "podman-signalen-api.service" "podman-signalen-worker.service" "podman-signalen-beat.service" ];
    serviceConfig = { Type = "oneshot"; RemainAfterExit = true; };
    path = [ config.virtualisation.podman.package ];
    script = ''
      manage() {
        podman run --rm --network=host \
          --env-file ${backendEnvFile} --env-file ${secrets} \
          ${backendImage} python manage.py "$@"
      }
      manage migrate --noinput
      manage createcachetable
    '';
  };

  # --- the front door ---------------------------------------------------------------
  security.acme = { acceptTerms = true; defaults.email = settings.acmeEmail; };

  services.nginx = {
    enable = true;
    recommendedProxySettings = true;
    recommendedTlsSettings = true;
    recommendedGzipSettings = true;
    clientMaxBodySize = "25m";   # photo uploads with a melding

    virtualHosts.${domain} = {
      enableACME = true;
      forceSSL = true;
      locations."/".proxyPass = "http://127.0.0.1:8080";
    };
    virtualHosts.${api} = {
      enableACME = true;
      forceSSL = true;
      locations."/".proxyPass = "http://127.0.0.1:8000";
    };
  };
}
