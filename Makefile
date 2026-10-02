SCHEME ?= PlexSaver
CONFIG ?= Release
BUILD_ROOT ?= $(CURDIR)/build/xcode
SAVER_DIR ?= $(HOME)/Library/Screen Savers
BUILT_SAVER = $(BUILD_ROOT)/Build/Products/$(CONFIG)/PlexSaver.saver
CODE_SIGNING_ALLOWED ?= NO

VERSION := $(shell sed -n 's/^MARKETING_VERSION = //p' Version.xcconfig)
BUILD := $(shell sed -n 's/^CURRENT_PROJECT_VERSION = //p' Version.xcconfig)

.PHONY: build clean install uninstall version bump-patch bump-minor bump-major test validate archive release

# Incremental, isolated build output; never searches or deletes global DerivedData.
build:
	xcodebuild -project PlexSaver.xcodeproj -scheme "$(SCHEME)" -configuration "$(CONFIG)" -derivedDataPath "$(BUILD_ROOT)" ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO CODE_SIGNING_ALLOWED=$(CODE_SIGNING_ALLOWED) build

clean:
	xcodebuild -project PlexSaver.xcodeproj -scheme "$(SCHEME)" -configuration "$(CONFIG)" -derivedDataPath "$(BUILD_ROOT)" clean

validate: override SCHEME = PlexSaver
validate: | build
	python3 scripts/install.py --source "$(BUILT_SAVER)" --destination "$(SAVER_DIR)" --check-only

install: override SCHEME = PlexSaver
install: build
	python3 scripts/install.py --source "$(BUILT_SAVER)" --destination "$(SAVER_DIR)"

uninstall:
	python3 scripts/install.py --destination "$(SAVER_DIR)" --uninstall

version:
	@echo "Source: $(VERSION) (build $(BUILD))"
	@python3 scripts/install.py --destination "$(SAVER_DIR)" --version

bump-patch bump-minor bump-major:
	python3 scripts/bump-version.py "$(@:bump-%=%)"

test:
	python3 -B -m unittest discover -s scripts/tests
	swift test -Xswiftc -strict-concurrency=complete

archive: override SCHEME = PlexSaver
archive: build validate
	mkdir -p build/release
	@set -eu; STAGING=$$(mktemp -d "$(CURDIR)/build/release/.archive-XXXXXX"); \
	trap 'rm -rf "$$STAGING"' EXIT HUP INT TERM; \
	ditto "$(BUILT_SAVER)" "$$STAGING/Montage.saver" && \
	ditto -c -k --sequesterRsrc --keepParent "$$STAGING/Montage.saver" "$$STAGING/Montage.saver.zip" && \
	mv -f "$$STAGING/Montage.saver.zip" "$(CURDIR)/build/release/Montage.saver.zip"

# Signing and notarization need an explicitly supplied identity/profile.
release:
	bash scripts/release.sh --notarize
