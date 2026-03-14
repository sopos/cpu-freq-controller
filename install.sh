#!/bin/bash

###############################################################################
# CPU Frequency Controller - Installation Script
###############################################################################

set -e

SCRIPT_NAME="cpu-freq-controller.sh"
SERVICE_NAME="cpu-freq-controller.service"
CONFIG_NAME="cpu-freq-controller.conf"
INSTALL_PATH="/usr/local/bin/cpu-freq-controller.sh"
SERVICE_PATH="/etc/systemd/system/cpu-freq-controller.service"
CONFIG_PATH="/etc/cpu-freq-controller.conf"

# Check if running as root
if [[ $EUID -ne 0 ]]; then
    echo "Error: This installation script must be run as root" >&2
    exit 1
fi

echo "Installing CPU Frequency Controller..."

# Install the script
echo "Installing script to $INSTALL_PATH"
cp "$SCRIPT_NAME" "$INSTALL_PATH"
chmod 755 "$INSTALL_PATH"

# Install the systemd service
echo "Installing systemd service to $SERVICE_PATH"
cp "$SERVICE_NAME" "$SERVICE_PATH"
chmod 644 "$SERVICE_PATH"

# Install the configuration file (only if it doesn't exist)
if [[ -f "$CONFIG_PATH" ]]; then
    echo "Configuration file already exists at $CONFIG_PATH (preserving existing)"
else
    echo "Installing configuration file to $CONFIG_PATH"
    cp "$CONFIG_NAME" "$CONFIG_PATH"
    chmod 644 "$CONFIG_PATH"
fi

# Reload systemd
echo "Reloading systemd daemon..."
systemctl daemon-reload

echo ""
echo "Installation complete!"
echo ""
echo "Configuration file: $CONFIG_PATH"
echo "Edit this file to customize temperature limits and frequency settings."
echo ""
echo "To enable and start the service:"
echo "  sudo systemctl enable cpu-freq-controller"
echo "  sudo systemctl start cpu-freq-controller"
echo ""
echo "To check service status:"
echo "  sudo systemctl status cpu-freq-controller"
echo ""
echo "To view logs:"
echo "  sudo journalctl -u cpu-freq-controller -f"
echo ""
