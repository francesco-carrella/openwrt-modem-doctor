#!/bin/sh
# deploy.sh — Deploy modem-doctor to router for development/testing
# Usage: ./deploy.sh [user@router_ip]

set -e

ROUTER="${1:-root@192.168.8.1}"
PKG="modem-doctor"
SCP="scp -O"  # -O flag needed for Dropbear (no sftp-server)

echo "=== Deploying $PKG to $ROUTER ==="

# --- Backend: library ---
echo "[1/8] Library..."
ssh "$ROUTER" "mkdir -p /usr/lib/modem-doctor"
$SCP modem-doctor/files/usr/lib/modem-doctor/modem-doctor-lib.sh "$ROUTER:/usr/lib/modem-doctor/modem-doctor-lib.sh"
ssh "$ROUTER" "chmod 644 /usr/lib/modem-doctor/modem-doctor-lib.sh"

# --- Backend: scripts ---
echo "[2/8] Scripts..."
$SCP modem-doctor/files/usr/bin/modem-doctor.sh "$ROUTER:/usr/bin/modem-doctor.sh"
$SCP modem-doctor/files/usr/bin/modem-doctor-setup.sh "$ROUTER:/usr/bin/modem-doctor-setup.sh"
ssh "$ROUTER" "chmod +x /usr/bin/modem-doctor.sh /usr/bin/modem-doctor-setup.sh"

# --- Backend: init script ---
echo "[3/8] Init script..."
$SCP modem-doctor/files/etc/init.d/modem-doctor "$ROUTER:/etc/init.d/modem-doctor"
ssh "$ROUTER" "chmod +x /etc/init.d/modem-doctor"

# --- Backend: UCI config (only if not exists — preserves user settings) ---
echo "[4/8] UCI config..."
ssh "$ROUTER" "[ -f /etc/config/modem-doctor ]" 2>/dev/null || \
	$SCP modem-doctor/files/etc/config/modem-doctor "$ROUTER:/etc/config/modem-doctor"

# --- LuCI: rpcd plugin ---
echo "[5/8] rpcd plugin..."
ssh "$ROUTER" "mkdir -p /usr/libexec/rpcd"
$SCP luci-app-modem-doctor/root/usr/libexec/rpcd/luci.modem-doctor "$ROUTER:/usr/libexec/rpcd/luci.modem-doctor"
ssh "$ROUTER" "chmod +x /usr/libexec/rpcd/luci.modem-doctor"

# --- LuCI: views ---
echo "[6/8] LuCI views..."
ssh "$ROUTER" "mkdir -p /www/luci-static/resources/view/modem-doctor"
$SCP luci-app-modem-doctor/htdocs/luci-static/resources/view/modem-doctor/status.js \
	"$ROUTER:/www/luci-static/resources/view/modem-doctor/status.js"
$SCP luci-app-modem-doctor/htdocs/luci-static/resources/view/modem-doctor/config.js \
	"$ROUTER:/www/luci-static/resources/view/modem-doctor/config.js"

# --- LuCI: menu, ACL, ucitrack ---
echo "[7/8] LuCI config..."
ssh "$ROUTER" "mkdir -p /usr/share/luci/menu.d /usr/share/rpcd/acl.d /usr/share/ucitrack"
$SCP luci-app-modem-doctor/root/usr/share/luci/menu.d/luci-app-modem-doctor.json \
	"$ROUTER:/usr/share/luci/menu.d/luci-app-modem-doctor.json"
$SCP luci-app-modem-doctor/root/usr/share/rpcd/acl.d/luci-app-modem-doctor.json \
	"$ROUTER:/usr/share/rpcd/acl.d/luci-app-modem-doctor.json"
$SCP luci-app-modem-doctor/root/usr/share/ucitrack/luci-app-modem-doctor.json \
	"$ROUTER:/usr/share/ucitrack/luci-app-modem-doctor.json"

# --- Run uci-defaults (clear cache + reload rpcd) ---
echo "[8/8] Clearing cache..."
ssh "$ROUTER" "sh /etc/uci-defaults/40_luci-modem-doctor 2>/dev/null || true"

# --- Reload services ---
echo ""
echo "=== Reloading services ==="
ssh "$ROUTER" "rm -rf /tmp/luci-indexcache /tmp/luci-modulecache /tmp/luci-*; echo 'LuCI cache cleared'"
ssh "$ROUTER" "/etc/init.d/rpcd reload 2>/dev/null; echo 'rpcd reloaded'"
ssh "$ROUTER" "/etc/init.d/modem-doctor enable 2>/dev/null; echo 'modem-doctor enabled'"

# Extract host from ROUTER (strip user@ prefix)
ROUTER_HOST="${ROUTER#*@}"

echo ""
echo "=== Deploy complete ==="
echo "Next steps:"
echo "  1. SSH to router and enable: uci set modem-doctor.main.enabled=1 && uci commit modem-doctor"
echo "  2. Start service: /etc/init.d/modem-doctor start"
echo "  3. Clear browser cache, then visit: http://${ROUTER_HOST}/cgi-bin/luci/admin/services/modem-doctor"
echo "  4. Test rpcd: ssh $ROUTER 'ubus call luci.modem-doctor get_status'"
