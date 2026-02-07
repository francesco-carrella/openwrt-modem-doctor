#!/bin/sh
# create-ipk.sh — Build .ipk packages without the OpenWrt SDK
# Usage: ./create-ipk.sh
#
# Creates:
#   modem-doctor_0.1.0-1_all.ipk
#   luci-app-modem-doctor_0.1.0-1_all.ipk

set -e

# Prevent macOS extended attributes (._files) in tarballs
export COPYFILE_DISABLE=1

PKG_VERSION="0.1.0-1"
OUTDIR="$(pwd)/dist"

mkdir -p "$OUTDIR"

build_ipk() {
	local name="$1"
	local arch="${2:-all}"

	echo "=== Building ${name}_${PKG_VERSION}_${arch}.ipk ==="

	local workdir
	workdir=$(mktemp -d)
	mkdir -p "$workdir/control" "$workdir/data"

	# Sanitize name for function lookup (hyphens -> underscores)
	local func_name
	func_name=$(echo "$name" | tr '-' '_')

	# Copy data
	eval "prepare_${func_name}_data" "$workdir/data"

	# Copy control
	eval "prepare_${func_name}_control" "$workdir/control"

	# Create conffiles if applicable
	eval "prepare_${func_name}_conffiles" "$workdir/control" 2>/dev/null || true

	# Build inner tarballs
	# --format ustar: avoids PAX headers that BusyBox tar can't parse
	# --uid/--gid 0: sets root ownership (matches OpenWrt's ipkg-build)
	(cd "$workdir/control" && tar --format ustar --uid 0 --gid 0 -czf ../control.tar.gz .)
	(cd "$workdir/data" && tar --format ustar --uid 0 --gid 0 -czf ../data.tar.gz .)
	echo "2.0" > "$workdir/debian-binary"

	# Create .ipk (gzipped tar — matches OpenWrt's ipkg-build format)
	local ipk="$OUTDIR/${name}_${PKG_VERSION}_${arch}.ipk"
	(cd "$workdir" && tar --format ustar --uid 0 --gid 0 -czf "$ipk" ./debian-binary ./data.tar.gz ./control.tar.gz)

	rm -rf "$workdir"
	echo "  Created: $ipk"
}

# --- modem-doctor package ---

prepare_modem_doctor_data() {
	local dest="$1"

	mkdir -p "$dest/usr/lib/modem-doctor"
	cp modem-doctor/files/usr/lib/modem-doctor/modem-doctor-lib.sh "$dest/usr/lib/modem-doctor/"

	mkdir -p "$dest/usr/bin"
	cp modem-doctor/files/usr/bin/modem-doctor.sh "$dest/usr/bin/"
	cp modem-doctor/files/usr/bin/modem-doctor-setup.sh "$dest/usr/bin/"
	chmod +x "$dest/usr/bin/modem-doctor.sh" "$dest/usr/bin/modem-doctor-setup.sh"

	mkdir -p "$dest/etc/init.d"
	cp modem-doctor/files/etc/init.d/modem-doctor "$dest/etc/init.d/modem-doctor"
	chmod +x "$dest/etc/init.d/modem-doctor"

	mkdir -p "$dest/etc/config"
	cp modem-doctor/files/etc/config/modem-doctor "$dest/etc/config/modem-doctor"

	mkdir -p "$dest/etc/uci-defaults"
	cp modem-doctor/files/etc/uci-defaults/80-modem-doctor "$dest/etc/uci-defaults/80-modem-doctor"
	chmod +x "$dest/etc/uci-defaults/80-modem-doctor"
}

