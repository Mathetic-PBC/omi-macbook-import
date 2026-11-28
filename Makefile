# Signing with a real identity keeps the keychain items and the Local Network
# permission across rebuilds. With none on the machine the build is ad-hoc
# signed, and macOS asks again after each install.
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

# The phone app is signed by Xcode for a team: the one the signing
# certificate on this machine belongs to, unless TEAM says another.
TEAM ?= $(shell security find-certificate -c "Apple Development" -p 2>/dev/null | openssl x509 -noout -subject -nameopt multiline 2>/dev/null | awk -F'= ' '/organizationalUnitName/ {print $$2; exit}')
PHONE := xcodebuild -project OmiImport.xcodeproj -scheme OmiRelay -derivedDataPath $(BUILD) -quiet
PHONE_APP := $(BUILD)/Build/Products/Release-iphoneos/OmiRelay.app
ARCHIVE := $(BUILD)/OmiRelay.xcarchive

.PHONY: project build debug test install uninstall clean phone phone-install testflight

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

# Compiles the phone app for an iPhone without signing it: a check, not
# something to install.
phone: project
	$(PHONE) -configuration Debug -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build

# Onto an iPhone that is plugged in or on this network. DEVICE is its name or
# identifier, from `xcrun devicectl list devices`. The first signed build
# registers the app's identifier with the Apple developer team.
phone-install: project
	$(PHONE) -configuration Release -destination 'generic/platform=iOS' DEVELOPMENT_TEAM=$(TEAM) -allowProvisioningUpdates build
	xcrun devicectl device install app --device "$(DEVICE)" "$(PHONE_APP)"

# Archives the phone app and uploads it to App Store Connect for TestFlight.
# The app must already exist there, with the identifier com.mathetic.OmiRelay.
testflight: project
	$(PHONE) -configuration Release -destination 'generic/platform=iOS' -archivePath $(ARCHIVE) DEVELOPMENT_TEAM=$(TEAM) -allowProvisioningUpdates archive
	xcodebuild -exportArchive -archivePath $(ARCHIVE) -exportOptionsPlist Phone/ExportOptions.plist -exportPath $(BUILD)/OmiRelay-export -allowProvisioningUpdates

uninstall:
	-pkill -x OmiImport
	rm -rf "$(DEST)"

clean:
	rm -rf $(BUILD) Core/.build OmiImport.xcodeproj
