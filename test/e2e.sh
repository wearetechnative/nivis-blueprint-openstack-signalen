#!/usr/bin/env bash
# Create the whole stack in a real OpenStack project, check that Signalen
# answers, then destroy it again.
#
#   OS_CLOUD=openstack ./test/e2e.sh
#
# Two applies are needed, because the host name is baked into the image but the
# address only exists once the network does:
#
#   1. apply with a placeholder domain  -> network, port, floating IP, host
#   2. re-apply with <address>.sslip.io -> new image, replaced host, real certs
#
# sslip.io resolves <ip>.sslip.io to <ip>, so no DNS record has to be made by
# hand. That second apply is not waste: it exercises the blueprint's central
# claim, that replacing the instance keeps the address and the data volume.
# A marker written to /var/lib after apply 1 is looked for again after apply 2.
#
# KEEP=1 leaves everything running. ./test/e2e.sh destroy cleans up later.

set -euo pipefail
cd "$(dirname "$0")/.."

VARS="${VARS:-test/vars.test.json}"
STATE="${STATE:-test/nivis.state.json}"
KEEP="${KEEP:-0}"
DEADLINE_MIN="${DEADLINE_MIN:-25}"
PLACEHOLDER="placeholder.invalid"

SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
          -o ConnectTimeout=10 -o BatchMode=yes -o LogLevel=ERROR)

# Every nivis call evaluates the plan, so every one of them needs the full
# variable set, `destroy` and `output` included.
DOMAIN="$PLACEHOLDER"
# NIVIS_BIN points at a build of nivis other than the flake's own, which is how
# a fix that is not released yet gets exercised. See test/SETUP.md.
NIVIS_BIN="${NIVIS_BIN:-}"
nivis() {
  local sub="$1"; shift
  if [ -n "$NIVIS_BIN" ]; then
    "$NIVIS_BIN" "$sub" --state "$STATE" --var-file "$VARS" --var "domain=$DOMAIN" "$@"
  else
    nix run github:nivis-project/nivis#nivis -- "$sub" \
      --state "$STATE" --var-file "$VARS" --var "domain=$DOMAIN" "$@"
  fi
}

# A ref resolves one attribute deep, so a list-valued address cannot be an
# output. Read the state file when `nivis output` hands back an unresolved ref.
address_from_state() {
  python3 "$(dirname "$0")/address.py" "$STATE"
}

say()  { printf '\n\033[1m== %s\033[0m\n' "$*"; }
die()  { printf '\033[31merror: %s\033[0m\n' "$*" >&2; exit 1; }
rssh() { ssh "${SSH_OPTS[@]}" "root@$ADDRESS" "$@"; }

# Images are content-addressed resources, so an image the configuration no
# longer declares is invisible to `nivis destroy`: it walks the config graph.
# Left alone they accumulate in Glance and are billed for. Sweep them by the
# name prefix this stack owns.
sweep_images() {
  command -v openstack >/dev/null 2>&1 || return 0
  local name
  openstack image list --private -f value -c Name 2>/dev/null |
    grep "^$(python3 -c "import json,sys;print(json.load(open(sys.argv[1])).get('name','signalen'))" "$VARS")-nixos-" |
    while read -r name; do
      echo "  sweeping leftover image $name"
      openstack image delete "$name" 2>/dev/null || true
    done
}

destroy() {
  say "destroy"
  nivis destroy
  sweep_images
}

case "${1:-run}" in
  destroy)
    ADDRESS=""
    # The stored domain does not matter for a destroy; the plan only has to
    # evaluate. Prefer the real one if the state still knows it.
    DOMAIN="$(nivis output address 2>/dev/null | tr -d '"[:space:]')".sslip.io || true
    [ "$DOMAIN" = ".sslip.io" ] && DOMAIN="$PLACEHOLDER"
    destroy; exit 0 ;;
  run) ;;
  *) die "usage: $0 [run|destroy]" ;;
esac

# --- preflight ----------------------------------------------------------------
[ -n "${OS_CLOUD:-}${OS_AUTH_URL:-}" ] || die "set OS_CLOUD (clouds.yaml) or the OS_* variables"
[ -f "$VARS" ] || die "no $VARS (copy test/vars.test.example.json and fill it in)"
grep -q '"protectData": *false' "$VARS" ||
  die "$VARS must set protectData to false, or the destroy at the end will refuse"
