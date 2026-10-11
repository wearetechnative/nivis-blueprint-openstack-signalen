#!/usr/bin/env bash
# Boot the image in qemu with a blank second disk, the way OpenStack will, and
# check it reaches a running system. Three minutes and no cloud, against the
# twenty a build-plus-upload costs. Every boot-path bug this blueprint has hit
# so far (a stage 1 panic on the unformatted volume, a metadata fetch that
# blocked sshd) is visible here.
#
#   ./test/boot-local.sh [vars.json]
#
# KEEP=1 leaves the machine up, reachable on ssh -p 2222 root@localhost.

set -euo pipefail
cd "$(dirname "$0")/.."

VARS="${1:-test/vars.test.json}"
DOMAIN_DEFAULT="local.invalid"
MEM="${MEM:-6144}"
DEADLINE_MIN="${DEADLINE_MIN:-10}"
KEEP="${KEEP:-0}"
WORK="$(mktemp -d)"
LOG="$WORK/console.log"
# Port 2222 is a popular choice, so do not assume it is ours.
pick_port() {
  local p
  for p in $(seq 2222 2280); do
    (exec 3<>"/dev/tcp/127.0.0.1/$p") 2>/dev/null && { exec 3<&-; continue; }
    echo "$p"; return 0
  done
  return 1
}
PORT="${PORT:-$(pick_port)}" || die "no free port between 2222 and 2280"

say() { printf '\n\033[1m== %s\033[0m\n' "$*"; }
die() { printf '\033[31merror: %s\033[0m\n' "$*" >&2; exit 1; }

[ -f "$VARS" ] || die "no $VARS"
# Must match the domain baked into the image, because Django's ALLOWED_HOSTS
# rejects anything else with a 400 before it looks at the path.
DOMAIN="$(python3 -c "import json,sys;print(json.load(open(sys.argv[1])).get('domain','$DOMAIN_DEFAULT'))" "$VARS")"
API="api.$DOMAIN"
[ -w /dev/kvm ] || die "no /dev/kvm (add yourself to the kvm group)"

