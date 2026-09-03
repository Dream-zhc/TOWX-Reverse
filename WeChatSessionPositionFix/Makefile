ARCHS = arm64 arm64e
TARGET = iphone:clang:latest:15.0

include $(THEOS)/makefiles/common.mk

LIBRARY_NAME = WXSessionPositionFix
WXSessionPositionFix_FILES = WXSessionPositionFix.m
WXSessionPositionFix_CFLAGS = -fobjc-arc -fblocks -Wall -Wextra -Wno-deprecated-declarations
WXSessionPositionFix_FRAMEWORKS = Foundation UIKit
WXSessionPositionFix_INSTALL_PATH = /Library/MobileSubstrate/DynamicLibraries

include $(THEOS_MAKE_PATH)/library.mk

after-stage::
	mkdir -p "$(THEOS_STAGING_DIR)/Library/MobileSubstrate/DynamicLibraries"
	cp WXSessionPositionFix.plist "$(THEOS_STAGING_DIR)/Library/MobileSubstrate/DynamicLibraries/WXSessionPositionFix.plist"
