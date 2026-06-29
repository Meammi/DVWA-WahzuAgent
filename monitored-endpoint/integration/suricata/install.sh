#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$(dirname "$SCRIPT_DIR")")"
TEMPLATE_PATH="$SCRIPT_DIR/suricata.yaml.template"
SURICATA_CONFIG_PATH="/etc/suricata/suricata.yaml"
SURICATA_LOG_DIR="/var/log/suricata"

if [[ $EUID -ne 0 ]]; then
    echo "[ERROR] Please run this script as root."
    exit 1
fi

if [[ -f "$ROOT_DIR/.env" ]]; then
    # shellcheck disable=SC1090
    source "$ROOT_DIR/.env"
fi

detect_ubuntu_version() {
    if [[ ! -r /etc/os-release ]]; then
        echo "[ERROR] Cannot detect Ubuntu version."
        exit 1
    fi

    # shellcheck disable=SC1091
    source /etc/os-release

    if [[ "${ID:-}" != "ubuntu" ]]; then
        echo "[ERROR] This installer supports Ubuntu only."
        exit 1
    fi

    UBUNTU_CODENAME="${VERSION_CODENAME:-}"
    UBUNTU_VERSION="${VERSION_ID:-}"

    if [[ -z "$UBUNTU_CODENAME" || -z "$UBUNTU_VERSION" ]]; then
        echo "[ERROR] Failed to read Ubuntu version details."
        exit 1
    fi
}

detect_interface() {
    local configured_interface="${SURICATA_INTERFACE:-${MONITOR_INTERFACE:-}}"

    if [[ -n "$configured_interface" ]]; then
        CAPTURE_INTERFACE="$configured_interface"
        return
    fi

    CAPTURE_INTERFACE="$(ip route show default 2>/dev/null | awk '/default/ {print $5; exit}')"

    if [[ -z "$CAPTURE_INTERFACE" ]]; then
        echo "[ERROR] Unable to detect a network interface."
        echo "[ERROR] Set SURICATA_INTERFACE or MONITOR_INTERFACE in monitored-endpoint/.env."
        exit 1
    fi
}

install_dependencies() {
    echo "[INFO] Installing dependencies..."
    apt update
    apt install -y software-properties-common curl gpg
}

install_suricata() {
    echo "[INFO] Installing Suricata for Ubuntu $UBUNTU_VERSION ($UBUNTU_CODENAME)..."

    if ! grep -Rqs "^deb .*oisf/suricata-stable" /etc/apt/sources.list /etc/apt/sources.list.d 2>/dev/null; then
        add-apt-repository -y ppa:oisf/suricata-stable
        apt update
    fi

    apt install -y suricata jq
}

configure_suricata() {
    echo "[INFO] Rendering Suricata configuration for interface $CAPTURE_INTERFACE..."

    if [[ ! -f "$TEMPLATE_PATH" ]]; then
        echo "[ERROR] Missing template: $TEMPLATE_PATH"
        exit 1
    fi

    sed "s/{{SURICATA_INTERFACE}}/$CAPTURE_INTERFACE/g" "$TEMPLATE_PATH" > "$SURICATA_CONFIG_PATH"
    mkdir -p "$SURICATA_LOG_DIR"
}

enable_service() {
    echo "[INFO] Enabling Suricata service..."
    systemctl enable suricata >/dev/null
    systemctl restart suricata
}

verify_installation() {
    local status_ok="false"
    local eve_ok="false"
    local attempts=10

    if systemctl is-active --quiet suricata; then
        status_ok="true"
    else
        echo "[ERROR] Suricata service failed to start."
        journalctl -u suricata -n 30 --no-pager || true
        exit 1
    fi

    if suricata -T -c "$SURICATA_CONFIG_PATH" -i "$CAPTURE_INTERFACE" >/tmp/suricata-verify.log 2>&1; then
        :
    else
        echo "[ERROR] Suricata configuration test failed."
        cat /tmp/suricata-verify.log
        exit 1
    fi

    if grep -q "eve-log:" "$SURICATA_CONFIG_PATH" && grep -q "enabled: yes" "$SURICATA_CONFIG_PATH"; then
        eve_ok="true"
    fi

    while (( attempts > 0 )); do
        if [[ -f "$SURICATA_LOG_DIR/eve.json" ]]; then
            break
        fi
        sleep 1
        ((attempts--))
    done

    if [[ ! -f "$SURICATA_LOG_DIR/eve.json" ]]; then
        echo "[ERROR] Suricata started but eve.json was not created."
        journalctl -u suricata -n 30 --no-pager || true
        exit 1
    fi

    echo
    [[ "$status_ok" == "true" ]] && echo "✓ Installed"
    [[ "$status_ok" == "true" ]] && echo "✓ Service running"
    [[ "$eve_ok" == "true" ]] && echo "✓ eve.json enabled"
    echo "✓ Ready for Wazuh"
}

detect_ubuntu_version
detect_interface
install_dependencies
install_suricata
configure_suricata
enable_service
verify_installation
