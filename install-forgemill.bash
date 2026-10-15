#!/usr/bin/env bash
# ForgeMill installer for fresh Ubuntu 22.04, 24.04 and 26.04 LTS (amd64).
# Run: sudo bash install-forgemill.bash
# Rerun this file to install the newest stable release, preserving all data.
# No backups, local source builds, external database or automatic app upgrades.
# Optional patched image is built separately using this repository's GitHub Actions.
set -Eeuo pipefail
umask 077
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
export DEBIAN_FRONTEND=noninteractive

readonly APP_DIR=/opt/forgemill
readonly OFFICIAL_REPOSITORY=ghcr.io/blink-zero/forgemill
REPOSITORY=$OFFICIAL_REPOSITORY
CUSTOM_IMAGE=''
IMAGE_SOURCE_EXPLICIT=0
readonly OWNER_LABEL=io.forgemill.installer
DOCKER=(docker --host unix:///var/run/docker.sock)
TMP_DIR=''
PORT=''
BIND_IP=''
FRESH=1
NEW_DATABASE=1

log() { printf '\n[ForgeMill] %s\n' "$*"; }
die() { printf '\nERROR: %s\n' "$*" >&2; exit 1; }
cleanup() {
    # Only the private, installer-created temporary directory is removed.
    if [[ $TMP_DIR == /tmp/forgemill-install.* && -d $TMP_DIR ]]; then
        rm -rf -- "$TMP_DIR"
    fi
}
trap cleanup EXIT
trap 'printf "\nERROR: Installation stopped at line %s. Fix the reported error and rerun.\n" "$LINENO" >&2' ERR

usage() {
    cat <<'HELP'
Usage: sudo bash install-forgemill.bash [--port 8443] [--bind 0.0.0.0]

Installs the latest stable GitHub release on Ubuntu 22.04/24.04/26.04 amd64.
Default URL: https://SERVER-IP:8443 (a generated self-signed certificate).
Prints the admin login after startup and checks the generated password.

Rerun to update. Existing data, secrets, certificate, port and chosen image are preserved.
--port NUMBER    HTTPS host port (1-65535); default 8443 on first install.
--bind IPV4      Host IPv4 address; default 0.0.0.0 on first install.
--image IMAGE    Opt in to pinned ghcr.io/howard-99/forgemill-syncfix:VERSION.
--official-image Return to upstream official latest stable releases.
--help          Show this help.

Installation and persistent data: /opt/forgemill
No scheduled backups or unattended application upgrades are installed.
Updates restart ForgeMill; run them when deployments/builds are idle.
HELP
}

valid_ipv4() {
    local value=$1 part
    local -a parts
    [[ $value =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || return 1
    IFS=. read -r -a parts <<< "$value"
    for part in "${parts[@]}"; do
        (( 10#$part <= 255 )) || return 1
        # Keep addresses canonical, avoiding octal/address parsing differences.
        [[ $part == 0 || $part != 0* ]] || return 1
    done
}

while (($#)); do
    case $1 in
        --help|-h) usage; exit 0 ;;
        --port) (($# >= 2)) || die '--port needs a number.'; PORT=$2; shift 2 ;;
        --bind) (($# >= 2)) || die '--bind needs an IPv4 address.'; BIND_IP=$2; shift 2 ;;
        --image) (($# >= 2)) || die '--image needs a pinned image reference.'; CUSTOM_IMAGE=$2; IMAGE_SOURCE_EXPLICIT=1; shift 2 ;;
        --official-image) CUSTOM_IMAGE=''; IMAGE_SOURCE_EXPLICIT=1; shift ;;
        *) die "Unknown argument: $1 (use --help)." ;;
    esac
done
if [[ -n $PORT ]]; then
    [[ $PORT =~ ^[0-9]{1,5}$ ]] || die 'Invalid port.'
    (( 10#$PORT >= 1 && 10#$PORT <= 65535 )) || die 'Port must be 1-65535.'
    PORT=$((10#$PORT))
fi
if [[ -n $BIND_IP ]]; then valid_ipv4 "$BIND_IP" || die 'Invalid IPv4 bind address.'; fi
(( EUID == 0 )) || die 'Run with sudo bash install-forgemill.bash.'
[[ -r /etc/os-release ]] || die 'Cannot identify the operating system.'
# shellcheck source=/dev/null
. /etc/os-release
[[ ${ID:-} == ubuntu ]] || die 'This installer requires Ubuntu.'
case ${VERSION_ID:-} in
    22.04|24.04|26.04) ;;
    *) die 'Supported releases: Ubuntu 22.04, 24.04 and 26.04 LTS.' ;;
esac
[[ $(dpkg --print-architecture) == amd64 ]] || die 'ForgeMill currently publishes only linux/amd64 images; use an x86-64 server.'
[[ -d /run/systemd/system ]] || die 'A booted Ubuntu system with systemd is required.'
command -v flock >/dev/null || die 'The Ubuntu util-linux package (flock) is required.'
exec 9>/run/lock/forgemill-installer.lock
flock -n 9 || die 'Another ForgeMill installer is running.'
[[ ! -L $APP_DIR ]] || die "$APP_DIR must not be a symlink."
if [[ -d $APP_DIR ]]; then
    if [[ -f $APP_DIR/.managed-by-installer ]]; then
        [[ $(cat "$APP_DIR/.managed-by-installer") == forgemill-installer-v1 ]] || die 'Unknown installation marker.'
        FRESH=0
    elif [[ -n $(find "$APP_DIR" -mindepth 1 -maxdepth 1 -print -quit) ]]; then
        die "$APP_DIR already contains an unmanaged installation; refusing to replace it."
    fi
fi

log "Preparing Ubuntu ${VERSION_ID} dependencies."
apt-get -o Acquire::Retries=3 -o DPkg::Lock::Timeout=180 update
apt-get -o Acquire::Retries=3 -o DPkg::Lock::Timeout=180 install -y --no-install-recommends ca-certificates curl openssl jq iproute2
TMP_DIR=$(mktemp -d /tmp/forgemill-install.XXXXXXXX)

if ! command -v docker >/dev/null; then
    # Refuse to remove another runtime as a side effect of installing ForgeMill.
    for package in docker.io docker-compose docker-compose-v2 podman-docker containerd runc; do
        if [[ $(dpkg-query -W -f='${Status}' "$package" 2>/dev/null || true) == 'install ok installed' ]]; then
            die "Conflicting package $package is installed. Use a fresh server or resolve the Docker package conflict first."
        fi
    done
    log 'Installing Docker Engine from its official stable Ubuntu repository.'
    install -d -m 0755 /etc/apt/keyrings
    curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 \
        --retry 3 --connect-timeout 15 --max-time 120 \
        https://download.docker.com/linux/ubuntu/gpg -o "$TMP_DIR/docker.asc"
    install -m 0644 "$TMP_DIR/docker.asc" /etc/apt/keyrings/docker.asc
    cat > /etc/apt/sources.list.d/docker.sources <<DOCKER_REPO
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: ${UBUNTU_CODENAME:-${VERSION_CODENAME}}
Components: stable
Architectures: amd64
Signed-By: /etc/apt/keyrings/docker.asc
DOCKER_REPO
    apt-get -o Acquire::Retries=3 -o DPkg::Lock::Timeout=180 update
    # Compose, Buildx and development toolchains are unnecessary for one container.
    apt-get -o Acquire::Retries=3 -o DPkg::Lock::Timeout=180 install -y --no-install-recommends docker-ce docker-ce-cli containerd.io
fi
systemctl enable --now docker.service
"${DOCKER[@]}" info >/dev/null

if "${DOCKER[@]}" container inspect forgemill > "$TMP_DIR/container.json" 2>/dev/null; then
    [[ $(jq -r '.[0].Config.Labels["io.forgemill.installer"] // ""' "$TMP_DIR/container.json") == v1 && $FRESH == 0 ]] || die 'An unmanaged container named forgemill exists; refusing to replace it.'
fi

if [[ -f $APP_DIR/settings.json ]]; then
    PORT=${PORT:-$(jq -er '.port' "$APP_DIR/settings.json")}
    BIND_IP=${BIND_IP:-$(jq -er '.bind' "$APP_DIR/settings.json")}
    if (( ! IMAGE_SOURCE_EXPLICIT )); then
        CUSTOM_IMAGE=$(jq -r '.image // ""' "$APP_DIR/settings.json")
    fi
fi
PORT=${PORT:-8443}
BIND_IP=${BIND_IP:-0.0.0.0}
[[ $PORT =~ ^[0-9]{1,5}$ ]] || die 'Invalid stored port.'
if (( 10#$PORT < 1 || 10#$PORT > 65535 )); then die 'Invalid stored port.'; fi
PORT=$((10#$PORT))
valid_ipv4 "$BIND_IP" || die 'Invalid stored bind address.'
# Detect an occupied port before downloading or stopping the existing service.
if ss -H -ltn "sport = :$PORT" | grep -q .; then
    if [[ ! -s $TMP_DIR/container.json ]] || ! jq -e --arg port "$PORT" \
        '.[0].HostConfig.PortBindings["8080/tcp"] | any(.HostPort == $port)' \
        "$TMP_DIR/container.json" >/dev/null; then
        die "TCP port $PORT is already in use. Choose another with --port NUMBER."
    fi
fi

if [[ -n $CUSTOM_IMAGE ]]; then
    # Do not permit arbitrary Docker registries or floating tags from CLI/JSON.
    # An opt-in patched image must have a fixed semver tag in this account.
    [[ $CUSTOM_IMAGE =~ ^ghcr\.io/howard-99/forgemill-syncfix:[0-9]+\.[0-9]+\.[0-9]+$ ]] ||
        die 'Only pinned ghcr.io/howard-99/forgemill-syncfix:VERSION images are supported by --image.'
    REPOSITORY=${CUSTOM_IMAGE%:*}
    IMAGE_TAG=$CUSTOM_IMAGE
    RELEASE="v${CUSTOM_IMAGE##*:}-syncfix"
    log "Opt-in patched image selected: $IMAGE_TAG"
else
    log 'Resolving the newest stable ForgeMill release from GitHub.'
    curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 \
        --retry 3 --connect-timeout 15 --max-time 120 \
        -H 'Accept: application/vnd.github+json' -H 'X-GitHub-Api-Version: 2022-11-28' \
        https://api.github.com/repos/blink-zero/forgemill/releases/latest -o "$TMP_DIR/release.json"
    RELEASE=$(jq -er 'select(.draft == false and .prerelease == false) | .tag_name' "$TMP_DIR/release.json")
    [[ $RELEASE =~ ^v?[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "Unexpected release tag: $RELEASE"
    # docker/metadata-action publishes semver image tags without the Git tag's v.
    IMAGE_TAG="$REPOSITORY:${RELEASE#v}"
fi
log "Downloading $RELEASE ($IMAGE_TAG)."
pulled=0
for attempt in 1 2 3; do
    if "${DOCKER[@]}" pull "$IMAGE_TAG"; then pulled=1; break; fi
    if (( attempt < 3 )); then sleep 10; fi
done
(( pulled == 1 )) || die 'The release image could not be pulled. It may still be publishing; rerun later. The existing container was not stopped.'
IMAGE_ID=$("${DOCKER[@]}" image inspect --format '{{.Id}}' "$IMAGE_TAG")
IMAGE_DIGEST=$("${DOCKER[@]}" image inspect --format '{{index .RepoDigests 0}}' "$IMAGE_TAG")
[[ $IMAGE_DIGEST == "$REPOSITORY"@sha256:* ]] || die 'Cannot resolve the downloaded image digest.'
[[ $("${DOCKER[@]}" image inspect --format '{{.Architecture}}' "$IMAGE_TAG") == amd64 ]] || die 'Unexpected image architecture.'

install -d -m 0700 "$APP_DIR"
if (( FRESH )); then
    printf '%s\n' forgemill-installer-v1 > "$APP_DIR/.managed-by-installer"
fi
install -d -m 0700 "$APP_DIR/data"
# App data is owned by the unprivileged UID used by the official image.
chown 1001:1001 "$APP_DIR/data"
if [[ -s $APP_DIR/data/forgemill.db ]]; then NEW_DATABASE=0; fi
install -d -m 0750 -o root -g 1001 "$APP_DIR/secrets" "$APP_DIR/tls"
for name in jwt_secret encryption_key admin_password; do
    secret="$APP_DIR/secrets/$name"
    if [[ ! -s $secret ]]; then
        (( NEW_DATABASE )) || die "Missing $secret. Restore the original secret; it must never be regenerated over an existing database."
        openssl rand -hex 32 > "$secret"
    fi
    chown root:1001 "$secret"
    chmod 0640 "$secret"
done

SERVER_IP=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") {print $(i+1); exit}}' || true)
SERVER_IP=${SERVER_IP:-127.0.0.1}
if [[ $BIND_IP != 0.0.0.0 ]]; then SERVER_IP=$BIND_IP; fi
if [[ ! -s $APP_DIR/tls/server.crt || ! -s $APP_DIR/tls/server.key ]]; then
    log 'Generating the HTTPS certificate (valid for 10 years).'
    SAN='DNS:localhost,IP:127.0.0.1'
    while IFS= read -r address; do
        if valid_ipv4 "$address" && [[ $address != 127.0.0.1 ]]; then SAN+=",IP:$address"; fi
    done < <(ip -o -4 address show | awk '{split($4,a,"/"); print a[1]}')
    openssl req -x509 -newkey rsa:3072 -sha256 -nodes -days 3650 \
        -subj '/CN=ForgeMill' -addext "subjectAltName=$SAN" \
        -keyout "$TMP_DIR/server.key" -out "$TMP_DIR/server.crt" 2>/dev/null
    install -m 0640 -o root -g 1001 "$TMP_DIR/server.key" "$APP_DIR/tls/server.key"
    install -m 0644 "$TMP_DIR/server.crt" "$APP_DIR/tls/server.crt"
fi
# Verify the pair before stopping a working container.
openssl x509 -in "$APP_DIR/tls/server.crt" -noout -checkend 86400 >/dev/null || die 'The HTTPS certificate expires within a day. Replace the certificate and key, then rerun.'
openssl x509 -in "$APP_DIR/tls/server.crt" -pubkey -noout > "$TMP_DIR/cert.pub"
openssl pkey -in "$APP_DIR/tls/server.key" -pubout > "$TMP_DIR/key.pub" 2>/dev/null
cmp -s "$TMP_DIR/cert.pub" "$TMP_DIR/key.pub" || die 'The HTTPS certificate and key do not match.'
chown root:1001 "$APP_DIR/tls/server.key"
chmod 0640 "$APP_DIR/tls/server.key"
CORS_ORIGINS="https://localhost:$PORT,https://127.0.0.1:$PORT,https://$SERVER_IP:$PORT"

OLD_TAG=''
OLD_DIGEST=''
OLD_ID=''
if [[ -f $APP_DIR/installed-image.json ]]; then
    OLD_TAG=$(jq -r '.tag // ""' "$APP_DIR/installed-image.json")
    OLD_DIGEST=$(jq -r '.digest // ""' "$APP_DIR/installed-image.json")
    OLD_ID=$(jq -r '.id // ""' "$APP_DIR/installed-image.json")
fi
# Commit settings before first startup, so an interrupted run is repeatable.
jq -n --argjson port "$PORT" --arg bind "$BIND_IP" --arg image "$CUSTOM_IMAGE" \
    '{port:$port,bind:$bind,image:$image}' > "$TMP_DIR/settings.json"
install -m 0600 "$TMP_DIR/settings.json" "$APP_DIR/settings.json"
log 'Starting ForgeMill with persistent data and bounded logs.'
if "${DOCKER[@]}" container inspect forgemill >/dev/null 2>&1; then
    "${DOCKER[@]}" stop --time 45 forgemill >/dev/null
    "${DOCKER[@]}" rm forgemill >/dev/null
fi
"${DOCKER[@]}" run -d --name forgemill \
    --label "$OWNER_LABEL=v1" --restart unless-stopped --init \
    --user 1001:1001 --read-only --cap-drop ALL --security-opt no-new-privileges:true \
    --stop-timeout 45 --pids-limit 512 --memory 2g --cpus 2 \
    --log-driver json-file --log-opt max-size=10m --log-opt max-file=3 \
    --publish "$BIND_IP:$PORT:8080" \
    --mount "type=bind,src=$APP_DIR/data,dst=/app/data" \
    --mount "type=bind,src=$APP_DIR/secrets,dst=/run/secrets,readonly" \
    --mount "type=bind,src=$APP_DIR/tls,dst=/run/tls,readonly" \
    --tmpfs /tmp:rw,noexec,nosuid,nodev,size=64m,mode=1777 \
    --tmpfs /home/forgemill/.config:rw,nosuid,nodev,size=16m,uid=1001,gid=1001,mode=0700 \
    --tmpfs /home/forgemill/.cache:rw,nosuid,nodev,size=32m,uid=1001,gid=1001,mode=0700 \
    --env FORGEMILL_ADMIN_USER=admin \
    --env FORGEMILL_ADMIN_PASSWORD_FILE=/run/secrets/admin_password \
    --env FORGEMILL_JWT_SECRET_FILE=/run/secrets/jwt_secret \
    --env FORGEMILL_ENCRYPTION_KEY_FILE=/run/secrets/encryption_key \
    --env FORGEMILL_TLS_CERT=/run/tls/server.crt --env FORGEMILL_TLS_KEY=/run/tls/server.key \
    --env "FORGEMILL_CORS_ORIGINS=$CORS_ORIGINS" --env FORGEMILL_LOG_LEVEL=info \
    --health-cmd 'wget -q --no-check-certificate -O /dev/null https://127.0.0.1:8080/api/version || exit 1' \
    --health-interval 30s --health-timeout 5s --health-start-period 30s --health-retries 3 \
    "$IMAGE_DIGEST" >/dev/null

CHECK_IP=$BIND_IP
[[ $CHECK_IP != 0.0.0.0 ]] || CHECK_IP=127.0.0.1
ready=0
for ((attempt=1; attempt<=60; attempt++)); do
    status=$("${DOCKER[@]}" inspect --format '{{.State.Status}} {{.State.Health.Status}}' forgemill)
    if [[ $status == 'running healthy' ]] && \
        curl --fail --silent --show-error --noproxy '*' --cacert "$APP_DIR/tls/server.crt" \
            --connect-timeout 2 --max-time 5 "https://$CHECK_IP:$PORT/api/version" \
            -o "$TMP_DIR/version.json" 2>/dev/null && \
        jq -e '(.version | type) == "string"' "$TMP_DIR/version.json" >/dev/null; then
        ready=1; break
    fi
    sleep 3
done
(( ready )) || die 'ForgeMill did not become healthy. Inspect with: sudo docker logs --tail 50 forgemill. Data and secrets have been preserved.'

# Send the password through a private file, never a command-line argument.
jq -n --rawfile password "$APP_DIR/secrets/admin_password" \
    '{username:"admin",password:($password | rtrimstr("\n"))}' > "$TMP_DIR/login.json"
LOGIN_CODE=$(curl --silent --show-error --noproxy '*' --cacert "$APP_DIR/tls/server.crt" \
    --connect-timeout 5 --max-time 20 --output /dev/null --write-out '%{http_code}' \
    -H 'Content-Type: application/json' --data-binary "@$TMP_DIR/login.json" \
    "https://$CHECK_IP:$PORT/api/auth/login")
if [[ $LOGIN_CODE != 200 ]]; then
    if (( NEW_DATABASE )) || [[ $LOGIN_CODE != 401 ]]; then die "Admin login verification failed (HTTP $LOGIN_CODE). Credentials have not been advertised as working."; fi
fi

# Docker restarts exited processes. This tiny timer also recovers a running,
# unhealthy app; it respects intentional stops and checks ownership.
cat > "$APP_DIR/check-health.bash" <<'HEALTH'
#!/usr/bin/env bash
set -eu
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
# Skip checks while the installer is replacing the container.
exec 9>/run/lock/forgemill-installer.lock
flock -n 9 || exit 0
docker=(docker --host unix:///var/run/docker.sock)
state=$("${docker[@]}" inspect --format '{{index .Config.Labels "io.forgemill.installer"}} {{.State.Status}} {{if .State.Health}}{{.State.Health.Status}}{{end}}' forgemill 2>/dev/null) || exit 0
if [[ $state == 'v1 running unhealthy' ]]; then
    "${docker[@]}" restart --time 45 forgemill >/dev/null
fi
HEALTH
chmod 0700 "$APP_DIR/check-health.bash"
cat > /etc/systemd/system/forgemill-health.service <<'SERVICE'
[Unit]
Description=Recover an unhealthy ForgeMill container
After=docker.service
[Service]
Type=oneshot
ExecStart=/opt/forgemill/check-health.bash
TimeoutStartSec=90
StandardOutput=null
SERVICE
cat > /etc/systemd/system/forgemill-health.timer <<'TIMER'
[Unit]
Description=Check ForgeMill health every two minutes
[Timer]
OnBootSec=3min
OnUnitActiveSec=2min
AccuracySec=15s
[Install]
WantedBy=timers.target
TIMER
systemctl daemon-reload
systemctl enable --now forgemill-health.timer

jq -n --arg tag "$IMAGE_TAG" --arg digest "$IMAGE_DIGEST" --arg id "$IMAGE_ID" \
    '{tag:$tag,digest:$digest,id:$id}' > "$TMP_DIR/installed-image.json"
install -m 0600 "$TMP_DIR/installed-image.json" "$APP_DIR/installed-image.json"
if [[ $(readlink -f -- "$0") != "$APP_DIR/install.bash" ]]; then
    install -m 0700 -- "$0" "$APP_DIR/install.bash"
fi
# Reclaim ONLY this install's previous image after the new one passes checks.
# Never force removal, prune Docker globally, delete volumes, or copy the DB.
if [[ -n $OLD_ID && $OLD_ID != "$IMAGE_ID" ]]; then
    for ref in "$OLD_TAG" "$OLD_DIGEST"; do
        if [[ $ref == "$REPOSITORY":* || $ref == "$REPOSITORY"@sha256:* ]]; then
            "${DOCKER[@]}" image rm "$ref" >/dev/null 2>&1 || true
        fi
    done
fi
apt-get clean

printf '\nForgeMill is ready.\n'
printf 'Release:  %s\nURL:      https://%s:%s\nUsername: admin\n' "$RELEASE" "$SERVER_IP" "$PORT"
if [[ $LOGIN_CODE == 200 ]]; then
    printf 'Password: %s\n' "$(cat "$APP_DIR/secrets/admin_password")"
    printf 'Login verified successfully.\n'
else
    printf 'Password: use your existing password (the initial one has been changed or the account renamed/disabled).\n'
fi
printf '\nHTTPS uses a self-signed certificate; trust /opt/forgemill/tls/server.crt in your browser.\n'
printf 'Data and keys: /opt/forgemill (required application storage; no backup copies).\n'
printf 'Container logs rotate at 3 x 10 MB. No automatic application upgrades.\n'
if [[ -n $CUSTOM_IMAGE ]]; then
    printf 'Patched image pinned: %s\n' "$CUSTOM_IMAGE"
    printf 'Switch to official stable: sudo bash /opt/forgemill/install.bash --official-image\n'
else
    printf 'Update to the newest stable release: sudo bash /opt/forgemill/install.bash\n'
fi
printf 'Initial password file: sudo cat /opt/forgemill/secrets/admin_password\n'
