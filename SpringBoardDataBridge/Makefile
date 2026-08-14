ARCHS = arm64 arm64e
TARGET = iphone:clang:17.5:15.0
THEOS_PACKAGE_SCHEME = roothide

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = TOWXSpringBoardDataBridge
TOWXSpringBoardDataBridge_FILES = \
    TOWXV11Diagnostics.m \
    TOWXV11SessionControllerFinal.m \
    TOWXV11HostContext.m \
    TOWXV11WindowFollowerFix3.m \
    TOWXV11PlacementEngineFix3.m \
    TOWXV11AvatarViewFix3.m \
    TOWXV11AnimationController.m \
    TOWXV11Gate.m \
    TOWXV11DataControllerFix3.m \
    TOWXV11AvatarControllerFix2.m
TOWXSpringBoardDataBridge_CFLAGS = -fobjc-arc -fblocks -Wall -Wextra -Werror -Wno-deprecated-declarations -include TOWXObjCCompat.h
TOWXSpringBoardDataBridge_FRAMEWORKS = Foundation UIKit QuartzCore ImageIO

include $(THEOS_MAKE_PATH)/tweak.mk