say "building the image from $VARS"
# `domain` has no default and the e2e passes it with --var, so supply one here.
# Nothing in the boot path depends on its value; ACME simply fails over to the
# self-signed certificate, as it would for any name that does not resolve yet.
EXPR="let vars = builtins.fromJSON (builtins.readFile $PWD/$VARS);
      in (builtins.getFlake \"path:$PWD\").lib.imageFrom
         ({ domain = \"local.invalid\"; } // vars)"
if ! IMG="$(nix build --impure --no-link --print-out-paths --expr "$EXPR")"; then
  die "the image did not build"
fi
QCOW="$IMG/nixos.qcow2"
[ -f "$QCOW" ] || die "no qcow2 at $QCOW"
say "image: $QCOW"

cleanup() {
  [ "$KEEP" = 1 ] && return 0
  [ -n "${QEMU_PID:-}" ] && kill "$QEMU_PID" 2>/dev/null || true
  rm -rf "$WORK"
}
trap cleanup EXIT
trap 'KEEP=0; cleanup; exit 130' INT TERM HUP

nix shell nixpkgs#qemu -c qemu-img create -f qcow2 "$WORK/data.qcow2" 20G >/dev/null

say "booting (console: $LOG)"
nix shell nixpkgs#qemu -c qemu-system-x86_64 \
  -machine accel=kvm -cpu host -smp 2 -m "$MEM" \
  -drive "file=$QCOW,format=qcow2,if=virtio,snapshot=on" \
  -drive "file=$WORK/data.qcow2,format=qcow2,if=virtio" \
  -nic "user,model=virtio,hostfwd=tcp:127.0.0.1:$PORT-:22" \
  -display none -serial "file:$LOG" &
QEMU_PID=$!

SSH_OPTS=(-p "$PORT" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
          -o ConnectTimeout=5 -o BatchMode=yes -o LogLevel=ERROR)
vssh() { ssh "${SSH_OPTS[@]}" root@localhost "$@"; }

deadline=$(( $(date +%s) + DEADLINE_MIN * 60 ))
printf 'waiting for ssh '
until vssh true >/dev/null 2>&1; do
  kill -0 "$QEMU_PID" 2>/dev/null || { echo; die "qemu died; see $LOG"; }
  if [ "$(date +%s)" -ge "$deadline" ]; then
    echo
    say "last 40 console lines"
    tail -40 "$LOG"
    die "no ssh within ${DEADLINE_MIN}m"
  fi
  printf .
  sleep 5
done
echo " ok"

# The containers are pulled from Docker Hub on first boot, so they come up well
# after sshd does. Without waiting, the checks below race the pull and report a
# failure that is really just impatience.
printf 'waiting for the API '
api_deadline=$(( $(date +%s) + DEADLINE_MIN * 60 ))
until vssh "curl -fsS --max-time 5 -H 'Host: $API' http://127.0.0.1:8000/signals/v1/ >/dev/null" 2>/dev/null; do
  [ "$(date +%s)" -lt "$api_deadline" ] || {
    echo
    say "containers"
    vssh "podman ps -a --format '{{.Names}}\t{{.Status}}'" || true
    vssh "journalctl -u podman-signalen-api -n 30 --no-pager" || true
    die "the API never answered"
  }
  printf .
  sleep 10
done
echo " ok"

say "checks"
fail=0
check() {
  local name="$1"; shift
  if "$@" >/dev/null 2>&1; then printf '  ok    %s\n' "$name"
  else printf '  \033[31mFAIL\033[0m  %s\n' "$name"; fail=1; fi
}

check "data volume mounted at /var/lib"  vssh "findmnt -no SOURCE /var/lib | grep -q /dev/vdb"
check "the volume got a filesystem"      vssh "findmnt -no FSTYPE /var/lib | grep -q ext4"
check "root partition fills the disk"    vssh '[ $(lsblk -bno SIZE /dev/vda1) -gt $(( $(lsblk -bndo SIZE /dev/vda) - 100000000 )) ]'
check "no metadata fetch is running"     vssh "! systemctl is-active openstack-init >/dev/null 2>&1"
check "postgres is up"                   vssh "systemctl is-active postgresql"
check "rabbitmq is up"                   vssh "systemctl is-active rabbitmq"
check "nginx is up"                      vssh "systemctl is-active nginx"
check "secrets were generated"           vssh "test -s /var/lib/signalen/secrets.env"
# ACME cannot succeed for a name that does not resolve, which is every name in
# a local boot. Anything else failing is a real failure.
check "the API answers"                  vssh "curl -fsS --max-time 10 -H 'Host: $API' http://127.0.0.1:8000/signals/v1/ >/dev/null"
check "the API serves public categories" vssh "curl -fsS --max-time 10 -H 'Host: $API' http://127.0.0.1:8000/signals/v1/public/terms/categories/ >/dev/null"
check "the frontend serves HTML"         vssh "curl -fsS --max-time 10 http://127.0.0.1:8080/ | grep -qi '<html'"
# The frontend has no /app.json endpoint: its entrypoint merges app.base.json
# with the file we mount and inlines the result into index.html as window.CONFIG.
check "frontend is pointed at our API"   vssh "curl -fsS --max-time 10 http://127.0.0.1:8080/ | grep -q 'apiBaseUrl\":\"https://$API'"
check "nginx proxies the API over TLS"   vssh "curl -fsS -k --max-time 10 --resolve $API:443:127.0.0.1 https://$API/signals/v1/ >/dev/null"
check "nginx serves the frontend"        vssh "curl -fsS -k --max-time 10 --resolve $DOMAIN:443:127.0.0.1 https://$DOMAIN/ | grep -qi '<html'"
check "every container is up"            vssh "! podman ps -a --format '{{.Status}}' | grep -qv '^Up'"
check "nothing but ACME failed" vssh \
  "! systemctl list-units --failed --no-legend --plain | grep -qv '^acme-'"

if [ "$fail" != 0 ]; then
  say "failed units"
  vssh "systemctl --failed --no-pager" || true
  vssh "journalctl -p warning -n 80 --no-pager" || true
  die "checks failed (console: $LOG)"
fi

say "boots clean"
[ "$KEEP" = 1 ] && say "KEEP=1: ssh -p $PORT root@localhost; console at $LOG"
exit 0
