#!/bin/sh
#
# build-ipk.sh — assemble a standalone luci-app-tailscale-updater .ipk
# without the OpenWrt SDK.
#
# iStoreOS ships the classic "ipkg" container:
#     .ipk = gzip( tar( ./debian-binary, ./data.tar.gz, ./control.tar.gz ) )
# (NOT the Debian-style `ar` archive — that one is rejected by iStoreOS's
#  opkg with "pkg_init_from_file: Malformed package file".)
#
# This script therefore emits the gzip-tar format, and additionally an `ar`
# variant for stock OpenWrt opkg builds.
#
# Results:
#   dist/luci-app-tailscale-updater_<ver>-<rel>_all.ipk     <- install on iStoreOS
#   dist/luci-app-tailscale-updater_<ver>-<rel>_all-ar.ipk  <- stock OpenWrt opkg
#
set -eu

HERE="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
NAME="luci-app-tailscale-updater"
META_NAME="tailscale-updater"
VERSION="1.0.0"
RELEASE="1"
ARCH="all"
TITLE_ZH="Tailscale 更新"
TITLE_EN="Tailscale Updater"
DESC_ZH="把 iStore 安装的 Tailscale 从 1.80.3-1 更新到官方最新稳定版，保留配置与登录状态"
DESC_EN="Update the iStore-installed Tailscale from 1.80.3-1 to the latest upstream stable release, keeping config and login state."
# Opening the app (from iStore or the LuCI menu) should land on the status /
# "check update" page by default. The update itself is triggered by the button
# on that page (or via ?run=1 if you ever want a direct one-tap entry).
LUCI_ENTRY="/cgi-bin/luci/admin/services/tailscale-updater"

APP_DIR="$HERE/luci-app-tailscale-updater"
SCRIPT_SRC="$HERE/tailscale-update.sh"
OUT_DIR="$HERE/dist"
PKG="${NAME}_${VERSION}-${RELEASE}_${ARCH}.ipk"
PKG_AR="${NAME}_${VERSION}-${RELEASE}_${ARCH}-ar.ipk"

log() { printf '%s\n' "$*" >&2; }
die() { log "error: $*"; exit 1; }

[ -f "$SCRIPT_SRC" ] || die "missing $SCRIPT_SRC"
[ -d "$APP_DIR" ]    || die "missing $APP_DIR"
command -v tar >/dev/null 2>&1 || die "tar not found"
command -v gzip >/dev/null 2>&1 || die "gzip not found"

# keep a synced copy inside the package so an SDK build is also self-contained
mkdir -p "$APP_DIR/root/usr/libexec"
cp -f "$SCRIPT_SRC" "$APP_DIR/root/usr/libexec/tailscale-update"
chmod 0755 "$APP_DIR/root/usr/libexec/tailscale-update"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT INT TERM

DATA="$WORK/data"
CTRL="$WORK/control"
STAGE="$WORK/stage"
mkdir -p "$DATA" "$CTRL" "$STAGE"

# ---- data payload --------------------------------------------------------
# root/  -> filesystem root (menu.d, acl.d, the script)
# htdocs/ -> /www  (luci.mk installs HTDOCS into $(1)/www; dropping it at the
#            root instead makes LuCI 404 on /luci-static/resources/view/...)
( cd "$APP_DIR/root" && tar cf - . ) | ( cd "$DATA" && tar xf - )
mkdir -p "$DATA/www"
( cd "$APP_DIR/htdocs" && tar cf - . ) | ( cd "$DATA/www" && tar xf - )
chmod 0755 "$DATA/usr/libexec/tailscale-update"