prepare_modem_doctor_control() {
	local dest="$1"

	cat > "$dest/control" <<EOF
Package: modem-doctor
Version: ${PKG_VERSION}
Architecture: all
Depends: comgt, jsonfilter, ethtool, sqm-scripts, kmod-sched-cake
Maintainer: Francesco Carrella <francesco-carrella@users.noreply.github.com>
Section: net
Description: Modem Connection Manager for Quectel Modems
License: Apache-2.0
EOF

	cat > "$dest/postinst" <<'EOF'
#!/bin/sh
if [ -z "${IPKG_INSTROOT}" ]; then
	/etc/init.d/modem-doctor enable 2>/dev/null
fi
exit 0
EOF
	chmod +x "$dest/postinst"

	cat > "$dest/prerm" <<'EOF'
#!/bin/sh
if [ -z "${IPKG_INSTROOT}" ]; then
	/etc/init.d/modem-doctor stop 2>/dev/null
	/etc/init.d/modem-doctor disable 2>/dev/null
fi
exit 0
EOF
	chmod +x "$dest/prerm"
}

prepare_modem_doctor_conffiles() {
	echo "/etc/config/modem-doctor" > "$1/conffiles"
}

# --- luci-app-modem-doctor package ---

prepare_luci_app_modem_doctor_data() {
	local dest="$1"

	# LuCI views (htdocs/ → /www/)
	mkdir -p "$dest/www/luci-static/resources/view/modem-doctor"
	cp luci-app-modem-doctor/htdocs/luci-static/resources/view/modem-doctor/status.js \
		"$dest/www/luci-static/resources/view/modem-doctor/"
	cp luci-app-modem-doctor/htdocs/luci-static/resources/view/modem-doctor/config.js \
		"$dest/www/luci-static/resources/view/modem-doctor/"

	# rpcd plugin (root/ → /)
	mkdir -p "$dest/usr/libexec/rpcd"
	cp luci-app-modem-doctor/root/usr/libexec/rpcd/luci.modem-doctor \
		"$dest/usr/libexec/rpcd/"
	chmod +x "$dest/usr/libexec/rpcd/luci.modem-doctor"

	# Menu, ACL, ucitrack
	mkdir -p "$dest/usr/share/luci/menu.d"
	cp luci-app-modem-doctor/root/usr/share/luci/menu.d/luci-app-modem-doctor.json \
		"$dest/usr/share/luci/menu.d/"

	mkdir -p "$dest/usr/share/rpcd/acl.d"
	cp luci-app-modem-doctor/root/usr/share/rpcd/acl.d/luci-app-modem-doctor.json \
		"$dest/usr/share/rpcd/acl.d/"

	mkdir -p "$dest/usr/share/ucitrack"
	cp luci-app-modem-doctor/root/usr/share/ucitrack/luci-app-modem-doctor.json \
		"$dest/usr/share/ucitrack/"

	# uci-defaults (clear LuCI cache + reload rpcd)
	mkdir -p "$dest/etc/uci-defaults"
	cp luci-app-modem-doctor/root/etc/uci-defaults/40_luci-modem-doctor \
		"$dest/etc/uci-defaults/"
	chmod +x "$dest/etc/uci-defaults/40_luci-modem-doctor"
}

prepare_luci_app_modem_doctor_control() {
	local dest="$1"

	cat > "$dest/control" <<EOF
Package: luci-app-modem-doctor
Version: ${PKG_VERSION}
Architecture: all
Depends: luci-base, modem-doctor
Maintainer: Francesco Carrella <francesco-carrella@users.noreply.github.com>
Section: luci
Description: LuCI Support for Modem Doctor
License: Apache-2.0
EOF
}

# --- Build both packages ---

build_ipk "modem-doctor"
build_ipk "luci-app-modem-doctor"

echo ""
echo "=== All packages built ==="
ls -la "$OUTDIR"/*.ipk
echo ""
echo "Install on router:"
echo "  scp -O $OUTDIR/*.ipk root@192.168.8.1:/tmp/"
echo "  ssh root@192.168.8.1 'opkg install /tmp/modem-doctor_*.ipk /tmp/luci-app-modem-doctor_*.ipk'"
