#!/usr/bin/env bash

set -euo pipefail

# Ensure the script is run as root
if [[ $EUID -ne 0 ]]; then
    echo "[ERROR] Please run this script as root."
    exit 1
fi

echo "[INFO] Stopping Wazuh Agent..."
systemctl stop wazuh-agent 2>/dev/null || true
systemctl disable wazuh-agent 2>/dev/null || true

echo "[INFO] Removing Wazuh Agent..."
apt purge -y wazuh-agent

echo "[INFO] Removing unused packages..."
apt autoremove -y

echo "[INFO] Removing Wazuh repository..."
rm -f /etc/apt/sources.list.d/wazuh.list
rm -f /usr/share/keyrings/wazuh.gpg

apt update

read -rp "Remove /var/ossec (agent configuration and logs)? [y/N]: " answer

if [[ "$answer" =~ ^[Yy]$ ]]; then
    rm -rf /var/ossec
    echo "[INFO] Removed /var/ossec"
fi

echo
echo "Uninstall completed."