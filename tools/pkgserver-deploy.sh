#!/usr/bin/env bash
#
# pkgserver-deploy.sh — install and start the CactPkg repository server on
# Artix Linux (dinit).  Idempotent; safe to re-run.
#
#   sudo tools/pkgserver-deploy.sh --domain pkg.example.org --email you@example.org
#
# Installs the server binary, a stable repository directory and the publish
# token (kept if it already exists), writes the dinit service, enables it at
# boot and starts it.  When the domain resolves it also obtains the Let's
# Encrypt certificate through the server's own ACME listener on port 80; the
# certbot deploy hook reloads the certificate on every renewal, with no
# restart and no downtime.
#
# Options:
#   --domain NAME      public host name            (default: pkg.cact.org)
#   --email ADDR       ACME account e-mail         (needed for the first issuance)
#   --repo DIR         repository directory        (default: /srv/cactpkg/repo)
#   --webroot DIR      ACME webroot                (default: /var/www/acme)
#   --token-file FILE  publish bearer token        (default: /etc/cactpkg/publish.token)
#   --bind ADDR        bind address                (default: 0.0.0.0)
#   --behind-tunnel    serve plain HTTP on the loopback for a TLS-terminating
#                      tunnel or reverse proxy in front (drops Let's Encrypt)
#   --tailscale        implies --behind-tunnel: also install and start the
#                      tailscaled service and, if logged in, funnel the port
#   --local-port N     loopback port for --behind-tunnel   (default: 8443)
#   --no-certbot       install and start; do not touch certificates
#   --no-start         install files only; do not enable or (re)start the service
#   -h, --help         show this help
#
set -euo pipefail

SERVICE=pkgserver
UNIT=/etc/dinit.d/pkgserver
BOOTD=/etc/dinit.d/boot.d
BIN=/usr/local/bin/pkgserver.py

HERE=$(cd "$(dirname "$0")" && pwd)
SRC=$(cd "$HERE/.." && pwd)

DOMAIN=pkg.cact.org
EMAIL=
REPO=/srv/cactpkg/repo
WEBROOT=/var/www/acme
TOKEN_FILE=/etc/cactpkg/publish.token
BIND=0.0.0.0
TUNNEL=0
TAILSCALE=0
LPORT=8443
DO_CERTBOT=1
DO_START=1

