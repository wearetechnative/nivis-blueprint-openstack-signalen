# Running the e2e test against Vexxhost

## 1. Get the client

```sh
nix shell nixpkgs#openstackclient
```

## 2. Get a clouds.yaml

In the Vexxhost dashboard for your region (Amsterdam is
`https://console.vexxhost.net`, log in and pick the project):

1. Identity -> Application Credentials -> Create Application Credential
2. Name it `nivis-e2e`, leave the roles as they are, set an expiry if you like
3. Download `clouds.yaml` (the secret is shown once)
4. `mkdir -p ~/.config/openstack && mv ~/Downloads/clouds.yaml ~/.config/openstack/`

Check the cloud name it wrote (usually `openstack`):

```sh
grep -E '^  [a-z]' ~/.config/openstack/clouds.yaml
export OS_CLOUD=<that name>
openstack token issue >/dev/null && echo "auth ok"
```

## 3. Report these four things back

```sh
openstack flavor list
openstack network list --external
openstack volume type list
openstack limits show --absolute
```

What matters in the output:

| What | Why |
| --- | --- |
| a flavor with >= 8 GB RAM | Elasticsearch alone takes 1 GB heap plus Postgres, RabbitMQ and four containers |
| that flavor's **Disk** column | if it is `0`, the cloud is boot-from-volume only and `infra.nix` needs a change (see below) |
| the external network's name | `externalNetwork`, probably `public` |
| the quota for instances, volumes, floating IPs, RAM | the test needs 1 instance, 1 volume of 20 GB, 1 floating IP |

### If Disk is 0

`infra.nix` boots the root disk from the image locally:

```nix
{ uuid = image.refAttr "id"; source_type = "image"; destination_type = "local"; ... }
```

A cloud whose flavors have no local disk needs `destination_type = "volume"`
plus a `volume_size`. Say so and it gets changed before the first apply.

## 4. Run it

```sh
cp test/vars.test.example.json test/vars.test.json   # edit: ssh key, e-mail, flavor
export OS_CLOUD=<name>
./test/e2e.sh
```

The script applies twice (the host name has to be in the image, and the
address only exists after the network does), checks the frontend, the API,
the database and the mounted data volume, then destroys everything. `KEEP=1`
leaves it running; `./test/e2e.sh destroy` cleans up afterwards.

Expect 30 to 60 minutes on a first run. The image is 5.5 GB on disk (8.4 GB
virtual) and gets uploaded twice, so the uploads dominate. The NixOS build
itself is cached between the two applies; only the qcow2 is regenerated.

The container images are not in the qcow2. The host pulls Signalen and
Elasticsearch from Docker Hub on first boot, so it needs to reach the
internet, and an anonymous pull rate limit will show up as a failed
`podman-signalen-*` unit.

## What the test does not cover

- OIDC login to the back office, because that needs a Keycloak realm. The
  `oidcIssuer` in `vars.test.json` may point at a realm that does not exist;
  the frontend and the API still come up, only the login button fails.
- Outgoing mail.
- Data survival across an instance replacement. Apply 2 does replace the
  instance, so a manual check is possible: create a melding after apply 1,
  look for it after apply 2.
