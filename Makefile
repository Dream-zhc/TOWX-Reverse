ARCHS = arm64 arm64e
TARGET ?= iphone:clang:latest:15.0
THEOS_PACKAGE_SCHEME = roothide

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = TOWXSpringBoardBridge TOWXWeChatProbe

TOWXSpringBoardBridge_FILES = SpringBoardBridge.c
TOWXSpringBoardBridge_CFLAGS = -fvisibility=hidden -Wall -Wextra -Werror
TOWXSpringBoardBridge_FRAMEWORKS = CoreFoundation

TOWXWeChatProbe_FILES = WeChatProbe.c
TOWXWeChatProbe_CFLAGS = -fvisibility=hidden -Wall -Wextra -Werror
TOWXWeChatProbe_FRAMEWORKS = CoreFoundation

include $(THEOS_MAKE_PATH)/tweak.mk
