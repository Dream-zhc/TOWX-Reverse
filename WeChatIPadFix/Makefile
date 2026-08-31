SDK ?= $(shell xcrun --sdk iphoneos --show-sdk-path)
MACOS_SDK ?= $(shell xcrun --sdk macosx --show-sdk-path)
CLANG ?= $(shell xcrun --find clang)
OUT_DIR ?= build
TARGET ?= arm64-apple-ios15.0
MACOS_TARGET ?= arm64-apple-macos13.0
SOURCES := $(wildcard Sources/*.m)
OUTPUT := $(OUT_DIR)/WeChatIPadFix.dylib

.PHONY: all clean test

all: $(OUTPUT)

$(OUTPUT): $(SOURCES)
	@mkdir -p $(OUT_DIR)
	$(CLANG) -target $(TARGET) -isysroot $(SDK) -fobjc-arc -fblocks \
		-Wall -Wextra -Werror -Wno-deprecated-declarations \
		-dynamiclib -install_name @rpath/WeChatIPadFix.dylib \
		-framework Foundation -framework UIKit \
		-Wl,-dead_strip -o $@ $(SOURCES)

clean:
	rm -rf $(OUT_DIR)

test:
	@mkdir -p $(OUT_DIR)
	$(CLANG) -target $(MACOS_TARGET) -isysroot $(MACOS_SDK) -fobjc-arc \
		-Wall -Wextra -Werror -framework Foundation \
		-o $(OUT_DIR)/restore-policy-tests Tests/RestorePolicyTests.m Sources/WXIFRestorePolicy.m
	$(OUT_DIR)/restore-policy-tests
