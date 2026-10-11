# Signalen on NixOS on OpenStack

A Nivis blueprint. One flake describes both the machine and the cloud it runs
in: clone it, fill in a handful of variables, `nivis apply`, and
[Signalen](https://signalen.org) (meldingen openbare ruimte) is running on a
NixOS host in your own OpenStack project.

> **Status: applied, and seen working.** Created, checked and destroyed
> against Vexxhost ams1 on 2026-10-11: Signalen served over HTTPS with a real
> Let's Encrypt certificate, the API answering, and the data volume surviving
> an instance replacement. Read [Open points](#open-points) before putting a
> municipality on it; several are serious.
>
> **Needs Nivis 0.9.2 or later.** 0.9.0 and 0.9.1 send unset
> optional-computed attributes as unknown rather than null, which creates
> ports administratively down and is refused outright by some Neutron
> policies.

## What you get

```
nivis apply ──► NixOS image (qcow2, Signalen baked in)        built by the run
                    │
  Nivis ── openstack_images_image_v2           the image, uploaded to Glance
        ── security group                       :80 :443 open, :22 from adminCidr
        ── port                                 a stable address
        ── openstack_blockstorage_volume_v3     the data volume (all state)
        ── openstack_compute_instance_v2        the host
        ── network + subnet + router            unless directAttach (see below)
           + floating IP
                    │
  https://<domain>        Signalen frontend
  https://api.<domain>    Signalen API
```

On the host: nginx with Let's Encrypt in front, PostgreSQL 16 + PostGIS and
RabbitMQ as native NixOS services, and the upstream Signalen containers
(API, Celery worker, Celery beat, frontend) plus Elasticsearch under podman.

## The idea: a disposable host, a durable volume

The host is never patched in place. Its whole configuration is baked into the
image, so **a change in Nix is a new image, and a new image is a new
instance**. Three things survive that replacement, because they are separate
resources:

- the **data volume**, mounted at `/var/lib` (database, uploads, search index,
  certificates, generated secrets);
- the **port and floating IP**, so the address and DNS never move;
- the **network and firewall**.

An upgrade of NixOS or Signalen is therefore: change a version, `nivis apply`.
A rollback is the same with the previous commit.

## Use it

You need Nix (with flakes) and an OpenStack project with a `clouds.yaml`.

```sh
cp vars.example.json vars.json     # edit: domain, e-mail, SSH key, OIDC, flavor
export OS_CLOUD=my-project

nix run github:nivis-project/nivis/v0.9.2#nivis -- plan  --var-file vars.json
nix run github:nivis-project/nivis/v0.9.2#nivis -- apply --var-file vars.json
```

`nivis apply` writes `nivis.state.json` and `nivis.state.json.ledger` next to
you. Both can hold secrets that came back from the provider. Do not commit
them.

Then point DNS for `<domain>` and `api.<domain>` at the `address` output.
Certificates are requested as soon as the names resolve. Because the host name
is baked into the image, the first deployment is two applies: one to learn the
address, one with the name that now resolves to it.

To look at the image without a cloud: `nix build .#image`. To check that
everything still evaluates and builds: `nix flake check`.

| Variable | Default | |
| --- | --- | --- |
| `domain` | required | frontend host name; the API is `api.<domain>` |
| `acmeEmail` | required | Let's Encrypt contact |
| `adminSshKey` | required | public key for root SSH |
| `oidcIssuer` | required | Keycloak realm URL for back-office login |
| `oidcClientId` | `signalen` | |
| `organization`, `mailFrom`, `smtpHost` | | shown in / used for e-mail to reporters |
| `backendVersion`, `frontendVersion` | `2.50.18`, `2.27.11` | Signalen image tags |
| `flavor` | `m1.large` | needs about 8 GB RAM; flavor names differ per cloud |
| `externalNetwork` | `public` | the provider's external network |
| `directAttach` | `false` | see [Two network shapes](#two-network-shapes) |
| `searchBackend` | `none` | `none` or `elasticsearch`; see [Open points](#open-points) |
| `adminCidr` | `0.0.0.0/0` | who may reach SSH; narrow this |
| `dataVolumeGb` | `50` | |
| `protectData` | `true` | refuse to destroy the data volume |

## Two network shapes

The default builds a private network behind a router and puts a floating IP in
front. That is the usual OpenStack shape and the portable one.

`directAttach = true` instead hangs the host's port straight on
`externalNetwork`, and the network, subnet, router and floating IP are not
created at all. It needs that network to be `shared` as well as
`router:external`.

It exists because some clouds will not do the default. Vexxhost refuses
`create_router` with an external gateway in one call, and the provider only
makes one call:

```
403 PolicyNotAuthorized: ... create_router:external_gateway_info:enable_snat ...
```

Either way the PORT is the durable thing, not the floating IP: it keeps its
address when the instance is replaced. Only `directAttach = true` has been
applied against a real cloud.

## Secrets

Nothing secret is in this repository, the Nix store or the image. The Django
secret key and the database and broker passwords are generated on first boot
and kept on the data volume (`/var/lib/signalen/secrets.env`, mode 0600).

## Test it

Two harnesses, cheapest first.

`test/boot-local.sh` boots the image in qemu with a blank second disk, the way
OpenStack will, and checks that Signalen answers. Three minutes, no cloud, no
credentials. Every boot-path bug this blueprint has had was visible here first:
a stage 1 panic on the unformatted volume, a metadata fetch that blocked sshd,
an API container that exited at once because its uWSGI options were missing.
Run it before you spend twenty minutes proving the same thing in a cloud.

```sh
./test/boot-local.sh            # KEEP=1 leaves it up on ssh -p 2222
```

`test/e2e.sh` creates the stack in a real project, checks it over HTTPS, and
destroys it again. It uses `<address>.sslip.io` as the host name, so no DNS
record has to be made by hand. `test/SETUP.md` has the steps for getting a
`clouds.yaml` and the one thing that differs per cloud.

```sh
cp test/vars.test.example.json test/vars.test.json   # edit it
OS_CLOUD=my-project ./test/e2e.sh
```

It applies twice on purpose. The host name is baked into the image and the
address only exists once the port does, so the first apply learns the address
and the second deploys under it. That second apply is also the test that
matters: it writes a marker to the data volume beforehand and looks for it
afterwards, so a green run has demonstrated that replacing the instance keeps
both the address and the state.

## Open points

Worst first.

- **Elasticsearch 7 is end of life** (since 2026-01-15) and carries six known
  CVEs, so `searchBackend` defaults to `none` and the back office cannot
  search. OpenSearch is not a drop-in: Signalen pins `elasticsearch==7.17.13`,
  whose client refuses to speak to anything that does not identify as
  Elasticsearch. The fix is upstream, not here.
- **No backups.** The data volume holds the database, the uploads, the search
  index and the certificates, and nothing snapshots it.
- **Images accumulate.** The image is a content-addressed resource, so a new
  one is created rather than replacing the old, which is what lets the host
  release it (Nivis refuses to replace an object another resource still
  holds). The old image is then no longer in the configuration, and
  `nivis destroy` walks the configuration, so it never removes it. That is the
  rollback path, but production needs a retention policy. `test/e2e.sh` sweeps
  them by name prefix; nothing else does.
- **Identity** is assumed to exist (a Keycloak realm). Back-office login has
  never been tested against a real one.
- **Container image tags** are pinned by tag, not digest.
- **One cloud, one shape.** Applied only against Vexxhost ams1, with
  `directAttach = true`. The default router shape is untested anywhere.
- **`growpart` under systemd stage 1.** It runs as a stage 2 service while the
  root filesystem is grown in the initrd, so the root partition may not expand
  to the flavor's disk. `test/boot-local.sh` asserts it; the cloud run does
  not.
- **Boot from volume.** The root disk comes from the image locally. A cloud
  whose flavors have a 0 GB disk needs `destination_type = "volume"` and a
  `volume_size`.
- **No image properties.** Glance gets no `properties`; a cloud needing
  `hw_firmware_type` has to have them added. The image is BIOS boot on x86_64.
- **`/dev/vdb`** is assumed to be the data volume.
- **PostgreSQL 16 / PostGIS 3.x**: upstream develops against 12 / 3.2.
- **Not yet covered:** outbound mail relay, monitoring, DNS via Designate, the
  BIO2 hardening baseline, and the Signalen classification and mapserver
  services.

## Licence

Apache-2.0.
