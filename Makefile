# Signing with a real identity keeps the Bluetooth permission across rebuilds.
# With none on the machine the build is ad-hoc signed, and macOS asks again
# after each install.
IDENTITY ?= $(shell security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Apple Development|Developer ID Application/ {print $$2; exit}')
ifeq ($(strip $(IDENTITY)),)
IDENTITY := -
endif

BUILD := build
APP := $(BUILD)/Build/Products/Release/OmiImport.app
DEBUG_APP := $(BUILD)/Build/Products/Debug/OmiImport.app
DEST := /Applications/OmiImport.app
XCODEBUILD := xcodebuild -project OmiImport.xcodeproj -scheme OmiImport -derivedDataPath $(BUILD) \
	CODE_SIGN_IDENTITY="$(IDENTITY)" -quiet
LSREGISTER := /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

.PHONY: project build debug test install uninstall clean

project:
	xcodegen generate --quiet

build: project
	$(XCODEBUILD) -configuration Release build

debug: project
	$(XCODEBUILD) -configuration Debug build

test:
	cd Core && swift test

# The release product is unregistered once installed, so macOS never starts
# the build-folder copy in place of the one in /Applications.
install: build
	-pkill -x OmiImport
	rm -rf "$(DEST)"
	ditto "$(APP)" "$(DEST)"
	-perl -e 'alarm 10; exec @ARGV' $(LSREGISTER) -u "$(CURDIR)/$(APP)" 2>/dev/null
	rm -rf "$(APP)"
	open "$(DEST)"

uninstall:
	-pkill -x OmiImport
	rm -rf "$(DEST)"

clean:
	rm -rf $(BUILD) Core/.build OmiImport.xcodeproj
