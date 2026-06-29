#!/usr/bin/env bash

set -euo pipefail

if [[ $EUID -ne 0 ]]; then
    echo "[ERROR] Please run this script as root."
    exit 1
fi

echo "[INFO] Stopping Zeek..."
systemctl stop zeek 2>/dev/null || true
systemctl disable zeek 2>/dev/null || true
rm -f /etc/systemd/system/zeek.service
systemctl daemon-reload

echo "[INFO] Removing Zeek packages..."
apt purge -y zeek jq || true
apt autoremove -y

echo "[INFO] Removing Zeek repository..."
rm -f /etc/apt/sources.list.d/security:zeek.list
rm -f /usr/share/keyrings/security_zeek.gpg
apt update

read -rp "Remove Zeek data under /opt/zeek? [y/N]: " answer

if [[ "$answer" =~ ^[Yy]$ ]]; then
    rm -rf /opt/zeek
    echo "[INFO] Removed /opt/zeek"
fi

echo
echo "Uninstall completed."
