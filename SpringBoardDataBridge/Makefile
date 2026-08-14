ARCHS = arm64 arm64e
TARGET = iphone:clang:17.5:15.0
THEOS_PACKAGE_SCHEME = roothide

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = TOWXSpringBoardDataBridge
TOWXSpringBoardDataBridge_FILES = TOWXSpringBoardProductV10.m TOWXTrollOpen140Anchor.m TOWXV11SessionController.m
TOWXSpringBoardDataBridge_CFLAGS = -fobjc-arc -fblocks -Wall -Wextra -Wno-deprecated-declarations -include TOWXObjCCompat.h
TOWXSpringBoardDataBridge_FRAMEWORKS = Foundation UIKit

include $(THEOS_MAKE_PATH)/tweak.mk