# iStore catalog metadata (so it also shows up inside iStore)
mkdir -p "$DATA/usr/lib/opkg/meta" "$DATA/lib/apk/meta"
meta_json() {
	cat <<EOF
{
  "name": "$META_NAME",
  "title": "$TITLE_ZH",
  "title_en": "$TITLE_EN",
  "entry": "$LUCI_ENTRY",
  "author": "kaliliu",
  "website": "https://tailscale.com/",
  "version": "$VERSION",
  "release": $RELEASE,
  "arch": ["$ARCH"],
  "description": "$DESC_ZH",
  "description_en": "$DESC_EN",
  "tags": ["networking", "service"],
  "depends": ["$NAME"]
}
EOF
}
meta_json > "$DATA/usr/lib/opkg/meta/$META_NAME.json"
meta_json > "$DATA/lib/apk/meta/$META_NAME.json"

# ---- control -------------------------------------------------------------
ISIZE="$(du -sk "$DATA" | awk '{print $1}')"
cat > "$CTRL/control" <<EOF
Package: $NAME
Version: $VERSION-$RELEASE
Depends: libc, luci-base, curl
Source: istoreos-tailscale-updater
SourceName: $NAME
License: MIT
Maintainer: kaliliu
Section: luci
SectionName: LuCI
Architecture: $ARCH
Installed-Size: $ISIZE
Description:  $TITLE_EN / $TITLE_ZH
 $DESC_EN
 $DESC_ZH
EOF

# luci.mk normally generates this postinst; we reproduce it so the menu entry
# and ACL become active right after install (otherwise the ACL is not loaded
# until a manual `rpcd reload`, and the LuCI page stays hidden/denied).
cat > "$CTRL/postinst" <<'EOF'
#!/bin/sh
[ -n "${IPKG_INSTROOT}" ] || {
	rm -f /tmp/luci-indexcache.*
	rm -rf /tmp/luci-modulecache/
	/etc/init.d/rpcd reload 2>/dev/null
	exit 0
}
EOF
chmod 0755 "$CTRL/postinst"

cat > "$CTRL/prerm" <<'EOF'
#!/bin/sh
[ -n "${IPKG_INSTROOT}" ] || {
	rm -f /tmp/luci-indexcache.*
	rm -rf /tmp/luci-modulecache/
	/etc/init.d/rpcd reload 2>/dev/null
	exit 0
}
EOF
chmod 0755 "$CTRL/prerm"

# ---- inner tarballs (both are plain gzip'd tars with ./ prefixed members) --
( cd "$DATA" && tar --owner=0 --group=0 --numeric-owner -czf "$STAGE/data.tar.gz" . )
( cd "$CTRL" && tar --owner=0 --group=0 --numeric-owner -czf "$STAGE/control.tar.gz" . )
printf '2.0\n' > "$STAGE/debian-binary"

mkdir -p "$OUT_DIR"

# ---- 1) iStoreOS / classic ipkg container: gzip(tar(...)) -----------------
rm -f "$OUT_DIR/$PKG"
( cd "$STAGE" && tar -czf "$OUT_DIR/$PKG" ./debian-binary ./data.tar.gz ./control.tar.gz ) \
	|| die "tar packaging failed"

# ---- 2) stock OpenWrt opkg container: ar ---------------------------------
if command -v ar >/dev/null 2>&1; then
	rm -f "$OUT_DIR/$PKG_AR"
	( cd "$STAGE" && ar rc "$OUT_DIR/$PKG_AR" debian-binary control.tar.gz data.tar.gz ) \
		|| log "warn: ar variant not built"
fi

log ""
log "built: $OUT_DIR/$PKG            (iStoreOS / ipkg gzip-tar)"
[ -f "$OUT_DIR/$PKG_AR" ] && log "built: $OUT_DIR/$PKG_AR  (stock OpenWrt opkg / ar)"
log "inner size: $(wc -c < "$STAGE/data.tar.gz" | tr -d ' ') bytes data, Installed-Size ${ISIZE} KB"
log ""
log "md5:    $(md5sum "$OUT_DIR/$PKG" | awk '{print $1}')"
log "sha256: $(sha256sum "$OUT_DIR/$PKG" | awk '{print $1}')"
