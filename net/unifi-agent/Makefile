# SPDX-License-Identifier: GPL-2.0-only

include $(TOPDIR)/rules.mk

PKG_NAME:=unifi-agent
PKG_VERSION:=0.1
PKG_RELEASE:=5

PKG_MAINTAINER:=Andre Brait <andrebrait@gmail.com>
PKG_LICENSE:=GPL-2.0-only

include $(INCLUDE_DIR)/package.mk

define Package/unifi-agent
  SECTION:=net
  CATEGORY:=Network
  TITLE:=Adopt this device into a UniFi Network controller
  DEPENDS:=+ucode +ucode-mod-fs +ucode-mod-uci +ucode-mod-socket \
	+ucode-mod-struct +ucode-mod-zlib +libucode +libmbedtls \
	+ip-bridge +ethtool
endef

define Package/unifi-agent/description
  Speaks the UniFi inform protocol so that a UniFi Network controller
  adopts this OpenWrt device as a UniFi switch or access point of a chosen
  model. The controller's port, VLAN, link aggregation, STP, IGMP and
  Wi-Fi settings are translated to UCI and applied, with a rollback if the
  controller is unreachable afterwards; port, client and system status is
  reported back. Firmware upgrades from the controller are refused.
endef

define Package/unifi-agent/conffiles
/etc/config/unifi-agent
/etc/unifi-agent/
endef

define Package/unifi-agent/prerm
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] || /usr/sbin/unifi-agent cleanup
exit 0
endef

define Build/Compile
	$(TARGET_CC) $(TARGET_CPPFLAGS) $(TARGET_CFLAGS) -Wall -fPIC -shared \
		-o $(PKG_BUILD_DIR)/aes.so ./src/aes.c \
		$(TARGET_LDFLAGS) -lucode -lmbedcrypto
endef

define Package/unifi-agent/install
	$(INSTALL_DIR) $(1)/usr/lib/ucode/unifi
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/aes.so $(1)/usr/lib/ucode/unifi/
	$(CP) ./files/* $(1)/
endef

$(eval $(call BuildPackage,unifi-agent))
