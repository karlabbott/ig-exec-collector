#!/bin/bash
set -euo pipefail

# ig-exec-collector install script for RHEL 10
# Usage: sudo ./install.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="/opt/ig-collector"
CONFIG_DIR="/etc/ig-collector"

echo "========================================="
echo "  Inspektor Gadget Exec Collector Setup"
echo "========================================="

# Check root
if [[ $EUID -ne 0 ]]; then
    echo "Error: This script must be run as root (use sudo)."
    exit 1
fi

# Check RHEL/compatible
if ! command -v dnf &>/dev/null; then
    echo "Error: dnf not found. This script is designed for RHEL 10 / compatible distros."
    exit 1
fi

echo ""
echo "[1/5] Installing dependencies..."
dnf install -y python3 curl jq &>/dev/null
echo "  ✓ Python3, curl, jq installed"

echo ""
echo "[2/5] Installing Inspektor Gadget..."
if command -v ig &>/dev/null; then
    CURRENT_VERSION=$(ig version 2>/dev/null || echo "unknown")
    echo "  ✓ Inspektor Gadget already installed ($CURRENT_VERSION)"
else
    IG_ARCH=$(uname -m)
    case "$IG_ARCH" in
        x86_64) IG_ARCH="amd64" ;;
        aarch64) IG_ARCH="arm64" ;;
        *) echo "Error: Unsupported architecture: $IG_ARCH"; exit 1 ;;
    esac
    IG_VERSION=$(curl -s https://api.github.com/repos/inspektor-gadget/inspektor-gadget/releases/latest | jq -r .tag_name)
    echo "  Downloading Inspektor Gadget $IG_VERSION ($IG_ARCH)..."
    curl -sL "https://github.com/inspektor-gadget/inspektor-gadget/releases/download/${IG_VERSION}/ig-linux-${IG_ARCH}-${IG_VERSION}.tar.gz" \
        | tar -C /usr/local/bin -xzf - ig
    ln -sf /usr/local/bin/ig /usr/bin/ig
    echo "  ✓ Inspektor Gadget $IG_VERSION installed"
fi

# Verify kernel supports BTF
echo ""
echo "[3/5] Checking kernel requirements..."
KERNEL_VERSION=$(uname -r)
echo "  Kernel: $KERNEL_VERSION"
if [[ -f /sys/kernel/btf/vmlinux ]]; then
    echo "  ✓ BTF support available"
else
    echo "  ⚠ BTF not found at /sys/kernel/btf/vmlinux - IG may not work correctly"
fi

echo ""
echo "[4/5] Installing collector..."
mkdir -p "$INSTALL_DIR"
mkdir -p "$CONFIG_DIR"
cp "$SCRIPT_DIR/ig-collector.py" "$INSTALL_DIR/ig-collector.py"
chmod +x "$INSTALL_DIR/ig-collector.py"

# Install env file if not already present
if [[ ! -f "$CONFIG_DIR/ig-collector.env" ]]; then
    cp "$SCRIPT_DIR/ig-collector.env.example" "$CONFIG_DIR/ig-collector.env"
    chmod 600 "$CONFIG_DIR/ig-collector.env"
    echo "  ✓ Config file created at $CONFIG_DIR/ig-collector.env"
    echo "  ⚠ You MUST edit $CONFIG_DIR/ig-collector.env with your Log Analytics credentials"
    NEEDS_CONFIG=true
else
    echo "  ✓ Config file already exists at $CONFIG_DIR/ig-collector.env (preserved)"
    NEEDS_CONFIG=false
fi

echo ""
echo "[5/5] Installing systemd service..."
cp "$SCRIPT_DIR/ig-collector.service" /etc/systemd/system/ig-collector.service
systemctl daemon-reload
systemctl enable ig-collector

echo ""
echo "========================================="
echo "  Installation complete!"
echo "========================================="
echo ""

if [[ "$NEEDS_CONFIG" == "true" ]]; then
    echo "Next steps:"
    echo "  1. Edit /etc/ig-collector/ig-collector.env with your Log Analytics credentials"
    echo "     sudo vi /etc/ig-collector/ig-collector.env"
    echo ""
    echo "  2. Start the collector:"
    echo "     sudo systemctl start ig-collector"
    echo ""
    echo "  3. Check status:"
    echo "     sudo systemctl status ig-collector"
    echo "     sudo journalctl -u ig-collector -f"
else
    echo "Starting collector..."
    systemctl restart ig-collector
    echo ""
    echo "Status:"
    systemctl status ig-collector --no-pager || true
fi
