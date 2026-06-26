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
: "${WAZUH_MANAGER_ADDRESS:?WAZUH_MANAGER_ADDRESS is not set}"
: "${WAZUH_MANAGER_PORT:?WAZUH_MANAGER_PORT is not set}"
: "${WAZUH_VERSION:?WAZUH_VERSION is not set}"
: "${AGENT_NAME:?AGENT_NAME is not set}"

echo "[INFO] Checking Wazuh repository..."

if [[ ! -f /etc/apt/sources.list.d/wazuh.list ]]; then
    echo "[INFO] Adding Wazuh repository..."

    curl -fsSL https://packages.wazuh.com/key/GPG-KEY-WAZUH \
        | gpg --dearmor \
        -o /usr/share/keyrings/wazuh.gpg

    cat >/etc/apt/sources.list.d/wazuh.list <<EOF
deb [signed-by=/usr/share/keyrings/wazuh.gpg] https://packages.wazuh.com/4.x/apt stable main
EOF
fi

echo "[INFO] Updating package index..."
apt update

if dpkg-query -W -f='${Status}' wazuh-agent 2>/dev/null | grep -q "^install ok installed$"; then
    echo "[INFO] Wazuh Agent is already installed."
else
    echo "[INFO] Installing Wazuh Agent..."
    apt install -y wazuh-agent="${WAZUH_VERSION}"-1
fi

echo "[INFO] Installing configuration..."


sed \
    -e "s/{{WAZUH_MANAGER_ADDRESS}}/$WAZUH_MANAGER_ADDRESS/g" \
    -e "s/{{WAZUH_MANAGER_PORT}}/$WAZUH_MANAGER_PORT/g" \
    -e "s/{{AGENT_NAME}}/$AGENT_NAME/g" \
    "$SCRIPT_DIR/ossec.conf.template" > /var/ossec/etc/ossec.conf

echo "[INFO] Starting Wazuh Agent..."
systemctl enable wazuh-agent >/dev/null
systemctl restart wazuh-agent
if systemctl is-active --quiet wazuh-agent; then
    echo "[INFO] Wazuh Agent is running."
else
    echo "[ERROR] Failed to start Wazuh Agent."
    journalctl -u wazuh-agent -n 20 --no-pager
    exit 1
fi

echo ""
echo "Installation completed!"
echo "The Wazuh Agent has been started."
echo "Check the Wazuh Dashboard to verify the agent has enrolled successfully."