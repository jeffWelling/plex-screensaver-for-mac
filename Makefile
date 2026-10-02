SCHEME ?= PlexSaver
CONFIG ?= Release
BUILD_ROOT ?= $(CURDIR)/build/xcode
SAVER_DIR ?= $(HOME)/Library/Screen Savers
OPTIONS_DIR ?= $(HOME)/Applications
BUILT_SAVER = $(BUILD_ROOT)/Build/Products/$(CONFIG)/PlexSaver.saver
BUILT_OPTIONS = $(BUILD_ROOT)/Build/Products/$(CONFIG)/Montage Options.app
CODE_SIGNING_ALLOWED ?= NO

VERSION := $(shell sed -n 's/^MARKETING_VERSION = //p' Version.xcconfig)
SAVER_NAME = Montage v$(VERSION).saver
BUILD := $(shell sed -n 's/^CURRENT_PROJECT_VERSION = //p' Version.xcconfig)

.PHONY: build build-options clean install uninstall version bump-patch bump-minor bump-major test validate archive release

# Incremental, isolated build output; never searches or deletes global DerivedData.
build:
	xcodebuild -project PlexSaver.xcodeproj -scheme "$(SCHEME)" -configuration "$(CONFIG)" -derivedDataPath "$(BUILD_ROOT)" ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO CODE_SIGNING_ALLOWED=$(CODE_SIGNING_ALLOWED) build

build-options: | build
	xcodebuild -project PlexSaver.xcodeproj -scheme MontageOptions -configuration "$(CONFIG)" -derivedDataPath "$(BUILD_ROOT)" ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO CODE_SIGNING_ALLOWED=$(CODE_SIGNING_ALLOWED) build

clean:
	xcodebuild -project PlexSaver.xcodeproj -scheme "$(SCHEME)" -configuration "$(CONFIG)" -derivedDataPath "$(BUILD_ROOT)" clean

validate: override SCHEME = PlexSaver
validate: | build build-options
	python3 scripts/install.py --source "$(BUILT_SAVER)" --destination "$(SAVER_DIR)" --options-source "$(BUILT_OPTIONS)" --options-destination "$(OPTIONS_DIR)" --check-only

install: override SCHEME = PlexSaver
install: build build-options
	python3 scripts/install.py --source "$(BUILT_SAVER)" --destination "$(SAVER_DIR)" --options-source "$(BUILT_OPTIONS)" --options-destination "$(OPTIONS_DIR)"

uninstall:
	python3 scripts/install.py --destination "$(SAVER_DIR)" --options-destination "$(OPTIONS_DIR)" --uninstall

version:
	@echo "Source: $(VERSION) (build $(BUILD))"
	@python3 scripts/install.py --destination "$(SAVER_DIR)" --options-destination "$(OPTIONS_DIR)" --version

bump-patch bump-minor bump-major:
	python3 scripts/bump-version.py "$(@:bump-%=%)"

test:
	python3 -B -m unittest discover -s scripts/tests
	swift test -Xswiftc -strict-concurrency=complete

archive: override SCHEME = PlexSaver
archive: build validate
	python3 -c 'import plistlib, sys; expected = tuple(sys.argv[1:3]); actual = [(str(info.get("CFBundleShortVersionString", "")), str(info.get("CFBundleVersion", ""))) for info in [plistlib.load(open(path + "/Contents/Info.plist", "rb")) for path in sys.argv[3:]]]; sys.exit("Archive bundle versions do not match Version.xcconfig") if any(version != expected for version in actual) else None' "$(VERSION)" "$(BUILD)" "$(BUILT_SAVER)" "$(BUILT_OPTIONS)"
	mkdir -p build/release
	@set -eu; STAGING=$$(mktemp -d "$(CURDIR)/build/release/.archive-XXXXXX"); \
	trap 'rm -rf "$$STAGING"' EXIT HUP INT TERM; \
	ditto "$(BUILT_SAVER)" "$$STAGING/$(SAVER_NAME)" && \
	ditto "$(BUILT_OPTIONS)" "$$STAGING/Montage Options.app" && \
	ditto -c -k --sequesterRsrc --keepParent "$$STAGING/$(SAVER_NAME)" "$$STAGING/Montage.saver.zip" && \
	ditto -c -k --sequesterRsrc --keepParent "$$STAGING/Montage Options.app" "$$STAGING/Montage.Options.zip" && \
	test ! -L "$(CURDIR)/build/release/Montage.saver.zip" && \
	test ! -L "$(CURDIR)/build/release/Montage.Options.zip" && \
	mv -f "$$STAGING/Montage.saver.zip" "$(CURDIR)/build/release/Montage.saver.zip" && \
	mv -f "$$STAGING/Montage.Options.zip" "$(CURDIR)/build/release/Montage.Options.zip"

# Signing and notarization need an explicitly supplied identity/profile.
release:
	bash scripts/release.sh --notarize
