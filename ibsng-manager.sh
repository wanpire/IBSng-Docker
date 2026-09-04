#!/usr/bin/env bash
#
# ═══════════════════════════════════════════════════════════════
#  IBSng — Docker build & management (from source)
#
#  Run:  sudo bash ibsng-manager.sh
#  (must be run from this folder — it needs Dockerfile + files/)
# ═══════════════════════════════════════════════════════════════

set -euo pipefail

R='\033[0;31m'; G='\033[0;32m'; Y='\033[1;33m'; B='\033[0;36m'; N='\033[0m'
ok()   { echo -e "${G}✅ $1${N}"; }
info() { echo -e "${B}ℹ️  $1${N}"; }
warn() { echo -e "${Y}⚠️  $1${N}"; }
err()  { echo -e "${R}❌ $1${N}"; }

IMAGE_NAME="ibsng-local:latest"
CONTAINER="ibsng"
VOLUME="ibsng_pgdata"
PG_MOUNT="/var/lib/postgresql"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# HTTPS (see Dockerfile note 11 / HA.md): these two host paths are bind-
# mounted into every container regardless of whether SERVER_DOMAIN is
# set, so enabling HTTPS later never requires recreating the container
# with different mounts — just get a cert into $LETSENCRYPT_DIR and
# restart. $WEBROOT_DIR is where certbot's webroot plugin writes ACME
# challenge files; $LETSENCRYPT_DIR is mounted read-only since the
# container only ever reads certs, never issues/renews them itself.
WEBROOT_DIR="/var/www/certbot-webroot"
LETSENCRYPT_DIR="/etc/letsencrypt"

require_root() {
    if [ "$(id -u)" -ne 0 ]; then
        err "Run this as root (sudo bash ibsng-manager.sh)."
        exit 1
    fi
}

pause() { echo ""; read -rp "$(echo -e "${Y}Press Enter to continue...${N}")" _; }

ask_port() {
    local prompt="$1" default="$2" var
    while true; do
        read -rp "$(echo -e "${Y}${prompt}${N} [default ${default}]: ")" var
        var="${var:-$default}"
        if ! [[ "$var" =~ ^[0-9]+$ ]] || [ "$var" -lt 1 ] || [ "$var" -gt 65535 ]; then
            err "Invalid port. Enter a number between 1 and 65535."
            continue
        fi
        echo "$var"
        return
    done
}

