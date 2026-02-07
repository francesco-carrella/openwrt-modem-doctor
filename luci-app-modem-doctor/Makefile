#
# Copyright (c) 2026 modem-doctor contributors
# Licensed under Apache-2.0
#

include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-modem-doctor
PKG_VERSION:=0.1.0
PKG_RELEASE:=1

PKG_MAINTAINER:=Francesco Carrella <francesco-carrella@users.noreply.github.com>
PKG_LICENSE:=Apache-2.0

LUCI_TITLE:=LuCI Support for Modem Doctor
LUCI_DESCRIPTION:=Web interface for modem monitoring and connection management
LUCI_DEPENDS:=+luci-base +modem-doctor

include $(TOPDIR)/feeds/luci/luci.mk

# call BuildPackage - OpenWrt buildroot signature
