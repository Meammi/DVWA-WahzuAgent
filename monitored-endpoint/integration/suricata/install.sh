#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(dirname "$(dirname "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)")")"
SURICATA_CONFIG_PATH="/etc/suricata/suricata.yaml"
SURICATA_DEFAULTS_PATH="/etc/default/suricata"
SURICATA_LOG_DIR="/var/log/suricata"
SURICATA_RULE_DIR="/etc/suricata/rules"
SURICATA_EVE_PATH="$SURICATA_LOG_DIR/eve.json"
OSSEC_CONFIG_PATH="/var/ossec/etc/ossec.conf"
SURICATA_EXAMPLE_CANDIDATES=(
    "/usr/share/doc/suricata/examples/suricata.yaml"
    "/usr/share/doc/suricata/examples/suricata.yaml.gz"
    "/usr/share/doc/suricata/suricata.yaml"
    "/usr/share/doc/suricata/suricata.yaml.gz"
)

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

require_file() {
    local file_path="$1"
    if [[ ! -f "$file_path" ]]; then
        echo "[ERROR] Required file not found: $file_path"
        exit 1
    fi
}

detect_ubuntu_version() {
    require_file /etc/os-release
    # shellcheck disable=SC1091
    source /etc/os-release

    if [[ "${ID:-}" != "ubuntu" ]]; then
        echo "[ERROR] This installer supports Ubuntu only."
        exit 1
    fi
}

detect_interface() {
    local configured_interface="${SURICATA_INTERFACE:-${MONITOR_INTERFACE:-}}"

    if [[ -n "$configured_interface" ]]; then
        CAPTURE_INTERFACE="$configured_interface"
    else
        CAPTURE_INTERFACE="$(ip route show default 2>/dev/null | awk '/default/ {print $5; exit}')"
    fi

    if [[ -z "${CAPTURE_INTERFACE:-}" ]]; then
        echo "[ERROR] Unable to detect a capture interface."
        echo "[ERROR] Set SURICATA_INTERFACE or MONITOR_INTERFACE in monitored-endpoint/.env."
        exit 1
    fi
}

detect_home_net() {
    local configured_home_net="${SURICATA_HOME_NET:-}"

    if [[ -n "$configured_home_net" ]]; then
        HOME_NET_VALUE="$configured_home_net"
        return
    fi

    HOME_NET_VALUE="$(ip -o -4 addr show dev "$CAPTURE_INTERFACE" | awk '{print $4; exit}')"

    if [[ -z "$HOME_NET_VALUE" ]]; then
        echo "[ERROR] Unable to detect an IPv4 address for interface $CAPTURE_INTERFACE."
        echo "[ERROR] Set SURICATA_HOME_NET in monitored-endpoint/.env."
        exit 1
    fi
}

install_dependencies() {
    echo "[INFO] Installing dependencies..."
    apt-get update
    apt-get install -y software-properties-common curl gpg
}

install_suricata() {
    echo "[INFO] Installing Suricata..."

    if ! grep -Rqs "ppa.launchpadcontent.net/oisf/suricata-stable" /etc/apt/sources.list /etc/apt/sources.list.d 2>/dev/null; then
        add-apt-repository -y ppa:oisf/suricata-stable
    fi

    apt-get update
    apt-get install -y suricata
}

reset_suricata_config() {
    local candidate

    echo "[INFO] Resetting Suricata config to a package baseline..."
    mkdir -p "$(dirname "$SURICATA_CONFIG_PATH")"

    for candidate in "${SURICATA_EXAMPLE_CANDIDATES[@]}"; do
        if [[ -f "$candidate" ]]; then
            cp "$SURICATA_CONFIG_PATH" "${SURICATA_CONFIG_PATH}.pre-wazuh.bak" 2>/dev/null || true
            if [[ "$candidate" == *.gz ]]; then
                gzip -dc "$candidate" > "$SURICATA_CONFIG_PATH"
            else
                cp "$candidate" "$SURICATA_CONFIG_PATH"
            fi
            return
        fi
    done

    echo "[ERROR] Could not find a packaged Suricata example config."
    exit 1
}

