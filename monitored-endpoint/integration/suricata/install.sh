#!/usr/bin/env bash

set -euo pipefail

SURICATA_CONFIG_PATH="/etc/suricata/suricata.yaml"
SURICATA_LOG_DIR="/var/log/suricata"
SURICATA_RULE_DIR="/var/lib/suricata/rules"
SURICATA_EVE_PATH="$SURICATA_LOG_DIR/eve.json"
OSSEC_CONFIG_PATH="/var/ossec/etc/ossec.conf"
TEMPLATE_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/suricata.yaml.template"

if [[ $EUID -ne 0 ]]; then
    echo "[ERROR] Please run this script as root."
    exit 1
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
}

detect_interface() {
    if [[ -n "${SURICATA_INTERFACE:-}" ]]; then
        CAPTURE_INTERFACE="$SURICATA_INTERFACE"
    elif [[ -n "${MONITOR_INTERFACE:-}" ]]; then
        CAPTURE_INTERFACE="$MONITOR_INTERFACE"
    else
        CAPTURE_INTERFACE="$(ip route show default 2>/dev/null | awk '/default/ {print $5; exit}')"
    fi

    if [[ -z "${CAPTURE_INTERFACE:-}" ]]; then
        echo "[ERROR] Unable to detect a capture interface."
        echo "[ERROR] Export SURICATA_INTERFACE or MONITOR_INTERFACE and rerun."
        exit 1
    fi
}

detect_home_net() {
    if [[ -n "${SURICATA_HOME_NET:-}" ]]; then
        HOME_NET_VALUE="$SURICATA_HOME_NET"
        return
    fi

    HOME_NET_VALUE="$(ip -o -4 addr show dev "$CAPTURE_INTERFACE" | awk '{print $4; exit}')"

    if [[ -z "$HOME_NET_VALUE" ]]; then
        echo "[ERROR] Unable to detect an IPv4 address for interface $CAPTURE_INTERFACE."
        echo "[ERROR] Export SURICATA_HOME_NET and rerun."
        exit 1
    fi
}

install_suricata() {
    echo "[INFO] Installing Suricata..."
    apt-get update
    apt-get install -y software-properties-common curl

    if ! grep -Rqs "ppa.launchpadcontent.net/oisf/suricata-stable" /etc/apt/sources.list /etc/apt/sources.list.d 2>/dev/null; then
        add-apt-repository -y ppa:oisf/suricata-stable
    fi

    apt-get update
    apt-get install -y suricata

    if ! command -v suricata-update >/dev/null 2>&1; then
        apt-get install -y suricata-update
    fi
}

install_rules() {
    echo "[INFO] Installing Emerging Threats rules..."
    suricata-update
}

configure_suricata() {
    echo "[INFO] Configuring Suricata..."

    mkdir -p "$SURICATA_LOG_DIR"

    if [[ -f "$SURICATA_CONFIG_PATH" ]]; then
        cp "$SURICATA_CONFIG_PATH" "${SURICATA_CONFIG_PATH}.bak"
        sed -i \
            -e "0,/HOME_NET:.*/s|HOME_NET:.*|HOME_NET: \"$HOME_NET_VALUE\"|" \
            -e "0,/interface:.*/s|interface:.*|interface: $CAPTURE_INTERFACE|" \
            "$SURICATA_CONFIG_PATH"
        return
    fi

    if [[ ! -f "$TEMPLATE_PATH" ]]; then
        echo "[ERROR] Missing template: $TEMPLATE_PATH"
        exit 1
    fi

    sed \
        -e "s|__HOME_NET__|$HOME_NET_VALUE|g" \
        -e "s|__CAPTURE_INTERFACE__|$CAPTURE_INTERFACE|g" \
        "$TEMPLATE_PATH" >"$SURICATA_CONFIG_PATH"
}

configure_wazuh_agent() {
    local marker='<!-- WAZUH_SURICATA_INTEGRATION -->'

    if [[ ! -f "$OSSEC_CONFIG_PATH" ]]; then
        echo "[WARN] Wazuh agent configuration not found. Skipping Wazuh log integration."
        return
    fi

    if ! grep -Fq "$marker" "$OSSEC_CONFIG_PATH"; then
        sed -i '/<\/ossec_config>/i\
  <!-- WAZUH_SURICATA_INTEGRATION -->\
  <localfile>\
    <log_format>json</log_format>\
    <location>/var/log/suricata/eve.json</location>\
  </localfile>' "$OSSEC_CONFIG_PATH"
    fi

    if systemctl list-unit-files | grep -q '^wazuh-agent\.service'; then
        systemctl restart wazuh-agent
    fi
}

verify_installation() {
    local verify_log="/tmp/suricata-verify.log"

    if ! suricata -T -c "$SURICATA_CONFIG_PATH" -i "$CAPTURE_INTERFACE" >"$verify_log" 2>&1; then
        echo "[ERROR] Suricata configuration test failed."
        cat "$verify_log"
        exit 1
    fi

    systemctl enable suricata >/dev/null
    systemctl restart suricata
    sleep 2

    if ! systemctl is-active --quiet suricata; then
        echo "[ERROR] Suricata service failed to start."
        journalctl -u suricata -n 30 --no-pager || true
        exit 1
    fi

    if [[ ! -f "$SURICATA_EVE_PATH" ]]; then
        echo "[ERROR] Missing $SURICATA_EVE_PATH after start."
        exit 1
    fi

    echo "[INFO] Suricata is running and writing $SURICATA_EVE_PATH."
}

detect_platform
detect_interface
detect_home_net
install_suricata
install_rules
configure_suricata
configure_wazuh_agent
verify_installation
