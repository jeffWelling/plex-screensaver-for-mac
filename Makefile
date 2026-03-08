SCHEME = PlexSaver
CONFIG = Release
PBXPROJ = PlexSaver.xcodeproj/project.pbxproj
SAVER_DIR = $(HOME)/Library/Screen Savers
DERIVED_DATA = $(HOME)/Library/Developer/Xcode/DerivedData

# Extract version from pbxproj (first match)
VERSION := $(shell grep '^\s*MARKETING_VERSION = ' $(PBXPROJ) | head -1 | sed 's/.*= //;s/;//')
BUILD := $(shell grep '^\s*CURRENT_PROJECT_VERSION = ' $(PBXPROJ) | head -1 | sed 's/.*= //;s/;//')
BUNDLE_NAME = PlexSaver_v$(VERSION).saver

.PHONY: build clean install uninstall version bump-patch bump-minor bump-major test

build: clean
	xcodebuild -scheme $(SCHEME) -configuration $(CONFIG) build

clean:
	xcodebuild -scheme $(SCHEME) -configuration $(CONFIG) clean 2>/dev/null || true
	@# Also nuke DerivedData for this project to avoid stale binaries
	rm -rf "$(DERIVED_DATA)"/PlexSaver-*/

install: build
	@# Remove any existing PlexSaver*.saver bundles
	rm -rf "$(SAVER_DIR)"/PlexSaver*.saver
	@# Find the built .saver and copy with versioned name
	$(eval BUILD_DIR := $(shell find "$(DERIVED_DATA)" -path "*/Build/Products/$(CONFIG)/PlexSaver.saver" -maxdepth 5 2>/dev/null | head -1))
	@if [ -z "$(BUILD_DIR)" ]; then echo "ERROR: Built .saver not found"; exit 1; fi
	cp -R "$(BUILD_DIR)" "$(SAVER_DIR)/$(BUNDLE_NAME)"
	@echo ""
	@echo "Installed: $(BUNDLE_NAME)"
	@echo "Version:   $(VERSION) (build $(BUILD))"
	@echo ""
	@echo "Restart System Settings or log out/in to load the new binary."

uninstall:
	rm -rf "$(SAVER_DIR)"/PlexSaver*.saver
	@echo "Removed all PlexSaver screensaver bundles."

version:
	@echo "Source:    $(VERSION) (build $(BUILD))"
	@INSTALLED=$$(ls -d "$(SAVER_DIR)"/PlexSaver*.saver 2>/dev/null | head -1); \
	if [ -n "$$INSTALLED" ]; then \
		IVERSION=$$(defaults read "$$INSTALLED/Contents/Info" CFBundleShortVersionString 2>/dev/null || echo "?"); \
		IBUILD=$$(defaults read "$$INSTALLED/Contents/Info" CFBundleVersion 2>/dev/null || echo "?"); \
		echo "Installed: $$IVERSION (build $$IBUILD) — $$(basename "$$INSTALLED")"; \
	else \
		echo "Installed: (none)"; \
	fi

bump-patch:
	@NEW=$$(echo $(VERSION) | awk -F. '{printf "%d.%d.%d", $$1, $$2, $$3+1}'); \
	sed -i '' "s/MARKETING_VERSION = $(VERSION)/MARKETING_VERSION = $$NEW/g" $(PBXPROJ); \
	NEWBUILD=$$(($(BUILD) + 1)); \
	sed -i '' "s/CURRENT_PROJECT_VERSION = $(BUILD)/CURRENT_PROJECT_VERSION = $$NEWBUILD/g" $(PBXPROJ); \
	echo "Bumped: $(VERSION) ($(BUILD)) -> $$NEW ($$NEWBUILD)"

bump-minor:
	@NEW=$$(echo $(VERSION) | awk -F. '{printf "%d.%d.%d", $$1, $$2+1, 0}'); \
	sed -i '' "s/MARKETING_VERSION = $(VERSION)/MARKETING_VERSION = $$NEW/g" $(PBXPROJ); \
	NEWBUILD=$$(($(BUILD) + 1)); \
	sed -i '' "s/CURRENT_PROJECT_VERSION = $(BUILD)/CURRENT_PROJECT_VERSION = $$NEWBUILD/g" $(PBXPROJ); \
	echo "Bumped: $(VERSION) ($(BUILD)) -> $$NEW ($$NEWBUILD)"

bump-major:
	@NEW=$$(echo $(VERSION) | awk -F. '{printf "%d.%d.%d", $$1+1, 0, 0}'); \
	sed -i '' "s/MARKETING_VERSION = $(VERSION)/MARKETING_VERSION = $$NEW/g" $(PBXPROJ); \
	NEWBUILD=$$(($(BUILD) + 1)); \
	sed -i '' "s/CURRENT_PROJECT_VERSION = $(BUILD)/CURRENT_PROJECT_VERSION = $$NEWBUILD/g" $(PBXPROJ); \
	echo "Bumped: $(VERSION) ($(BUILD)) -> $$NEW ($$NEWBUILD)"

test:
	xcodebuild -scheme SaverTest -configuration Debug build
	@echo ""
	@echo "SaverTest built. Open in Xcode to run, or:"
	@echo "  open $$(find '$(DERIVED_DATA)' -path '*/Build/Products/Debug/SaverTest.app' -maxdepth 5 2>/dev/null | head -1)"
