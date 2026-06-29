#!/usr/bin/env bash

set -euo pipefail

if [[ $EUID -ne 0 ]]; then
    echo "[ERROR] Please run this script as root."
    exit 1
fi

echo "[INFO] Stopping Suricata..."
systemctl stop suricata 2>/dev/null || true
systemctl disable suricata 2>/dev/null || true

if [[ -f /var/ossec/etc/ossec.conf ]]; then
    sed -i '/<!-- WAZUH_SURICATA_INTEGRATION -->/,/<\/localfile>/d' /var/ossec/etc/ossec.conf
    if systemctl list-unit-files | grep -q '^wazuh-agent\.service'; then
        systemctl restart wazuh-agent || true
    fi
fi

echo "[INFO] Removing Suricata packages..."
apt purge -y suricata jq || true
apt autoremove -y

echo "[INFO] Removing Suricata repository..."
add-apt-repository --remove -y ppa:oisf/suricata-stable 2>/dev/null || true
rm -f /etc/apt/sources.list.d/oisf-ubuntu-suricata-stable-*.list
rm -f /etc/apt/sources.list.d/oisf-ubuntu-suricata-stable-*.sources
apt update

read -rp "Remove Suricata configuration and logs under /etc/suricata and /var/log/suricata? [y/N]: " answer

if [[ "$answer" =~ ^[Yy]$ ]]; then
    rm -rf /etc/suricata /var/log/suricata
    echo "[INFO] Removed Suricata configuration and logs."
fi

echo
echo "Uninstall completed."
