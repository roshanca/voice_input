APP_NAME = VoiceInput
BUNDLE_ID = com.voiceinput.app
BUILD_DIR = .build
RELEASE_DIR = $(BUILD_DIR)/release
APP_BUNDLE = $(APP_NAME).app
APP_CONTENTS = $(APP_BUNDLE)/Contents
APP_MACOS = $(APP_CONTENTS)/MacOS
APP_RESOURCES = $(APP_CONTENTS)/Resources
ICON_SOURCE = Assets/AppIcon.png
ICONSET_DIR = $(BUILD_DIR)/AppIcon.iconset
# Auto-stamped into the bundle's CFBundleVersion on every build.
BUILD_VERSION = $(shell date +%Y%m%d.%H%M)

.PHONY: build run install clean test

build:
	@echo "Building $(APP_NAME)..."
	swift build -c release
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
	@echo "Signing app bundle..."
	codesign --force --deep --sign "VoiceInput Dev" \
		--entitlements VoiceInput.entitlements \
		$(APP_BUNDLE)
	@echo "Build complete: $(APP_BUNDLE)"

run: build
	open $(APP_BUNDLE)

test:
	swift test

install: build
	@echo "Installing to /Applications..."
	cp -R $(APP_BUNDLE) /Applications/
	@echo "Installed to /Applications/$(APP_BUNDLE)"

clean:
	rm -rf $(BUILD_DIR)
	rm -rf $(APP_BUNDLE)
	@echo "Cleaned build artifacts."
