#!/usr/bin/env bash
# Install or update Zigveil from a prebuilt image on a Debian/Ubuntu systemd host.
# First install: SNI=example.com BACKEND=203.0.113.10:443 bash install_docker_compose.sh
# Alternatively use CONFIG_SOURCE=/path/to/config.json. Existing config is retained.
set -euo pipefail
umask 077

INSTALL_DIR="${INSTALL_DIR:-/opt/zigveil}"
REPO_RAW_URL="${REPO_RAW_URL:-https://raw.githubusercontent.com/XXcipherX/zigveil/main}"
DEFAULT_IMAGE_REPO="${DEFAULT_IMAGE_REPO:-ghcr.io/xxcipherx/zigveil}"
DEFAULT_IMAGE_TAG="${DEFAULT_IMAGE_TAG:-latest}"
IMAGE="${IMAGE:-}"
AUTO_IMAGE_CPU_VARIANT="${AUTO_IMAGE_CPU_VARIANT:-true}"
INSTALL_DOCKER="${INSTALL_DOCKER:-true}"
NOFILE_LIMIT="${NOFILE_LIMIT:-65536}"
LISTEN="${LISTEN:-0.0.0.0:443}"
SERVICE_NAME=zigveil
SERVICE_FILE=/etc/systemd/system/zigveil.service
work=""

info() { printf 'zigveil: %s\n' "$*"; }
fail() { printf 'zigveil: %s\n' "$*" >&2; exit 1; }
cleanup() {
    case "$work" in "$INSTALL_DIR"/.install.*) rm -rf -- "$work" ;; esac
}
trap cleanup EXIT

host_supports_v3() {
    [[ "$(uname -m)" == x86_64 && -r /proc/cpuinfo ]] || return 1
    local flags flag
    flags="$(awk -F: '/^flags[[:space:]]*:/ { print " " $2 " "; exit }' /proc/cpuinfo)"
    for flag in cx16 lahf_lm popcnt pni ssse3 sse4_1 sse4_2 avx avx2 bmi1 bmi2 f16c fma movbe xsave; do
        [[ "$flags" == *" $flag "* ]] || return 1
    done
    [[ "$flags" == *" lzcnt "* || "$flags" == *" abm "* ]]
}

install_tools() {
    local missing=false tool
    for tool in curl jq flock; do command -v "$tool" >/dev/null || missing=true; done
    if "$missing"; then
        command -v apt-get >/dev/null || fail "Install curl, jq and util-linux first"
        apt-get update < /dev/null
        DEBIAN_FRONTEND=noninteractive apt-get install -y ca-certificates curl jq util-linux < /dev/null
    fi
    if ! command -v docker >/dev/null || ! docker compose version >/dev/null 2>&1; then
        [[ "$INSTALL_DOCKER" == true ]] || fail "Docker Engine and Compose v2 are required"
        info "Installing Docker Engine and Compose v2"
        curl -fsSL --retry 3 https://get.docker.com -o "$work/get-docker.sh"
        sh "$work/get-docker.sh" < /dev/null
    fi
    systemctl enable --now docker.service
    docker compose version >/dev/null || fail "Docker Compose v2 is required"
    docker info >/dev/null || fail "Docker daemon is unavailable"
}