container_exists()  { docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx "$1"; }
container_running() { docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$1"; }

install_docker() {
    if command -v docker >/dev/null 2>&1; then
        ok "Docker is already installed ($(docker --version | cut -d, -f1))."
        return
    fi
    info "Docker is not installed. Installing..."
    apt-get update -y
    apt-get install -y ca-certificates curl gnupg
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    chmod a+r /etc/apt/keyrings/docker.gpg
    . /etc/os-release
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu ${VERSION_CODENAME} stable" \
        > /etc/apt/sources.list.d/docker.list
    apt-get update -y
    apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
    systemctl enable --now docker
    ok "Docker installed and started."
}

build_image() {
    info "Building the IBSng image from source (this downloads and compiles IBSng — can take a few minutes)..."
    if ! docker build -t "$IMAGE_NAME" "$SCRIPT_DIR"; then
        err "Build failed. Common cause: the SourceForge download URL changed."
        err "Check https://sourceforge.net/projects/ibsng/files/ for the current filename and rebuild with:"
        err "  docker build --build-arg IBSNG_URL=<direct .tar.bz2 link> -t $IMAGE_NAME $SCRIPT_DIR"
        return 1
    fi
    ok "Image built: $IMAGE_NAME"
}

ibsng_install() {
    install_docker
    build_image || { pause; return; }

    echo ""
    info "Enter ports (press Enter to accept defaults):"
    local WEB_PORT API_PORT AUTH_PORT ACCT_PORT ADMIN_PASS
    WEB_PORT=$(ask_port "Web port (IBSng admin panel)" 80)
    API_PORT=$(ask_port "API port (XML-RPC)" 1235)
    AUTH_PORT=$(ask_port "RADIUS Authentication port (UDP)" 1812)
    ACCT_PORT=$(ask_port "RADIUS Accounting port (UDP)" 1813)
    echo ""
    read -rp "$(echo -e "${Y}Admin password for the 'system' account [default: admin]: ${N}")" ADMIN_PASS
    ADMIN_PASS="${ADMIN_PASS:-admin}"

    echo ""
    info "HTTPS (Let's Encrypt) — leave blank to skip and use plain HTTP only."
    info "You can add this later: rerun Install, or just set it up manually and"
    info "restart the container — see HA.md for the certbot side of this."
    local SERVER_DOMAIN
    read -rp "$(echo -e "${Y}Public domain name for this server (e.g. ibsng.example.com) [none]: ${N}")" SERVER_DOMAIN

    echo ""
    info "Port summary:"
    echo -e "   Web:         ${G}$WEB_PORT${N}  → 80/tcp"
    [ -n "$SERVER_DOMAIN" ] && echo -e "   HTTPS:       ${G}443${N} → 443/tcp (domain: ${SERVER_DOMAIN})"
    echo -e "   API:         ${G}$API_PORT${N}  → 1235/tcp"
    echo -e "   RADIUS auth: ${G}$AUTH_PORT${N} → 1812/udp"
    echo -e "   RADIUS acct: ${G}$ACCT_PORT${N} → 1813/udp"
    echo ""
    local confirm
    read -rp "$(echo -e "${Y}Proceed? (y/n): ${N}")" confirm
    [ "$confirm" != "y" ] && { warn "Cancelled."; return; }

    if container_exists "$CONTAINER"; then
        warn "A container named '$CONTAINER' already exists."
        local re
        read -rp "$(echo -e "${Y}Remove and reinstall? (volume data is kept) (y/n): ${N}")" re
        [ "$re" = "y" ] && docker rm -f "$CONTAINER" || { warn "Cancelled."; return; }
    fi

    docker volume create "$VOLUME" >/dev/null
    ok "Persistent volume '$VOLUME' ready (Postgres data survives restarts/updates)."
    mkdir -p "$WEBROOT_DIR"

    info "Starting container..."
    docker run -d \
        --name "$CONTAINER" \
        --restart unless-stopped \
        -p "${WEB_PORT}:80/tcp" \
        -p 443:443/tcp \
        -p "${API_PORT}:1235/tcp" \
        -p "${AUTH_PORT}:1812/udp" \
        -p "${ACCT_PORT}:1813/udp" \
        -e IBSNG_ADMIN_PASSWORD="${ADMIN_PASS}" \
        -e SERVER_DOMAIN="${SERVER_DOMAIN}" \
        -v "${VOLUME}:${PG_MOUNT}" \
        -v "${WEBROOT_DIR}:/var/www/html" \
        -v "${LETSENCRYPT_DIR}:${LETSENCRYPT_DIR}:ro" \
        "$IMAGE_NAME"

    info "Waiting for first-boot install (Postgres init + IBSng setup wizard)..."
    sleep 25
    if container_running "$CONTAINER"; then
        ok "Container started!"
    else
        err "Container failed to start. Logs:"
        docker logs "$CONTAINER" 2>&1 | tail -40
        pause; return
    fi

    local SERVER_IP
    SERVER_IP=$(hostname -I 2>/dev/null | awk '{print $1}')
    echo ""
    echo -e "${G}═══════════════════════════════════════════════${N}"
    echo -e "${G}          IBSng installation complete ✅${N}"
    echo -e "${G}═══════════════════════════════════════════════${N}"
    echo -e "🌐 Web panel: ${B}http://${SERVER_IP}:${WEB_PORT}/IBSng/admin${N}"
    if [ -n "$SERVER_DOMAIN" ]; then
        warn "SERVER_DOMAIN=${SERVER_DOMAIN} is set, but HTTPS won't actually turn on until a"
        warn "cert exists at ${LETSENCRYPT_DIR}/live/${SERVER_DOMAIN}/ on this host — run certbot"
        warn "against ${WEBROOT_DIR} (the webroot plugin), then 'docker restart ${CONTAINER}'."
    fi
    echo -e "🔌 API (XML-RPC): port ${B}${API_PORT}${N}"
    echo -e "📡 RADIUS auth/acct: ${B}${AUTH_PORT}/udp${N} / ${B}${ACCT_PORT}/udp${N}"
    echo -e "👤 Login: ${Y}system${N} / ${Y}${ADMIN_PASS}${N}"
    echo ""
    warn "First boot runs IBSng's own install wizard automatically — check 'Live Log'"
    warn "(menu option 3) if the panel doesn't load right away; the wizard was written"
    warn "for CentOS/RedHat and may need a manual finishing touch on Debian/Ubuntu."
    pause
}

show_status() {
    if container_exists "$CONTAINER"; then
        echo ""
        docker ps -a --filter "name=^/${CONTAINER}\$" --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
        echo ""
    else
        warn "Container '$CONTAINER' is not installed yet."
    fi
    pause
}

show_live_log() {
    if ! container_exists "$CONTAINER"; then
        warn "Container '$CONTAINER' is not installed yet."; pause; return
    fi
    info "Showing live logs — press Ctrl+C to exit."
    exec docker logs --tail 200 -f "$CONTAINER"
}

restart_container() {
    if container_exists "$CONTAINER"; then
        docker restart "$CONTAINER" >/dev/null && ok "Restarted."
    else
        warn "Container '$CONTAINER' is not installed yet."
    fi
    pause
}

ibsng_update() {
    if ! container_exists "$CONTAINER"; then
        warn "Not installed yet. Use Install first."; pause; return
    fi
    local WEB_PORT API_PORT AUTH_PORT ACCT_PORT SERVER_DOMAIN
    WEB_PORT=$(docker port "$CONTAINER" 80/tcp 2>/dev/null | head -1 | sed 's/.*://')
    API_PORT=$(docker port "$CONTAINER" 1235/tcp 2>/dev/null | head -1 | sed 's/.*://')
    AUTH_PORT=$(docker port "$CONTAINER" 1812/udp 2>/dev/null | head -1 | sed 's/.*://')
    ACCT_PORT=$(docker port "$CONTAINER" 1813/udp 2>/dev/null | head -1 | sed 's/.*://')
    WEB_PORT="${WEB_PORT:-80}"; API_PORT="${API_PORT:-1235}"
    AUTH_PORT="${AUTH_PORT:-1812}"; ACCT_PORT="${ACCT_PORT:-1813}"
    # carry the existing SERVER_DOMAIN forward so re-running Update never
    # silently drops HTTPS config that was set up after initial install
    SERVER_DOMAIN=$(docker inspect "$CONTAINER" --format \
        '{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null \
        | sed -n 's/^SERVER_DOMAIN=//p')

    warn "This rebuilds the image (re-downloads IBSng source) and recreates the container."
    warn "Your database (volume '$VOLUME') is kept."
    [ -n "$SERVER_DOMAIN" ] && info "Carrying forward SERVER_DOMAIN=${SERVER_DOMAIN} from the current container."
    local c
    read -rp "$(echo -e "${Y}Proceed? (y/n): ${N}")" c
    [ "$c" != "y" ] && { warn "Cancelled."; pause; return; }

    build_image || { pause; return; }
    mkdir -p "$WEBROOT_DIR"
    docker rm -f "$CONTAINER" >/dev/null
    docker run -d \
        --name "$CONTAINER" \
        --restart unless-stopped \
        -p "${WEB_PORT}:80/tcp" \
        -p 443:443/tcp \
        -p "${API_PORT}:1235/tcp" \
        -p "${AUTH_PORT}:1812/udp" \
        -p "${ACCT_PORT}:1813/udp" \
        -e SERVER_DOMAIN="${SERVER_DOMAIN}" \
        -v "${VOLUME}:${PG_MOUNT}" \
        -v "${WEBROOT_DIR}:/var/www/html" \
        -v "${LETSENCRYPT_DIR}:${LETSENCRYPT_DIR}:ro" \
        "$IMAGE_NAME"
    sleep 8
    container_running "$CONTAINER" && ok "Updated and running." || { err "Failed to start. Logs:"; docker logs "$CONTAINER" | tail -30; }
    pause
}

ibsng_delete() {
    if ! container_exists "$CONTAINER"; then
        warn "Nothing to delete."; pause; return
    fi
    local c
    read -rp "$(echo -e "${Y}Delete container? Data volume '$VOLUME' is kept. (y/n): ${N}")" c
    if [ "$c" = "y" ]; then
        docker rm -f "$CONTAINER" >/dev/null && ok "Container removed (volume kept)."
    else
        warn "Cancelled."
    fi
    pause
}

main_menu() {
    while true; do
        clear
        echo -e "${B}═══════════════════════════════════════════════${N}"
        echo -e "${B}  IBSng (built from source) — Docker Manager${N}"
        echo -e "${B}═══════════════════════════════════════════════${N}"
        echo ""
        if container_running "$CONTAINER"; then
            echo -e "  State: ${G}running${N}"
        elif container_exists "$CONTAINER"; then
            echo -e "  State: ${Y}stopped${N}"
        else
            echo -e "  State: ${R}not installed${N}"
        fi
        echo ""
        echo "  1) Install / Reinstall (build image + run)"
        echo "  2) Status"
        echo "  3) Live Log"
        echo "  4) Restart"
        echo "  5) Update (rebuild image, keep data)"
        echo "  6) Delete (keeps data volume)"
        echo "  7) Exit"
        echo ""
        read -rp "Select: " ch
        case "$ch" in
            1) ibsng_install ;;
            2) show_status ;;
            3) show_live_log ;;
            4) restart_container ;;
            5) ibsng_update ;;
            6) ibsng_delete ;;
            7) echo ""; ok "Bye."; exit 0 ;;
            *) warn "Invalid choice."; sleep 1 ;;
        esac
    done
}

require_root
if [ -t 1 ] && [ -e /dev/tty ]; then
    exec < /dev/tty
fi
main_menu