install_rules() {
    echo "[INFO] Installing Emerging Threats rules..."
    mkdir -p "$SURICATA_RULE_DIR"

    if command -v suricata-update >/dev/null 2>&1; then
        suricata-update
        return
    fi

    local rules_url="https://rules.emergingthreats.net/open/suricata-6.0.8/emerging.rules.tar.gz"
    local rules_archive="/tmp/emerging.rules.tar.gz"
    local extract_dir="/tmp/emerging-rules.$$"

    rm -rf "$extract_dir"
    mkdir -p "$extract_dir"
    curl -fsSL "$rules_url" -o "$rules_archive"
    tar -xzf "$rules_archive" -C "$extract_dir"
    find "$SURICATA_RULE_DIR" -maxdepth 1 -type f -name '*.rules' -delete
    cp "$extract_dir"/rules/*.rules "$SURICATA_RULE_DIR"/
    chmod 0644 "$SURICATA_RULE_DIR"/*.rules
    rm -rf "$extract_dir" "$rules_archive"
}

configure_suricata() {
    echo "[INFO] Configuring Suricata..."

    reset_suricata_config
    require_file "$SURICATA_CONFIG_PATH"

    sed -i -E 's|^(\s*HOME_NET:\s*).*$|\1"'"$HOME_NET_VALUE"'"|' "$SURICATA_CONFIG_PATH"
    sed -i -E 's|^(\s*EXTERNAL_NET:\s*).*$|\1"any"|' "$SURICATA_CONFIG_PATH"
    sed -i -E 's|^(\s*default-rule-path:\s*).*$|\1/etc/suricata/rules|' "$SURICATA_CONFIG_PATH"

    if ! grep -Eq '^\s*-\s*"\*\.rules"\s*$' "$SURICATA_CONFIG_PATH"; then
        sed -i '/^rule-files:/a\  - "*.rules"' "$SURICATA_CONFIG_PATH"
    fi

    perl -0pi -e 's/stats:\n(\s*)enabled:\s*no/stats:\n${1}enabled: yes/m' "$SURICATA_CONFIG_PATH"

    if grep -q '^af-packet:' "$SURICATA_CONFIG_PATH"; then
        perl -0pi -e 's/af-packet:\n(\s*)-\s*interface:\s*[^\n]+/af-packet:\n${1}- interface: '"$CAPTURE_INTERFACE"'/m' "$SURICATA_CONFIG_PATH"
    else
        cat >>"$SURICATA_CONFIG_PATH" <<EOF

af-packet:
  - interface: $CAPTURE_INTERFACE
EOF
    fi

    if [[ -f "$SURICATA_DEFAULTS_PATH" ]]; then
        if grep -q '^IFACE=' "$SURICATA_DEFAULTS_PATH"; then
            sed -i -E 's|^IFACE=.*$|IFACE="'"$CAPTURE_INTERFACE"'"|' "$SURICATA_DEFAULTS_PATH"
        else
            printf 'IFACE="%s"\n' "$CAPTURE_INTERFACE" >> "$SURICATA_DEFAULTS_PATH"
        fi

        if grep -q '^LISTENMODE=' "$SURICATA_DEFAULTS_PATH"; then
            sed -i -E 's|^LISTENMODE=.*$|LISTENMODE=af-packet|' "$SURICATA_DEFAULTS_PATH"
        else
            echo 'LISTENMODE=af-packet' >> "$SURICATA_DEFAULTS_PATH"
        fi
    fi

    mkdir -p "$SURICATA_LOG_DIR"
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

enable_service() {
    echo "[INFO] Enabling Suricata service..."
    systemctl enable suricata >/dev/null
    systemctl restart suricata
}

verify_installation() {
    local attempts=15

    if ! suricata -T -c "$SURICATA_CONFIG_PATH" -i "$CAPTURE_INTERFACE" >/tmp/suricata-verify.log 2>&1; then
        echo "[ERROR] Suricata configuration test failed."
        cat /tmp/suricata-verify.log
        exit 1
    fi

    if ! systemctl is-active --quiet suricata; then
        echo "[ERROR] Suricata service failed to start."
        journalctl -u suricata -n 30 --no-pager || true
        exit 1
    fi

    while (( attempts > 0 )); do
        if [[ -f "$SURICATA_EVE_PATH" ]]; then
            break
        fi
        sleep 1
        ((attempts--))
    done

    if [[ ! -f "$SURICATA_EVE_PATH" ]]; then
        echo "[ERROR] Suricata started, but $SURICATA_EVE_PATH was not created."
        journalctl -u suricata -n 30 --no-pager || true
        exit 1
    fi

    echo
    print_check "Installed"
    print_check "Service running"
    print_check "eve.json enabled"
    print_check "Ready for Wazuh"
}

detect_ubuntu_version
detect_interface
detect_home_net
install_dependencies
install_suricata
configure_suricata
install_rules
configure_wazuh_agent
enable_service
verify_installation
