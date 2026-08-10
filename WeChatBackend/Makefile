ARCHS = arm64
TARGET = iphone:clang:17.5:15.0
THEOS_PACKAGE_SCHEME = roothide

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = TOWXWeChatBackend
TOWXWeChatBackend_FILES = TOWXWeChatBackend.m
TOWXWeChatBackend_CFLAGS = -fobjc-arc -Wall -Wextra -Werror -Wno-deprecated-declarations
TOWXWeChatBackend_FRAMEWORKS = Foundation UIKit

include $(THEOS_MAKE_PATH)/tweak.mk
