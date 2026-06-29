#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$(dirname "$SCRIPT_DIR")")"
TEMPLATE_PATH="$SCRIPT_DIR/zeek.yaml.template"
ZEEK_PREFIX="/opt/zeek"
ZEEK_NODE_CONFIG="$ZEEK_PREFIX/etc/node.cfg"
ZEEK_LOCAL_CONFIG="$ZEEK_PREFIX/share/zeek/site/local.zeek"
ZEEK_WAZUH_POLICY="$ZEEK_PREFIX/share/zeek/site/wazuh-json-logs.zeek"
ZEEK_LOG_DIR="$ZEEK_PREFIX/logs/current"
ZEEK_SERVICE_PATH="/etc/systemd/system/zeek.service"

if [[ $EUID -ne 0 ]]; then
    echo "[ERROR] Please run this script as root."
    exit 1
fi

if [[ -f "$ROOT_DIR/.env" ]]; then
    # shellcheck disable=SC1090
    source "$ROOT_DIR/.env"
fi

detect_platform() {
    if [[ ! -r /etc/os-release ]]; then
        echo "[ERROR] Cannot detect operating system."
        exit 1
    fi

    # shellcheck disable=SC1091
    source /etc/os-release

    if [[ "${ID:-}" != "ubuntu" ]]; then
        echo "[ERROR] This installer supports Ubuntu only."
        exit 1
    fi

    UBUNTU_VERSION="${VERSION_ID:-}"
    OBS_VERSION="xUbuntu_${UBUNTU_VERSION//./}"
}

detect_interface() {
    local configured_interface="${ZEEK_INTERFACE:-${MONITOR_INTERFACE:-}}"

    if [[ -n "$configured_interface" ]]; then
        CAPTURE_INTERFACE="$configured_interface"
        return
    fi

    CAPTURE_INTERFACE="$(ip route show default 2>/dev/null | awk '/default/ {print $5; exit}')"

    if [[ -z "$CAPTURE_INTERFACE" ]]; then
        echo "[ERROR] Unable to detect a network interface."
        echo "[ERROR] Set ZEEK_INTERFACE or MONITOR_INTERFACE in monitored-endpoint/.env."
        exit 1
    fi
}

install_dependencies() {
    echo "[INFO] Installing dependencies..."
    apt update
    apt install -y curl gpg lsb-release apt-transport-https dnsutils
}

install_zeek() {
    local repo_url="https://download.opensuse.org/repositories/security:/zeek/${OBS_VERSION}/"
    local repo_file="/etc/apt/sources.list.d/security:zeek.list"
    local keyring="/usr/share/keyrings/security_zeek.gpg"

    echo "[INFO] Installing Zeek from ${repo_url}..."

    curl -fsSL "${repo_url}Release.key" | gpg --dearmor --yes -o "$keyring"

    cat >"$repo_file" <<EOF
deb [signed-by=$keyring] $repo_url /
EOF

    apt update
    apt install -y zeek jq
}

configure_zeek() {
    echo "[INFO] Configuring Zeek on interface $CAPTURE_INTERFACE..."

    if [[ ! -d "$ZEEK_PREFIX" ]]; then
        echo "[ERROR] Zeek was not installed under $ZEEK_PREFIX."
        exit 1
    fi

    cat >"$ZEEK_NODE_CONFIG" <<EOF
[zeek]
type=standalone
host=localhost
interface=$CAPTURE_INTERFACE
EOF

    if [[ ! -f "$TEMPLATE_PATH" ]]; then
        echo "[ERROR] Missing template: $TEMPLATE_PATH"
        exit 1
    fi

    cp "$TEMPLATE_PATH" "$ZEEK_WAZUH_POLICY"

    if ! grep -Fqx "@load ./wazuh-json-logs.zeek" "$ZEEK_LOCAL_CONFIG"; then
        printf '\n@load ./wazuh-json-logs.zeek\n' >> "$ZEEK_LOCAL_CONFIG"
    fi
}

install_service() {
    echo "[INFO] Installing Zeek systemd unit..."

    cat >"$ZEEK_SERVICE_PATH" <<'EOF'
[Unit]
Description=Zeek Network Security Monitor
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/opt/zeek/bin/zeekctl deploy
ExecStop=/opt/zeek/bin/zeekctl stop
ExecReload=/opt/zeek/bin/zeekctl deploy

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable zeek >/dev/null
    systemctl restart zeek
}

verify_logs() {
    local required_logs=("conn.log" "dns.log" "http.log" "ssl.log")
    local attempts

    if ! systemctl is-active --quiet zeek; then
        echo "[ERROR] Zeek service failed to start."
        journalctl -u zeek -n 30 --no-pager || true
        exit 1
    fi

    "$ZEEK_PREFIX/bin/zeekctl" check >/tmp/zeek-check.log 2>&1 || {
        echo "[ERROR] Zeek configuration check failed."
        cat /tmp/zeek-check.log
        exit 1
    }

    dig +short example.com >/dev/null 2>&1 || true
    curl -fsSI http://example.com >/dev/null 2>&1 || true
    curl -fsSI https://example.com >/dev/null 2>&1 || true

    for log_name in "${required_logs[@]}"; do
        attempts=20
        while (( attempts > 0 )); do
            if [[ -f "$ZEEK_LOG_DIR/$log_name" ]]; then
                break
            fi
            sleep 1
            ((attempts--))
        done

        if [[ ! -f "$ZEEK_LOG_DIR/$log_name" ]]; then
            echo "[ERROR] Expected Zeek log was not created: $ZEEK_LOG_DIR/$log_name"
            ls -la "$ZEEK_LOG_DIR" 2>/dev/null || true
            exit 1
        fi

        echo "✓ $log_name"
    done
}

detect_platform
detect_interface
install_dependencies
install_zeek
configure_zeek
install_service
verify_logs
