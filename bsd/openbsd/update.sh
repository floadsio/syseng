#!/bin/sh

echo "=== OpenBSD Update ==="

# 1. syspatch
echo "[1/3] Checking syspatch..."
if output=$(syspatch -c 2>&1) && [ -z "$output" ]; then
    echo "   No syspatch updates available."
elif [ -n "$output" ]; then
    echo "   Available patches:"
    echo "$output" | sed 's/^/     /'
    echo "   Installing syspatch patches..."
    if ! syspatch; then
        echo "   syspatch failed!"
        exit 1
    fi
    if [ -f /var/run/reboot-required ]; then
        echo ""
        echo "   REBOOT REQUIRED"
        echo "   After reboot: doas $0"
        echo ""
        exit 0
    fi
else
    echo "   syspatch check failed:"
    echo "   $output"
    exit 1
fi
echo ""

# 2. pkgupdate
echo "[2/3] pkgupdate dry-run..."
pkgupdate -n || { echo "   pkgupdate dry-run failed!"; exit 1; }
echo ""

echo "[3/3] Updating packages..."
pkgupdate || echo "   pkgupdate failed!"

echo ""
echo "=== Update finished ==="

