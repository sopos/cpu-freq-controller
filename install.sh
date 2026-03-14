#!/bin/bash

###############################################################################
# CPU Frequency Controller - Installation Script
###############################################################################

set -e

SCRIPT_NAME="cpu-freq-controller.sh"
SERVICE_NAME="cpu-freq-controller.service"
INSTALL_PATH="/usr/local/bin/cpu-freq-controller.sh"
SERVICE_PATH="/etc/systemd/system/cpu-freq-controller.service"

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

# Reload systemd
echo "Reloading systemd daemon..."
systemctl daemon-reload

echo ""
echo "Installation complete!"
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
echo "  sudo tail -f /var/log/cpu-freq-controller.log"
echo ""
