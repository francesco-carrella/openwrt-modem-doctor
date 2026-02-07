#
# Copyright (c) 2026 modem-doctor contributors
# Licensed under Apache-2.0
#

include $(TOPDIR)/rules.mk

PKG_NAME:=modem-doctor
PKG_VERSION:=0.1.0
PKG_RELEASE:=1

PKG_MAINTAINER:=Francesco Carrella <francesco-carrella@users.noreply.github.com>
PKG_LICENSE:=Apache-2.0

include $(INCLUDE_DIR)/package.mk

define Package/modem-doctor
  SECTION:=net
  CATEGORY:=Network
  TITLE:=Modem Connection Manager for Quectel Modems
  DEPENDS:=+comgt +jsonfilter +ethtool +sqm-scripts +kmod-sched-cake
  PKGARCH:=all
endef

define Package/modem-doctor/description
Modem Doctor monitors cellular connection quality on Quectel modems and
automatically recovers from latency spikes and connection drops.
Includes SQM/CAKE traffic shaping, bufferbloat fixes (txqueuelen, GRO),
modem sleep management, and a smart watchdog with progressive recovery.
endef

define Package/modem-doctor/conffiles
/etc/config/modem-doctor
endef

define Build/Configure
endef

define Build/Compile
endef

define Package/modem-doctor/install
	$(INSTALL_DIR) $(1)/usr/lib/modem-doctor
	$(INSTALL_DATA) ./files/usr/lib/modem-doctor/modem-doctor-lib.sh $(1)/usr/lib/modem-doctor/

	$(INSTALL_DIR) $(1)/usr/bin
	$(INSTALL_BIN) ./files/usr/bin/modem-doctor.sh $(1)/usr/bin/
	$(INSTALL_BIN) ./files/usr/bin/modem-doctor-setup.sh $(1)/usr/bin/

	$(INSTALL_DIR) $(1)/etc/init.d
	$(INSTALL_BIN) ./files/etc/init.d/modem-doctor $(1)/etc/init.d/

	$(INSTALL_DIR) $(1)/etc/config
	$(INSTALL_CONF) ./files/etc/config/modem-doctor $(1)/etc/config/

	$(INSTALL_DIR) $(1)/etc/uci-defaults
	$(INSTALL_BIN) ./files/etc/uci-defaults/80-modem-doctor $(1)/etc/uci-defaults/
endef

define Package/modem-doctor/postinst
#!/bin/sh
if [ -z "$${IPKG_INSTROOT}" ]; then
	/etc/init.d/modem-doctor enable 2>/dev/null
fi
exit 0
endef

define Package/modem-doctor/prerm
#!/bin/sh
if [ -z "$${IPKG_INSTROOT}" ]; then
	/etc/init.d/modem-doctor stop 2>/dev/null
	/etc/init.d/modem-doctor disable 2>/dev/null
fi
exit 0
endef

$(eval $(call BuildPackage,modem-doctor))
