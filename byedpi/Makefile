include $(TOPDIR)/rules.mk

PKG_NAME:=byedpi
PKG_VERSION:=0.17.3
PKG_RELEASE:=1

PKG_SOURCE_VERSION:=ba532298de7b28cfe854aea83d061369d13ca290
PKG_SOURCE:=$(PKG_SOURCE_VERSION).tar.gz
PKG_SOURCE_URL:=https://github.com/hufrea/byedpi/archive/
PKG_HASH:=skip

PKG_LICENSE:=MIT
PKG_LICENSE_FILES:=LICENSE

PKG_BUILD_DIR:=$(BUILD_DIR)/$(PKG_NAME)-$(PKG_SOURCE_VERSION)
PKG_BUILD_PARALLEL:=1

include $(INCLUDE_DIR)/package.mk

define Package/byedpi
	SECTION:=net
	CATEGORY:=Network
	TITLE:=ByeDPI
	URL:=https://github.com/hufrea/byedpi
endef

define Package/byedpi/description
	Local SOCKS proxy server to bypass DPI (Deep Packet Inspection)
endef

define Package/byedpi/install
	$(INSTALL_DIR) $(1)/usr/bin
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/ciadpi $(1)/usr/bin

	$(INSTALL_DIR) $(1)/etc/init.d
	$(INSTALL_BIN) ./files/byedpi.init $(1)/etc/init.d/byedpi

	$(INSTALL_DIR) $(1)/etc/config
	$(INSTALL_CONF) ./files/byedpi.config $(1)/etc/config/byedpi
endef

$(eval $(call BuildPackage,byedpi))
