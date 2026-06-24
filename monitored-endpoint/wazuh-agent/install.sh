#!/usr/bin/env bash

set -euo pipefail

# Resolve project paths
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"

# Ensure the script is run as root
if [[ $EUID -ne 0 ]]; then
    echo "[ERROR] Please run this script as root."
    exit 1
fi

# Load configuration
if [[ ! -f "$ROOT_DIR/.env" ]]; then
    echo "[ERROR] .env not found."
    exit 1
fi

source "$ROOT_DIR/.env"

# Validate required variables
: "${MANAGER_IP:?MANAGER_IP is not set}"
: "${WAZUH_VERSION:?WAZUH_VERSION is not set}"

echo "[INFO] Installing dependencies..."
apt update
apt install -y curl gnupg apt-transport-https

echo "[INFO] Adding Wazuh repository..."
curl -s https://packages.wazuh.com/key/GPG-KEY-WAZUH \
    | gpg --dearmor \
    -o /usr/share/keyrings/wazuh.gpg

echo "deb [signed-by=/usr/share/keyrings/wazuh.gpg] https://packages.wazuh.com/4.x/apt stable main" \
    > /etc/apt/sources.list.d/wazuh.list

apt update

echo "[INFO] Installing Wazuh Agent ${WAZUH_VERSION}..."
WAZUH_MANAGER="$MANAGER_IP" \
apt install -y wazuh-agent="${WAZUH_VERSION}"-1

echo "[INFO] Installing configuration..."
cp "$SCRIPT_DIR/ossec.conf.template" /var/ossec/etc/ossec.conf

echo "[INFO] Starting Wazuh Agent..."
systemctl enable wazuh-agent
systemctl restart wazuh-agent

echo ""
echo "Installation completed!"
echo "Next step:"
echo "sudo ./register-agent.sh"

