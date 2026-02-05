#!/bin/bash
set -euo pipefail

# Uninstall ig-exec-collector

echo "Uninstalling Inspektor Gadget Exec Collector..."

if [[ $EUID -ne 0 ]]; then
    echo "Error: This script must be run as root (use sudo)."
    exit 1
fi

# Stop and disable service
if systemctl is-active ig-collector &>/dev/null; then
    echo "  Stopping ig-collector service..."
    systemctl stop ig-collector
fi

if systemctl is-enabled ig-collector &>/dev/null; then
    systemctl disable ig-collector
fi

# Remove files
rm -f /etc/systemd/system/ig-collector.service
systemctl daemon-reload

rm -rf /opt/ig-collector

echo ""
echo "Uninstalled. Config preserved at /etc/ig-collector/ (remove manually if desired)."
echo "Inspektor Gadget binary preserved at /usr/local/bin/ig (remove manually if desired)."
