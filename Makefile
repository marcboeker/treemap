# Native macOS app. Signing settings come from .env (see .env.example).
# SIGN=0 builds the app without code signing (used by CI).

SHELL := /bin/bash

-include .env
BUNDLE_ID         ?= one.m8n.treemap
CODESIGN_IDENTITY ?= -
export BUNDLE_ID CODESIGN_IDENTITY

APP_PROJECT := App/Treemap.xcodeproj
APP_BUNDLE  := build/Treemap.app
DMG         := build/Treemap.dmg
ARGS        ?=
SIGN        ?= 1
# Extra xcodebuild build settings, e.g. OTHER_CODE_SIGN_FLAGS=--timestamp.
XCODEBUILD_SETTINGS ?=

ifeq ($(SIGN),0)
SIGN_SETTINGS := CODE_SIGNING_ALLOWED=NO
else
SIGN_SETTINGS := CODE_SIGN_IDENTITY="$(CODESIGN_IDENTITY)"
endif

# Disk image with the app and an /Applications link.
define make_dmg
rm -rf build/dmg $(DMG)
mkdir -p build/dmg
cp -R $(APP_BUNDLE) build/dmg/
ln -s /Applications build/dmg/Applications
hdiutil create -volname Treemap -srcfolder build/dmg -ov -format UDZO $(DMG)
rm -rf build/dmg
endef

.PHONY: all app run test project dmg notarize check-notary install icon clean

all: app

test:
	swift test

project:
	cd App && xcodegen generate --quiet

app: project
	@xcodebuild -quiet -project $(APP_PROJECT) -scheme Treemap -configuration Release \
		-destination 'generic/platform=macOS' \
		-derivedDataPath build/DerivedData \
		CONFIGURATION_BUILD_DIR="$(CURDIR)/build" \
		$(SIGN_SETTINGS) $(XCODEBUILD_SETTINGS) build
	@echo "built $(APP_BUNDLE)"

run: app
	open $(APP_BUNDLE) $(if $(ARGS),--args $(ARGS),)

# Regenerates the app icon artwork (the PNGs are committed).
icon:
	swift run make-icon App/Resources/Assets.xcassets/AppIcon.appiconset

dmg: app
	$(make_dmg)
	@echo "built $(DMG)"

check-notary:
	@test -n "$(NOTARY_IDENTITY)" || { echo "error: NOTARY_IDENTITY is not set. Put a Developer ID Application identity in .env (see .env.example)."; exit 1; }
	@test -n "$(NOTARY_PROFILE)" || { echo "error: NOTARY_PROFILE is not set. Create one with 'xcrun notarytool store-credentials' and put its name in .env."; exit 1; }

# Developer ID signing, notarization and stapling. Needs NOTARY_IDENTITY (Developer ID
# Application certificate) and NOTARY_PROFILE (notarytool keychain profile) in .env.
# Hardened runtime and entitlements come from App/project.yml.
notarize: check-notary
	@$(MAKE) --no-print-directory app CODESIGN_IDENTITY="$(NOTARY_IDENTITY)" \
		XCODEBUILD_SETTINGS=OTHER_CODE_SIGN_FLAGS=--timestamp
	codesign --verify --strict --verbose=2 $(APP_BUNDLE)
	$(make_dmg)
	codesign --force --timestamp --sign "$(NOTARY_IDENTITY)" $(DMG)
	xcrun notarytool submit $(DMG) --keychain-profile "$(NOTARY_PROFILE)" --wait
	xcrun stapler staple $(DMG)
	xcrun stapler staple $(APP_BUNDLE)
	@echo "notarized $(DMG)"

install: app
	rm -rf /Applications/Treemap.app
	cp -R $(APP_BUNDLE) /Applications/Treemap.app

clean:
	rm -rf build .build $(APP_PROJECT)
