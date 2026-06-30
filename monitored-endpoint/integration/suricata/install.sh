#!/usr/bin/env bash

set -euo pipefail

SURICATA_CONFIG_PATH="/etc/suricata/suricata.yaml"
SURICATA_LOG_DIR="/var/log/suricata"
SURICATA_RULE_DIR="/var/lib/suricata/rules"
SURICATA_EVE_PATH="$SURICATA_LOG_DIR/eve.json"
OSSEC_CONFIG_PATH="/var/ossec/etc/ossec.conf"
TEMPLATE_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/suricata.yaml.template"
RULES_URL="https://rules.emergingthreats.net/open/suricata-6.0.8/emerging.rules.tar.gz"

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
}

install_rules() {
    echo "[INFO] Installing Emerging Threats rules..."
    mkdir -p "$SURICATA_RULE_DIR"
    local rules_archive="/tmp/emerging.rules.tar.gz"
    local extract_dir="/tmp/emerging-rules.$$"

    rm -rf "$extract_dir"
    mkdir -p "$extract_dir"
    curl -fsSL "$RULES_URL" -o "$rules_archive"
    tar -xzf "$rules_archive" -C "$extract_dir"
    find "$SURICATA_RULE_DIR" -maxdepth 1 -type f -name '*.rules' -delete
    cp "$extract_dir"/rules/*.rules "$SURICATA_RULE_DIR"/
    chmod 0644 "$SURICATA_RULE_DIR"/*.rules
    rm -rf "$extract_dir" "$rules_archive"
}

configure_suricata() {
    echo "[INFO] Configuring Suricata..."

    if [[ ! -f "$TEMPLATE_PATH" ]]; then
        echo "[ERROR] Missing template: $TEMPLATE_PATH"
        exit 1
    fi

    mkdir -p "$SURICATA_LOG_DIR"
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
