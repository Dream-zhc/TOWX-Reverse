ARCHS = arm64 arm64e
TARGET = iphone:clang:17.5:15.0
THEOS_PACKAGE_SCHEME = roothide

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = TOWXSpringBoardDataBridge
TOWXSpringBoardDataBridge_FILES = TOWXSpringBoardDataBridge.c
TOWXSpringBoardDataBridge_CFLAGS = -Wall -Wextra -Werror -fvisibility=hidden -fblocks

include $(THEOS_MAKE_PATH)/tweak.mk
