{
  description = "Nivis blueprint: Signalen on a NixOS host in OpenStack";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
  inputs.nivis.url = "github:nivis-project/nivis/v0.9.2";

  outputs =
    { self, nixpkgs, nivis }:
    let
      lib = nivis.lib;

      # One set of variables drives BOTH domains: the OS and the infra.
      declareVars = lib.mkVars {
        name            = { type = "str";  default = "signalen"; };
        domain          = { type = "str"; };   # meldingen.example.nl (API: api.<domain>)
        acmeEmail       = { type = "str"; };
        adminSshKey     = { type = "str"; };   # public key, baked into the image
        oidcIssuer      = { type = "str"; };   # Keycloak realm URL
        oidcClientId    = { type = "str";  default = "signalen"; };
        organization    = { type = "str";  default = "Gemeente"; };
        smtpHost        = { type = "str";  default = "localhost"; };
        mailFrom        = { type = "str";  default = "noreply@example.nl"; };
        backendVersion  = { type = "str";  default = "2.50.18"; };
        frontendVersion = { type = "str";  default = "2.27.11"; };
        # OpenStack side
        flavor          = { type = "str";  default = "m1.large"; };  # >= 8 GB RAM
        externalNetwork = { type = "str";  default = "public"; };
        adminCidr       = { type = "str";  default = "0.0.0.0/0"; }; # who may SSH
        # "none" or "elasticsearch". Signalen's back-office search needs
        # Elasticsearch 7, which went EOL on 2026-01-15 and carries six CVEs,
        # and its pinned client (elasticsearch 7.17 + elasticsearch-dsl 7.4)
        # refuses to speak to OpenSearch because of the product check. There is
        # no safe option here today, so the default is the one that ships no
        # known holes, and turning search on has to be a decision someone made.
        searchBackend   = { type = "str";  default = "none"; };
        # true: hang the host's port straight on `externalNetwork` instead of
        # building a private network, a router and a floating IP. Needs that
        # network to be shared; required on clouds that refuse to create a
        # router and its external gateway in one call (Vexxhost does).
        directAttach    = { type = "bool"; default = false; };
        dataVolumeGb    = { type = "int";  default = 50; };
        protectData     = { type = "bool"; default = true; };
      };

      # Domain 1: the OS. A NixOS system whose build output is a qcow2 image.
      imageSystem =
        vars:
        nixpkgs.lib.nixosSystem {
          system = "x86_64-linux";
          specialArgs.settings = vars;
          modules = [
            # Elasticsearch is Elastic 2.0 (unfree) and EOL (insecure). Both
            # are allowed by name rather than wholesale, and only when search
            # is actually switched on, so nothing else can quietly ride along.
            (
              if vars.searchBackend == "elasticsearch" then
                {
                  nixpkgs.config.allowUnfreePredicate =
                    pkg: nixpkgs.lib.getName pkg == "elasticsearch";
                  nixpkgs.config.allowInsecurePredicate =
                    pkg: nixpkgs.lib.getName pkg == "elasticsearch";
                }
              else
                { }
            )
            ./image.nix
            ./default.nix
            ./signalen.nix
          ];
        };

      # The derivation plus the path of the qcow2 inside it. $out is a DIRECTORY
      # (make-disk-image writes $out/<fileName>), and Glance must be handed the
      # file, so infra.nix needs both halves.
      mkImage =
        vars:
        let
          sys = imageSystem vars;
        in
        {
          drv = sys.config.system.build.image;
          fileName = sys.config.image.fileName;
        };

      exampleVars = declareVars (builtins.fromJSON (builtins.readFile ./vars.example.json));
    in
    {
      # Domain 2: the infra, fed by that image. `nivis` evaluates this.
      nivis.plan =
        ledger:
        let
          vars = declareVars (ledger.vars or { });
        in
        import ./infra.nix {
          nivis = lib;
          inherit vars;
          nixosImage = mkImage vars;
        } ledger;

      # The same image the cloud gets, from a plain vars attrset, so the local
      # boot test (test/boot-local.sh) exercises the image that will be applied
      # rather than a lookalike built from the example variables.
      lib.imageFrom = varsJson: mkImage (declareVars varsJson);

      # `nix build .#image` to inspect or boot the qcow2 without touching a cloud.
      # Built from vars.example.json; `nivis apply` builds it from your own vars.
      packages.x86_64-linux.image = (mkImage exampleVars).drv;

      # `nix flake check`: the host config and the IR both evaluate.
      checks.x86_64-linux = {
        host = (imageSystem exampleVars).config.system.build.toplevel;
        image = (mkImage exampleVars).drv;
      };
    };
}
