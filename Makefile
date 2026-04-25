APP_NAME = VoiceInput
BUNDLE_ID = com.voiceinput.app
BUILD_DIR = .build
RELEASE_DIR = $(BUILD_DIR)/release
APP_BUNDLE = $(APP_NAME).app
APP_CONTENTS = $(APP_BUNDLE)/Contents
APP_MACOS = $(APP_CONTENTS)/MacOS
APP_RESOURCES = $(APP_CONTENTS)/Resources

.PHONY: build run install clean

build:
	@echo "Building $(APP_NAME)..."
	swift build -c release
	@echo "Creating app bundle..."
	rm -rf $(APP_BUNDLE)
	mkdir -p $(APP_MACOS)
	mkdir -p $(APP_RESOURCES)
	cp $(RELEASE_DIR)/$(APP_NAME) $(APP_MACOS)/$(APP_NAME)
	cp Info.plist $(APP_CONTENTS)/Info.plist
	cp VoiceInput.entitlements $(APP_RESOURCES)/VoiceInput.entitlements || true
	@echo "Signing app bundle..."
	codesign --force --deep --sign - \
		--entitlements VoiceInput.entitlements \
		$(APP_BUNDLE)
	@echo "Build complete: $(APP_BUNDLE)"

run: build
	open $(APP_BUNDLE)

install: build
	@echo "Installing to /Applications..."
	cp -R $(APP_BUNDLE) /Applications/
	@echo "Installed to /Applications/$(APP_BUNDLE)"

clean:
	rm -rf $(BUILD_DIR)
	rm -rf $(APP_BUNDLE)
	@echo "Cleaned build artifacts."