ssh-add -L >/dev/null 2>&1 || [ -f ~/.ssh/id_ed25519 ] ||
  die "no SSH key available for the checks"

# EXIT alone is not enough: a kill, a Ctrl+C or a harness stop ends the script
# without running an EXIT trap, and everything created so far is then orphaned
# in the project with nothing left holding a reference to it.
on_signal() { trap - EXIT INT TERM HUP; destroy; exit 130; }
trap '[ "$KEEP" = 1 ] || destroy' EXIT
trap on_signal INT TERM HUP

wait_for() {
  local what="$1" deadline; deadline=$(( $(date +%s) + DEADLINE_MIN * 60 ))
  shift
  printf 'waiting for %s ' "$what"
  until "$@" >/dev/null 2>&1; do
    [ "$(date +%s)" -lt "$deadline" ] || { echo; die "timed out waiting for $what"; }
    printf .
    sleep 10
  done
  echo " ok"
}

# --- 1. bring the address into being ------------------------------------------
say "apply 1/2 (placeholder domain, to learn the address)"
nivis apply

ADDRESS="$(nivis output address 2>/dev/null | tr -d '"[:space:]')"
case "$ADDRESS" in *__ref*|"") ADDRESS="$(address_from_state)" ;; esac
[ -n "$ADDRESS" ] || die "no address: neither the output nor $STATE has one"
say "address: $ADDRESS"

wait_for "ssh on $ADDRESS" rssh true

MARKER="nivis-e2e-$(date +%s)"
rssh "echo $MARKER > /var/lib/e2e-marker; findmnt -no SOURCE /var/lib"
say "wrote marker $MARKER to the data volume"

# --- 2. the real thing, on a name that resolves -------------------------------
DOMAIN="${ADDRESS}.sslip.io"
say "apply 2/2 (domain=$DOMAIN: new image, replaced instance, same address)"
nivis apply

wait_for "ssh on the replaced host" rssh true
wait_for "a certificate for $DOMAIN"      curl -fsS --max-time 10 "https://$DOMAIN/"
wait_for "the API on api.$DOMAIN"         curl -fsS --max-time 10 "https://api.$DOMAIN/signals/v1/"

# --- 3. checks -----------------------------------------------------------------
say "checks"
fail=0
check() {
  local name="$1"; shift
  if "$@" >/dev/null 2>&1; then printf '  ok    %s\n' "$name"
  else printf '  \033[31mFAIL\033[0m  %s\n' "$name"; fail=1; fi
}

check "frontend serves HTML"       bash -c "curl -fsS 'https://$DOMAIN/' | grep -qi '<html'"
# No /app.json endpoint: the frontend inlines its config into index.html.
check "frontend is pointed at our API" bash -c "curl -fsS 'https://$DOMAIN/' | grep -q 'apiBaseUrl\":\"https://api.$DOMAIN'"
check "API root is JSON"           bash -c "curl -fsS 'https://api.$DOMAIN/signals/v1/' | head -c1 | grep -q '[{[]'"
check "API serves categories"      curl -fsS "https://api.$DOMAIN/signals/v1/public/terms/categories/"
check "HTTP redirects to HTTPS"    bash -c "curl -sS -o /dev/null -w '%{http_code}' 'http://$DOMAIN/' | grep -q '^30'"
check "certificate is not self-signed" \
  bash -c "echo | openssl s_client -connect '$DOMAIN:443' -servername '$DOMAIN' 2>/dev/null | grep -qi 'Let.s Encrypt'"
check "data volume mounted at /var/lib"  rssh "findmnt -no SOURCE /var/lib | grep -q /dev/vdb"
check "the marker survived the replacement" \
  rssh "grep -q $MARKER /var/lib/e2e-marker"
check "postgres has the Signalen schema" \
  rssh "sudo -u postgres psql -tAc \"select to_regclass('public.signals_signal')\" signals | grep -q signals_signal"
check "no failed units"            rssh "! systemctl list-units --failed --no-legend --plain | grep -q ."

if [ "$fail" != 0 ]; then
  say "something failed; state on the host"
  rssh "systemctl --failed --no-pager; journalctl -p warning -n 120 --no-pager" || true
  die "checks failed"
fi

say "all checks passed: https://$DOMAIN"
[ "$KEEP" = 1 ] && say "KEEP=1: left running. ./test/e2e.sh destroy to clean up."
exit 0
