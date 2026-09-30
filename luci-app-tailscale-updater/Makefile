#
# luci-app-tailscale-updater — LuCI frontend for the iStoreOS Tailscale updater
#
# Drop this directory into your OpenWrt/iStoreOS SDK's package/ tree (or add
# this repo as a feed) and build with:
#     ./scripts/feeds update -a && ./scripts/feeds install -a
#     make package/luci-app-tailscale-updater/compile V=s
#
include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-tailscale-updater
PKG_VERSION:=1.0.0
PKG_RELEASE:=1

PKG_LICENSE:=MIT
PKG_MAINTAINER:=kaliliu

LUCI_TITLE:=LuCI app for the iStoreOS Tailscale updater
LUCI_DEPENDS:=+luci-base +curl
LUCI_PKGARCH:=all

include $(TOPDIR)/feeds/luci/luci.mk

# luci.mk auto-installs ./htdocs and ./root, and defines the postinst that
# reloads rpcd and clears the LuCI caches.

# call BuildPackage - OpenWrt buildroot signature
