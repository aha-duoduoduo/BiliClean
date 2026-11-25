ifneq ($(filter release,$(MAKECMDGOALS)),)
export FINALPACKAGE = 1
endif

TARGET := iphone:clang:latest:14.0
ARCHS = arm64 arm64e

INSTALL_TARGET_PROCESSES = tv.danmaku.bilianime tv.danmaku.bilianime2

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = BiliClean

BiliClean_FILES = Tweak.x BLCOfflineAccountHooks.m BLCCDNManager.m BLCCDNSpeedProbe.m BLCTabManager.m BLCFeatureSettingsViewControllers.m BLCSettingsTransfer.m BLCAirPlayHooks.m BLCVipQualityHooks.m $(wildcard Download/*.m)
BiliClean_CFLAGS = -fobjc-arc
BiliClean_FRAMEWORKS = Foundation UIKit AVFoundation CoreMedia Photos

# make release DIAG=1: diagnostics build (HTTP endpoints on port 8790, see Debug/).
ifeq ($(DIAG),1)
BiliClean_FILES += $(wildcard Debug/*.m) Debug/BLCDiagTrampolines.S
BiliClean_CFLAGS += -DBLC_DIAG=1
BLC_RELEASE_SUFFIX := -diag
endif

include $(THEOS_MAKE_PATH)/tweak.mk

BLC_RELEASE_VERSION := $(shell awk '/^Version:/ {print $$2}' control)
BLC_RELEASE_FILE := BiliClean_$(BLC_RELEASE_VERSION)$(BLC_RELEASE_SUFFIX).dylib

.PHONY: release
release: package
	mkdir -p dist
	lipo .theos/_/Library/MobileSubstrate/DynamicLibraries/BiliClean.dylib -thin arm64 -output dist/$(BLC_RELEASE_FILE)
	codesign --force --sign - dist/$(BLC_RELEASE_FILE)
	codesign --verify --all-architectures dist/$(BLC_RELEASE_FILE)
	cd dist && shasum -a 256 $(BLC_RELEASE_FILE) > $(BLC_RELEASE_FILE).sha256