say() { printf '  %s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

usage() {
    cat <<'EOF'
Usage: sudo pkgserver-deploy.sh [options]

  --domain NAME      public host name            (default: pkg.cact.org)
  --email ADDR       ACME account e-mail         (needed for the first issuance)
  --repo DIR         repository directory        (default: /srv/cactpkg/repo)
  --webroot DIR      ACME webroot                (default: /var/www/acme)
  --token-file FILE  publish bearer token        (default: /etc/cactpkg/publish.token)
  --bind ADDR        bind address                (default: 0.0.0.0)
  --behind-tunnel    serve plain HTTP on the loopback for a TLS-terminating
                     tunnel or reverse proxy in front (drops Let's Encrypt)
  --tailscale        implies --behind-tunnel: also install and start the
                     tailscaled service and, if logged in, funnel the port
  --local-port N     loopback port for --behind-tunnel   (default: 8443)
  --no-certbot       install and start; do not touch certificates
  --no-start         install files only; do not enable or (re)start the service
  -h, --help         show this help
EOF
}

# True when NAME has an A record, checked against the local resolver and then
# a public one (the local resolver can lie about a host that does not exist).
resolves() {
    getent hosts "$1" >/dev/null 2>&1 && return 0
    command -v curl >/dev/null 2>&1 || return 1
    local r
    r=$(curl -fsS --max-time 5 "https://dns.google/resolve?name=$1&type=A" 2>/dev/null) || return 1
    if command -v python3 >/dev/null 2>&1; then
        python3 -c 'import json, sys
d = json.load(sys.stdin)
a = [x for x in d.get("Answer", []) if x.get("type") == 1]
sys.exit(0 if d.get("Status") == 0 and a else 1)' <<<"$r"
    else
        # no python3: NOERROR status plus an explicit A answer
        printf '%s' "$r" | grep -q '"Status":0' \
            && printf '%s' "$r" | grep -q '"type":1'
    fi
}

# Enable a dinit service at boot and (re)start it so the current unit file
# takes effect.  unload cannot be used: the boot service waits for it.
dinit_up() {
    local svc=$1
    if [ ! -e "$BOOTD/$svc" ]; then
        dinitctl enable "$svc" >/dev/null
        say "enabled $svc (starts at boot)"
    fi
    if dinitctl status "$svc" >/dev/null 2>&1; then
        dinitctl reload "$svc" >/dev/null 2>&1 \
            || say "note: reload of $svc failed, restarting instead"
        dinitctl restart "$svc" >/dev/null 2>&1 || dinitctl start "$svc"
    else
        dinitctl start "$svc"
    fi
    say "$svc: $(dinitctl status "$svc" 2>&1 \
        | grep -i '^ *State:' | sed 's/^ *//' || echo 'unknown state')"
}

while [ $# -gt 0 ]; do
    case "$1" in
        --domain)     DOMAIN=${2:?--domain needs a value}; shift 2 ;;
        --email)      EMAIL=${2:?--email needs a value}; shift 2 ;;
        --repo)       REPO=${2:?--repo needs a value}; shift 2 ;;
        --webroot)    WEBROOT=${2:?--webroot needs a value}; shift 2 ;;
        --token-file) TOKEN_FILE=${2:?--token-file needs a value}; shift 2 ;;
        --bind)       BIND=${2:?--bind needs a value}; shift 2 ;;
        --behind-tunnel) TUNNEL=1; shift ;;
        --tailscale)  TUNNEL=1; TAILSCALE=1; shift ;;
        --local-port) LPORT=${2:?--local-port needs a value}; shift 2 ;;
        --no-certbot) DO_CERTBOT=0; shift ;;
        --no-start)   DO_START=0; shift ;;
        -h|--help)    usage; exit 0 ;;
        *)            die "unknown argument: $1 (try --help)" ;;
    esac
done

[ "$(id -u)" -eq 0 ] || die "run as root:  sudo $0 --domain $DOMAIN [--email you@example.org]"
[ -f "$SRC/tools/pkgserver.py" ] || die "tools/pkgserver.py not found under $SRC"
command -v dinitctl >/dev/null 2>&1 || die "dinitctl not found; this script targets dinit systems"

echo "pkgserver deploy"
if [ "$TUNNEL" -eq 1 ]; then
    say "mode     behind a tunnel (plain HTTP on 127.0.0.1:$LPORT)"
else
    say "domain   $DOMAIN"
fi
say "repo     $REPO"
say "webroot  $WEBROOT"

mkdir -p "$(dirname "$BIN")" "$(dirname "$UNIT")" "$REPO" "$WEBROOT" \
    "$(dirname "$TOKEN_FILE")"
install -m755 "$SRC/tools/pkgserver.py" "$BIN"
say "installed $BIN"

if [ -s "$TOKEN_FILE" ]; then
    say "kept existing publish token $TOKEN_FILE"
else
    ( umask 077; head -c24 /dev/urandom | base64 > "$TOKEN_FILE" )
    say "generated publish token $TOKEN_FILE"
fi

tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT
if [ "$TUNNEL" -eq 1 ]; then
    cmdline="$BIN --repo $REPO --http --port $LPORT --publish-token-file $TOKEN_FILE"
else
    cmdline="$BIN --repo $REPO --cert /etc/letsencrypt/live/$DOMAIN/fullchain.pem --key /etc/letsencrypt/live/$DOMAIN/privkey.pem --domain $DOMAIN --host $BIND --acme-port 80 --acme-webroot $WEBROOT --publish-token-file $TOKEN_FILE"
fi
cat > "$tmp" <<EOF
# CactPkg repository server (written by tools/pkgserver-deploy.sh).
type            = process
command         = $cmdline
smooth-recovery = true
depends-on      = network.target
depends-on      = local.target
EOF
if cmp -s "$tmp" "$UNIT"; then
    say "$UNIT unchanged"
