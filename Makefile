APP_NAME = VoiceInput
BUNDLE_ID = com.voiceinput.app
BUILD_DIR = .build
RELEASE_DIR = $(BUILD_DIR)/release
APP_BUNDLE = $(APP_NAME).app
APP_CONTENTS = $(APP_BUNDLE)/Contents
APP_MACOS = $(APP_CONTENTS)/MacOS
APP_RESOURCES = $(APP_CONTENTS)/Resources
APP_FRAMEWORKS = $(APP_CONTENTS)/Frameworks
ICON_SOURCE = Assets/AppIcon.png
ICONSET_DIR = $(BUILD_DIR)/AppIcon.iconset
# Auto-stamped into the bundle's CFBundleVersion on every build.
BUILD_VERSION = $(shell date +%Y%m%d.%H%M)
DMG_PATH = $(APP_NAME).dmg

# Shared signing defaults, overridable per-machine (see docs/Release.md).
include Config/Signing.shared.mk
-include Config/Signing.local.mk

.PHONY: build run install clean test dmg

build:
	@echo "Building $(APP_NAME)..."
	swift build -c release -Xlinker -rpath -Xlinker @executable_path/../Frameworks
	@echo "Creating app bundle..."
	rm -rf $(APP_BUNDLE)
	mkdir -p $(APP_MACOS)
	mkdir -p $(APP_RESOURCES)
	cp $(RELEASE_DIR)/$(APP_NAME) $(APP_MACOS)/$(APP_NAME)
	cp Info.plist $(APP_CONTENTS)/Info.plist
	/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $(BUILD_VERSION)" $(APP_CONTENTS)/Info.plist
	@echo "Version: $$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' $(APP_CONTENTS)/Info.plist) ($(BUILD_VERSION))"
	cp VoiceInput.entitlements $(APP_RESOURCES)/VoiceInput.entitlements || true
	@echo "Generating app icon..."
	mkdir -p $(ICONSET_DIR)
	sips -z 16 16     $(ICON_SOURCE) --out $(ICONSET_DIR)/icon_16x16.png
	sips -z 32 32     $(ICON_SOURCE) --out $(ICONSET_DIR)/icon_16x16@2x.png
	sips -z 32 32     $(ICON_SOURCE) --out $(ICONSET_DIR)/icon_32x32.png
	sips -z 64 64     $(ICON_SOURCE) --out $(ICONSET_DIR)/icon_32x32@2x.png
	sips -z 128 128   $(ICON_SOURCE) --out $(ICONSET_DIR)/icon_128x128.png
	sips -z 256 256   $(ICON_SOURCE) --out $(ICONSET_DIR)/icon_128x128@2x.png
	sips -z 256 256   $(ICON_SOURCE) --out $(ICONSET_DIR)/icon_256x256.png
	sips -z 512 512   $(ICON_SOURCE) --out $(ICONSET_DIR)/icon_256x256@2x.png
	sips -z 512 512   $(ICON_SOURCE) --out $(ICONSET_DIR)/icon_512x512.png
	cp $(ICON_SOURCE) $(ICONSET_DIR)/icon_512x512@2x.png
	iconutil -c icns $(ICONSET_DIR) -o $(APP_RESOURCES)/AppIcon.icns
	@echo "Embedding Sparkle.framework..."
	@SPARKLE_FW=$$(find $(BUILD_DIR)/artifacts -type d -name "Sparkle.framework" -path "*macos-arm64*" | head -1); \
	if [ -n "$$SPARKLE_FW" ]; then \
		mkdir -p $(APP_FRAMEWORKS); \
		rm -rf $(APP_FRAMEWORKS)/Sparkle.framework; \
		ditto "$$SPARKLE_FW" $(APP_FRAMEWORKS)/Sparkle.framework; \
	else \
		echo "Warning: Sparkle.framework not found under $(BUILD_DIR)/artifacts — bundle will lack updater support"; \
	fi
	@echo "Signing app bundle..."
	codesign --force --deep --sign "$(CODESIGN_IDENTITY)" \
		--entitlements $(CODESIGN_ENTITLEMENTS) \
		$(APP_BUNDLE)
	@echo "Build complete: $(APP_BUNDLE)"

test:
	# The products-dir rpath lets the test bundle find the copied
	# Sparkle.framework — SwiftPM doesn't add it for executable deps.
	swift test -Xlinker -rpath -Xlinker $(shell swift build --show-bin-path)

dmg: build
	tools/build_dmg.sh $(APP_BUNDLE) $(DMG_PATH)

run: build
	open $(APP_BUNDLE)

install: build
	@echo "Installing to /Applications..."
	cp -R $(APP_BUNDLE) /Applications/
	@echo "Installed to /Applications/$(APP_BUNDLE)"

clean:
	rm -rf $(BUILD_DIR)
	rm -rf $(APP_BUNDLE)
	rm -f $(DMG_PATH)
	@echo "Cleaned build artifacts."
