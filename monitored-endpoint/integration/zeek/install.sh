#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$(dirname "$SCRIPT_DIR")")"
TEMPLATE_PATH="$SCRIPT_DIR/zeek.yaml.template"
ZEEK_PREFIX="/opt/zeek"
ZEEK_NODE_CONFIG="$ZEEK_PREFIX/etc/node.cfg"
ZEEK_NETWORKS_CONFIG="$ZEEK_PREFIX/etc/networks.cfg"
ZEEK_LOCAL_CONFIG="$ZEEK_PREFIX/share/zeek/site/local.zeek"
ZEEK_LOG_DIR="$ZEEK_PREFIX/logs/current"
ZEEK_SERVICE_PATH="/etc/systemd/system/zeek.service"
ZEEK_REPO_FILE="/etc/apt/sources.list.d/security:zeek.list"
ZEEK_KEYRING="/etc/apt/trusted.gpg.d/security_zeek.gpg"
OSSEC_CONFIG_PATH="/var/ossec/etc/ossec.conf"

if [[ $EUID -ne 0 ]]; then
    echo "[ERROR] Please run this script as root."
    exit 1
fi

if [[ -f "$ROOT_DIR/.env" ]]; then
    # shellcheck disable=SC1090
    source "$ROOT_DIR/.env"
fi

print_check() {
    printf '\342\234\223 %s\n' "$1"
}

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
    OBS_VERSION="xUbuntu_${UBUNTU_VERSION}"
}

detect_interface() {
    local configured_interface="${ZEEK_INTERFACE:-${MONITOR_INTERFACE:-}}"

    if [[ -n "$configured_interface" ]]; then
        CAPTURE_INTERFACE="$configured_interface"
    else
        CAPTURE_INTERFACE="$(ip route show default 2>/dev/null | awk '/default/ {print $5; exit}')"
    fi

    if [[ -z "${CAPTURE_INTERFACE:-}" ]]; then
        echo "[ERROR] Unable to detect a capture interface."
        echo "[ERROR] Set ZEEK_INTERFACE or MONITOR_INTERFACE in monitored-endpoint/.env."
        exit 1
    fi
}

detect_network_subnet() {
    local configured_subnet="${ZEEK_NETWORK_SUBNET:-}"

    if [[ -n "$configured_subnet" ]]; then
        NETWORK_SUBNET="$configured_subnet"
        return
    fi

    NETWORK_SUBNET="$(ip -o -4 addr show dev "$CAPTURE_INTERFACE" | awk '{print $4; exit}')"

    if [[ -z "$NETWORK_SUBNET" ]]; then
        echo "[ERROR] Unable to detect a subnet for interface $CAPTURE_INTERFACE."
        echo "[ERROR] Set ZEEK_NETWORK_SUBNET in monitored-endpoint/.env."
        exit 1
    fi
}

install_dependencies() {
    echo "[INFO] Installing dependencies..."
    apt-get update
    apt-get install -y curl gpg apt-transport-https dnsutils
}

install_zeek() {
    local repo_url="http://download.opensuse.org/repositories/security:/zeek/${OBS_VERSION}/"

    echo "[INFO] Installing Zeek from ${repo_url}..."

    echo "deb ${repo_url} /" > "$ZEEK_REPO_FILE"
    curl -fsSL "${repo_url}Release.key" | gpg --dearmor --yes > "$ZEEK_KEYRING"

    apt-get update
    apt-get install -y zeek
}

configure_zeek() {
    echo "[INFO] Configuring Zeek on interface $CAPTURE_INTERFACE..."

    if [[ ! -d "$ZEEK_PREFIX" ]]; then
        echo "[ERROR] Zeek was not installed under $ZEEK_PREFIX."
        exit 1
    fi

    if [[ ! -f "$ZEEK_LOCAL_CONFIG" ]]; then
        echo "[ERROR] Missing Zeek local config: $ZEEK_LOCAL_CONFIG"
        exit 1
    fi

    cat >"$ZEEK_NODE_CONFIG" <<EOF
[zeek]
type=standalone
host=localhost
interface=$CAPTURE_INTERFACE
EOF

    if [[ ! -f "$ZEEK_NETWORKS_CONFIG" ]]; then
        echo "[ERROR] Missing Zeek networks config: $ZEEK_NETWORKS_CONFIG"
        exit 1
    fi

    if ! grep -Fqx "$NETWORK_SUBNET" "$ZEEK_NETWORKS_CONFIG"; then
        printf '%s\n' "$NETWORK_SUBNET" >> "$ZEEK_NETWORKS_CONFIG"
    fi

    if [[ ! -f "$TEMPLATE_PATH" ]]; then
        echo "[ERROR] Missing template: $TEMPLATE_PATH"
        exit 1
    fi

    if ! grep -Fqx "@load policy/tuning/json-logs.zeek" "$ZEEK_LOCAL_CONFIG"; then
        cat "$TEMPLATE_PATH" >> "$ZEEK_LOCAL_CONFIG"
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
}

configure_wazuh_agent() {
    local marker='<!-- WAZUH_ZEEK_INTEGRATION -->'

    if [[ ! -f "$OSSEC_CONFIG_PATH" ]]; then
        echo "[WARN] Wazuh agent configuration not found. Skipping Wazuh log integration."
        return
    fi

    if ! grep -Fq "$marker" "$OSSEC_CONFIG_PATH"; then
        sed -i '/<\/ossec_config>/i\
  <!-- WAZUH_ZEEK_INTEGRATION -->\
  <localfile>\
    <log_format>json</log_format>\
    <location>/opt/zeek/logs/current/*.log</location>\
  </localfile>' "$OSSEC_CONFIG_PATH"
    fi

    if systemctl list-unit-files | grep -q '^wazuh-agent\.service'; then
        systemctl restart wazuh-agent
    fi
}

start_zeek() {
    echo "[INFO] Starting Zeek..."

    "$ZEEK_PREFIX/bin/zeekctl" check >/tmp/zeek-check.log 2>&1 || {
        echo "[ERROR] Zeek configuration check failed."
        cat /tmp/zeek-check.log
        exit 1
    }

    "$ZEEK_PREFIX/bin/zeekctl" deploy >/tmp/zeek-deploy.log 2>&1 || {
        echo "[ERROR] Zeek deployment failed."
        cat /tmp/zeek-deploy.log
        exit 1
    }

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

        print_check "$log_name"
    done
}

detect_platform
detect_interface
detect_network_subnet
install_dependencies
install_zeek
configure_zeek
install_service
configure_wazuh_agent
start_zeek
verify_logs