else
    install -m644 "$tmp" "$UNIT"
    say "installed $UNIT"
fi

if [ "$DO_START" -eq 1 ]; then
    dinit_up "$SERVICE"
fi

if [ "$TAILSCALE" -eq 1 ]; then
    if ! command -v tailscale >/dev/null 2>&1; then
        say "tailscale not installed:  sudo pacman -Syu --needed tailscale"
        say "then re-run this script with --tailscale"
    elif [ ! -f "$SRC/tools/tailscaled.dinit" ]; then
        say "missing $SRC/tools/tailscaled.dinit"
    else
        mkdir -p /var/lib/tailscale /run/tailscale
        modprobe tun 2>/dev/null || true
        install -m644 "$SRC/tools/tailscaled.dinit" /etc/dinit.d/tailscaled
        if [ "$DO_START" -eq 1 ]; then
            dinit_up tailscaled
        fi
        if tailscale status >/dev/null 2>&1; then
            tailscale funnel --bg --yes "$LPORT"
            say "funnel:"
            tailscale funnel status 2>&1 | sed 's/^/    /'
        else
            say "tailscale is not logged in yet; run these once:"
            say "    sudo tailscale up"
            say "    sudo tailscale funnel --bg $LPORT"
        fi
    fi
fi

if [ "$TUNNEL" -eq 1 ]; then
    say "certificate: none on this hop (--behind-tunnel); the tunnel or proxy"
    say "             terminates TLS, so the public URL must be https"
elif [ "$DO_CERTBOT" -eq 0 ]; then
    say "certificate: skipped (--no-certbot)"
elif [ -f "/etc/letsencrypt/live/$DOMAIN/fullchain.pem" ]; then
    say "certificate for $DOMAIN already present"
    if [ "$DO_START" -eq 1 ]; then
        dinitctl signal HUP "$SERVICE" >/dev/null 2>&1 || true
    fi
elif ! command -v certbot >/dev/null 2>&1; then
    say "certbot not installed:  sudo pacman -Syu --needed certbot"
    say "then re-run this script to issue the certificate"
elif ! resolves "$DOMAIN"; then
    say "warning: $DOMAIN does not resolve; create the DNS A record first"
    say "then re-run this script to issue the certificate"
else
    say "requesting a Let's Encrypt certificate for $DOMAIN"
    args=(certonly --webroot -w "$WEBROOT" -d "$DOMAIN"
          --deploy-hook "dinitctl signal HUP $SERVICE")
    if [ -n "$EMAIL" ]; then
        args+=(-m "$EMAIL" --agree-tos --no-eff-email --non-interactive)
    fi
    certbot "${args[@]}"
    say "certificate issued; HTTPS is up"
fi

echo
if [ "$TUNNEL" -eq 1 ]; then
    say "local hub   http://127.0.0.1:$LPORT"
    if [ "$TAILSCALE" -eq 1 ]; then
        say "public URL  https://<node>.<tailnet>.ts.net   (see: tailscale funnel status)"
    else
        say "expose it   point a TLS-terminating tunnel at that port, e.g."
        say "              ssh -R 80:localhost:$LPORT nokey@localhost.run   (free, no signup)"
        say "              sudo tailscale funnel --bg $LPORT                (stable URL)"
    fi
    say "publish     curl -T <file>.cpkg -H \"Authorization: Bearer <token from $TOKEN_FILE>\" https://<tunnel-host>/publish/<file>.cpkg"
    say "client      cactpkg update -R https://<tunnel-host>"
else
    say "repository  https://$DOMAIN"
    say "publish     curl -T <file>.cpkg -H \"Authorization: Bearer <token from $TOKEN_FILE>\" https://$DOMAIN/publish/<file>.cpkg"
    say "client      cactpkg update -R https://$DOMAIN"
fi
if [ "$DO_START" -eq 1 ] && ! dinitctl is-started --quiet "$SERVICE" >/dev/null 2>&1; then
    say "note: $SERVICE is not running; see  dinitctl status $SERVICE"
fi
