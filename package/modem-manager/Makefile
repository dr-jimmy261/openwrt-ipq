include $(TOPDIR)/rules.mk

PKG_NAME:=modem-manager
PKG_VERSION:=1.2.0
PKG_RELEASE:=3

include $(INCLUDE_DIR)/package.mk

define Package/modem-manager
  SECTION:=utils
  CATEGORY:=Utilities
  TITLE:=Universal Cellular Modem Connection Manager (with LuCI Page)
  PKGARCH:=all
endef

define Package/modem-manager/description
  An automated connection watchdog loop supporting AT, CM, DHCP, and native PCIe MBIM modes with LuCI control.
endef

define Build/Compile
endef

define Package/modem-manager/install
	# Install the connection automation loop script
	$(INSTALL_DIR) $(1)/usr/bin
	$(INSTALL_BIN) ./files/modem-manager.script $(1)/usr/bin/modem-manager

	# Install the modem reinit script
	$(INSTALL_DIR) $(1)/usr/bin
	$(INSTALL_BIN) ./files/modem-reinit $(1)/usr/bin/modem-reinit

	# Install the modem reboot script
	$(INSTALL_DIR) $(1)/usr/bin
	$(INSTALL_BIN) ./files/modem-reboot $(1)/usr/bin/modem-reboot

	# Install the modem signal collection script
	$(INSTALL_DIR) $(1)/usr/bin
	$(INSTALL_BIN) ./files/modem-signal $(1)/usr/bin/modem-signal

	# Install the self-contained SMS collector and PDU decoder
	$(INSTALL_BIN) ./files/modem-sms $(1)/usr/bin/modem-sms

	# Install system boot hook controls
	$(INSTALL_DIR) $(1)/etc/init.d
	$(INSTALL_BIN) ./files/modem-manager.init $(1)/etc/init.d/modem-manager

	# Install the default system configuration structure
	$(INSTALL_DIR) $(1)/etc/config
	$(INSTALL_CONF) ./files/modem-manager.config $(1)/etc/config/modemmanager

	# Install the LuCI view template
	$(INSTALL_DIR) $(1)/usr/lib/lua/luci/view/modemmanager
	$(INSTALL_DATA) ./files/modemmanager-view.htm $(1)/usr/lib/lua/luci/view/modemmanager/view.htm

	# Install the LuCI controller with reinit action
	$(INSTALL_DIR) $(1)/usr/lib/lua/luci/controller
	$(INSTALL_DATA) ./files/modemmanager-controller.lua $(1)/usr/lib/lua/luci/controller/modemmanager.lua
endef

$(eval $(call BuildPackage,modem-manager))