[[ $EUID -eq 0 ]] || fail "Run as root"
[[ "$(uname -s)" == Linux ]] || fail "Linux is required"
command -v systemctl >/dev/null || fail "systemd is required"
[[ -d /run/systemd/system ]] || fail "systemd must be running"
[[ "$INSTALL_DIR" =~ ^/[A-Za-z0-9_./-]+$ ]] || fail "INSTALL_DIR must be absolute without whitespace or shell metacharacters"
INSTALL_DIR="$(readlink -m -- "$INSTALL_DIR")"
[[ "$INSTALL_DIR" != / && "$INSTALL_DIR" != /etc && "$INSTALL_DIR" != /usr && "$INSTALL_DIR" != /opt ]] || fail "Choose a dedicated INSTALL_DIR"
[[ "$AUTO_IMAGE_CPU_VARIANT" == true || "$AUTO_IMAGE_CPU_VARIANT" == false ]] || fail "AUTO_IMAGE_CPU_VARIANT must be true or false"
[[ "$INSTALL_DOCKER" == true || "$INSTALL_DOCKER" == false ]] || fail "INSTALL_DOCKER must be true or false"
[[ "$NOFILE_LIMIT" =~ ^[0-9]{1,7}$ ]] || fail "NOFILE_LIMIT must be an integer"
NOFILE_LIMIT=$((10#$NOFILE_LIMIT))
(( NOFILE_LIMIT >= 16 && NOFILE_LIMIT <= 1048576 )) || fail "NOFILE_LIMIT must be 16..1048576"
if [[ -n "${GHCR_USER:-}" && -z "${GHCR_TOKEN:-}" ]] || [[ -z "${GHCR_USER:-}" && -n "${GHCR_TOKEN:-}" ]]; then
    fail "Set both GHCR_USER and GHCR_TOKEN, or neither"
fi
[[ ! -L "$SERVICE_FILE" ]] || fail "Refusing to replace a symlinked service unit"
mkdir -p -- "$INSTALL_DIR"
if ! command -v flock >/dev/null; then
    command -v apt-get >/dev/null || fail "Install util-linux first"
    apt-get update < /dev/null
    DEBIAN_FRONTEND=noninteractive apt-get install -y util-linux < /dev/null
fi
exec 9> "$INSTALL_DIR/.install.lock"
flock -n 9 || fail "Another installer is running"
CONFIG_FILE="$INSTALL_DIR/config.json"
COMPOSE_FILE="$INSTALL_DIR/compose.yml"
ENV_FILE="$INSTALL_DIR/.env"
for file in "$CONFIG_FILE" "$COMPOSE_FILE" "$ENV_FILE"; do
    [[ ! -L "$file" && ( ! -e "$file" || -f "$file" ) ]] || fail "Expected a regular file at $file"
done
if [[ ! -f "$CONFIG_FILE" ]]; then
    if [[ -z "${CONFIG_SOURCE:-}" && -f /etc/zigveil/config.json ]]; then
        CONFIG_SOURCE=/etc/zigveil/config.json
    fi
    if [[ -n "${CONFIG_SOURCE:-}" ]]; then
        [[ -f "$CONFIG_SOURCE" && -r "$CONFIG_SOURCE" ]] || fail "CONFIG_SOURCE must be a readable file"
    else
        [[ -n "${SNI:-}" && -n "${BACKEND:-}" ]] || fail "First install needs CONFIG_SOURCE, or SNI and BACKEND"
    fi
fi
work="$(mktemp -d "$INSTALL_DIR/.install.XXXXXX")"
install_tools
docker_bin="$(command -v docker)"
[[ "$docker_bin" =~ ^/[A-Za-z0-9_./-]+$ ]] || fail "Unexpected Docker executable path"

auto_selected=false
if [[ -z "$IMAGE" ]]; then
    IMAGE="$DEFAULT_IMAGE_REPO:$DEFAULT_IMAGE_TAG"
    if [[ "$AUTO_IMAGE_CPU_VARIANT" == true ]] && host_supports_v3; then
        IMAGE="$IMAGE-amd64-v3"
        auto_selected=true
    fi
fi
[[ "$IMAGE" =~ ^[a-z0-9][A-Za-z0-9._/:@-]+$ ]] || fail "Invalid image reference"
if [[ -n "${GHCR_USER:-}" ]]; then
    printf '%s' "$GHCR_TOKEN" | docker login ghcr.io -u "$GHCR_USER" --password-stdin > /dev/null
fi
info "Pulling $IMAGE"
if ! docker pull "$IMAGE"; then
    if [[ "$auto_selected" != true ]]; then fail "Image pull failed; running service was kept"; fi
    IMAGE="$DEFAULT_IMAGE_REPO:$DEFAULT_IMAGE_TAG"
    [[ "$IMAGE" =~ ^[a-z0-9][A-Za-z0-9._/:@-]+$ ]] || fail "Invalid fallback image reference"
    info "Optimized image unavailable; pulling $IMAGE"
    docker pull "$IMAGE" || fail "Image pull failed; running service was kept"
fi

if [[ -f "$CONFIG_FILE" ]]; then
    candidate="$CONFIG_FILE"
    info "Keeping $CONFIG_FILE"
elif [[ -n "${CONFIG_SOURCE:-}" ]]; then
    cp -- "$CONFIG_SOURCE" "$work/config.json"
    candidate="$work/config.json"
else
    jq -n --arg listen "$LISTEN" --arg sni "$SNI" --arg backend "$BACKEND" \
        '{listen:$listen,routes:[{sni:$sni,backend:$backend}]}' > "$work/config.json"
    candidate="$work/config.json"
fi
curl -fsSL --retry 3 "${REPO_RAW_URL%/}/deploy/compose.yml" -o "$work/compose.yml"
printf 'ZIGVEIL_IMAGE=%s\nZIGVEIL_NOFILE=%s\n' "$IMAGE" "$NOFILE_LIMIT" > "$work/.env"
docker compose --project-name zigveil --project-directory "$INSTALL_DIR" \
    --env-file "$work/.env" -f "$work/compose.yml" config --quiet
info "Checking configuration with the new image"
docker run --rm --network host --read-only --cap-drop ALL --cap-add NET_BIND_SERVICE \
    --security-opt no-new-privileges:true --ulimit "nofile=$NOFILE_LIMIT:$NOFILE_LIMIT" \
    --mount "type=bind,source=$candidate,target=/etc/zigveil/config.json,readonly" \
    "$IMAGE" --check /etc/zigveil/config.json

# Pull and config validation finish before touching a running service.
managed_active=false
if systemctl is-active --quiet "$SERVICE_NAME.service"; then
    if [[ -f "$SERVICE_FILE" ]] && grep -Fxq '# Managed by Zigveil Docker Compose installer.' "$SERVICE_FILE"; then
        managed_active=true
    else
        info "Stopping the native Zigveil service before migration"
        systemctl stop "$SERVICE_NAME.service"
    fi
fi
if [[ ! -f "$CONFIG_FILE" ]]; then
    chmod 0600 "$work/config.json"
    mv -T -- "$work/config.json" "$CONFIG_FILE"
fi
mv -T -- "$work/compose.yml" "$COMPOSE_FILE"
mv -T -- "$work/.env" "$ENV_FILE"
chmod 0600 "$CONFIG_FILE" "$COMPOSE_FILE" "$ENV_FILE"
cat > "$work/zigveil.service" <<EOF
# Managed by Zigveil Docker Compose installer.
[Unit]
Description=Zigveil (Docker Compose)
After=network-online.target docker.service
Wants=network-online.target
Requires=docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=$INSTALL_DIR
ExecStart=$docker_bin compose --project-name zigveil --env-file $ENV_FILE -f $COMPOSE_FILE up -d --wait --wait-timeout 20
ExecReload=$docker_bin compose --project-name zigveil --env-file $ENV_FILE -f $COMPOSE_FILE up -d --force-recreate --no-deps --wait --wait-timeout 20 zigveil
ExecStop=$docker_bin compose --project-name zigveil --env-file $ENV_FILE -f $COMPOSE_FILE down
TimeoutStartSec=90s
TimeoutStopSec=45s

[Install]
WantedBy=multi-user.target
EOF
install -m 0644 "$work/zigveil.service" "$SERVICE_FILE"
systemctl daemon-reload
systemctl enable "$SERVICE_NAME.service"
if [[ "$managed_active" == true ]]; then
    systemctl reload "$SERVICE_NAME.service"
else
    systemctl start "$SERVICE_NAME.service"
fi
systemctl is-active --quiet "$SERVICE_NAME.service" || fail "Service is not active; inspect journalctl -u zigveil"
ready=false
for ((attempt=0; attempt<20; attempt++)); do
    container="$(docker compose --project-name zigveil --env-file "$ENV_FILE" -f "$COMPOSE_FILE" ps --all --quiet zigveil)"
    pid="$(docker inspect --format '{{.State.Pid}}' "$container" 2>/dev/null || true)"
    if [[ "$pid" =~ ^[1-9][0-9]*$ ]]; then
        # Listener readiness must work at warn/error/none too. Match a LISTEN
        # inode owned by this container process without creating probe traffic.
        if { readlink /proc/"$pid"/fd/* 2>/dev/null || true; } | awk '
            FILENAME == "-" {
                if ($0 ~ /^socket:\[[0-9]+\]$/) {
                    gsub(/^socket:\[|\]$/, ""); owned[$0] = 1
                }
                next
            }
            $4 == "0A" && owned[$10] { ready = 1 }
            END { exit !ready }
        ' - "/proc/$pid/net/tcp" "/proc/$pid/net/tcp6" 2>/dev/null; then
            ready=true
            break
        fi
    fi
    sleep 1
done
[[ "$ready" == true ]] || fail "Listener did not start; inspect Docker Compose logs"
info "Installed $IMAGE"
info "Config: $CONFIG_FILE"
info "Status: systemctl status zigveil"
info "Logs: cd $INSTALL_DIR && docker compose --env-file .env -f compose.yml logs -f"
