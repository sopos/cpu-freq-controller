#!/bin/bash

###############################################################################
# CPU Frequency Controller - Uninstallation Script
###############################################################################

set -e

INSTALL_PATH="/usr/local/bin/cpu-freq-controller.sh"
SERVICE_PATH="/etc/systemd/system/cpu-freq-controller.service"
CONFIG_PATH="/etc/cpu-freq-controller.conf"

# Check if running as root
if [[ $EUID -ne 0 ]]; then
    echo "Error: This uninstallation script must be run as root" >&2
    exit 1
fi

echo "Uninstalling CPU Frequency Controller..."

# Stop and disable the service
if systemctl is-active --quiet cpu-freq-controller; then
    echo "Stopping cpu-freq-controller service..."
    systemctl stop cpu-freq-controller
fi

if systemctl is-enabled --quiet cpu-freq-controller 2>/dev/null; then
    echo "Disabling cpu-freq-controller service..."
    systemctl disable cpu-freq-controller
fi

# Remove the service file
if [[ -f "$SERVICE_PATH" ]]; then
    echo "Removing service file: $SERVICE_PATH"
    rm -f "$SERVICE_PATH"
fi

# Remove the script
if [[ -f "$INSTALL_PATH" ]]; then
    echo "Removing script: $INSTALL_PATH"
    rm -f "$INSTALL_PATH"
fi

# Ask about configuration file
if [[ -f "$CONFIG_PATH" ]]; then
    echo ""
    read -p "Remove configuration file $CONFIG_PATH? (y/N): " -n 1 -r
    echo ""
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        echo "Removing configuration file: $CONFIG_PATH"
        rm -f "$CONFIG_PATH"
    else
        echo "Keeping configuration file: $CONFIG_PATH"
    fi
fi

# Reload systemd
echo "Reloading systemd daemon..."
systemctl daemon-reload

echo ""
echo "Uninstallation complete!"
echo ""
