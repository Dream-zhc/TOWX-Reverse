ARCHS = arm64
TARGET = iphone:clang:17.5:15.0
THEOS_PACKAGE_SCHEME = roothide

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = TOWXGoldenAdapter
TOWXGoldenAdapter_FILES = TOWXGoldenAdapter.m
TOWXGoldenAdapter_CFLAGS = -fobjc-arc -fblocks -Wall -Wextra -Wno-deprecated-declarations -include TOWXUIKitCompat.h
TOWXGoldenAdapter_FRAMEWORKS = Foundation UIKit

include $(THEOS_MAKE_PATH)/tweak.mk
