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

# Validate variables
: "${MANAGER_IP:?MANAGER_IP is not set}"
: "${AGENT_NAME:?AGENT_NAME is not set}"

if [[ -f /var/ossec/etc/client.keys ]]; then
    echo "[INFO] Agent already registered."
    exit 0
fi

echo "[INFO] Registering agent..."

/var/ossec/bin/agent-auth \
    -m "$MANAGER_IP" \
    -A "$AGENT_NAME"

echo "[INFO] Restarting Wazuh Agent..."

systemctl restart wazuh-agent

echo "[INFO] Agent registration completed."