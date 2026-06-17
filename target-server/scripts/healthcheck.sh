#!/bin/bash
set -u

SCRIPT_DIR=$(dirname "$(readlink -f "$0")")
DEFAULT_CONFIG_FILE="${SCRIPT_DIR}/../config/tunnel.conf"
INSTALLED_CONFIG_FILE="/opt/reverse-tunnel/config/tunnel.conf"
CONFIG_FILE="${1:-}"

if [ -z "$CONFIG_FILE" ]; then
    if [ -f "$INSTALLED_CONFIG_FILE" ]; then
        CONFIG_FILE="$INSTALLED_CONFIG_FILE"
    else
        CONFIG_FILE="$DEFAULT_CONFIG_FILE"
    fi
fi

FAILURES=0
WARNINGS=0

ok() {
    echo "[OK] $*"
}

warn() {
    WARNINGS=$((WARNINGS + 1))
    echo "[WARN] $*"
}

fail() {
    FAILURES=$((FAILURES + 1))
    echo "[FAIL] $*"
}

tcp_check() {
    local host="$1"
    local port="$2"
    timeout 2 bash -c "</dev/tcp/${host}/${port}" >/dev/null 2>&1
}

remote_port_listening() {
    local port="$1"
    ssh -o BatchMode=yes -o ConnectTimeout=5 "$MIDDLE_SERVER_HOST_ALIAS" \
        "ss -tln | awk '{print \$4}' | grep -Eq ':${port}$'" >/dev/null 2>&1
}

parse_tunnel() {
    local tunnel="$1"
    IFS=: read -r REMOTE_PORT TARGET_HOST TARGET_PORT <<EOF
$tunnel
EOF
}

echo "=== reverse-tunnel healthcheck ==="

if [ ! -f "$CONFIG_FILE" ]; then
    fail "Config file not found: $CONFIG_FILE"
    echo "Summary: ${FAILURES} failure(s), ${WARNINGS} warning(s)"
    exit 1
fi

# shellcheck source=/dev/null
source "$CONFIG_FILE"
MIDDLE_SERVER_TUNNEL_USER="${MIDDLE_SERVER_TUNNEL_USER:-tunnel}"

if [ -z "${MIDDLE_SERVER_HOST_ALIAS:-}" ] || [ -z "${TUNNELS:-}" ]; then
    fail "Config must define MIDDLE_SERVER_HOST_ALIAS and TUNNELS"
    echo "Summary: ${FAILURES} failure(s), ${WARNINGS} warning(s)"
    exit 1
fi

ok "Using config: $CONFIG_FILE"

if systemctl list-unit-files reverse-tunnel.service >/dev/null 2>&1; then
    if systemctl is-active --quiet reverse-tunnel.service; then
        ok "reverse-tunnel.service is active"
    else
        fail "reverse-tunnel.service is not active"
    fi
else
    warn "reverse-tunnel.service is not installed"
fi

if pgrep -f "autossh .*${MIDDLE_SERVER_TUNNEL_USER}@${MIDDLE_SERVER_HOST_ALIAS}" >/dev/null; then
    ok "autossh process is running"
else
    fail "autossh process for ${MIDDLE_SERVER_TUNNEL_USER}@${MIDDLE_SERVER_HOST_ALIAS} is not running"
fi

if ssh -o BatchMode=yes -o ConnectTimeout=5 "$MIDDLE_SERVER_HOST_ALIAS" true >/dev/null 2>&1; then
    ok "Can SSH to middle alias: $MIDDLE_SERVER_HOST_ALIAS"
else
    fail "Cannot SSH to middle alias: $MIDDLE_SERVER_HOST_ALIAS"
fi

for tunnel in $TUNNELS; do
    REMOTE_PORT=""
    TARGET_HOST=""
    TARGET_PORT=""
    parse_tunnel "$tunnel"

    if [ -z "$REMOTE_PORT" ] || [ -z "$TARGET_HOST" ] || [ -z "$TARGET_PORT" ]; then
        fail "Invalid tunnel entry: $tunnel"
        continue
    fi

    if remote_port_listening "$REMOTE_PORT"; then
        ok "Middle Server is listening on remote port $REMOTE_PORT"
    else
        fail "Middle Server is not listening on remote port $REMOTE_PORT"
    fi

    if tcp_check "$TARGET_HOST" "$TARGET_PORT"; then
        ok "Local backend ${TARGET_HOST}:${TARGET_PORT} is reachable"
    else
        warn "Local backend ${TARGET_HOST}:${TARGET_PORT} is not reachable"
    fi
done

echo "Summary: ${FAILURES} failure(s), ${WARNINGS} warning(s)"

if [ "$FAILURES" -gt 0 ]; then
    exit 1
fi

exit 0
