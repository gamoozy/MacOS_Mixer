SCHEME      := MacOsMixer
PROJECT     := MacOsMixer.xcodeproj
BUILD_DIR   := build
APP_NAME    := MacOs Mixer.app
INSTALL_DIR := /Applications
INSTALLED   := $(INSTALL_DIR)/MacOsMixer.app

.PHONY: setup generate build install run clean uninstall help

# ─── Default target ───────────────────────────────────────────────────────────
all: install

# ─── Install dependencies ─────────────────────────────────────────────────────
setup:
	@command -v brew >/dev/null 2>&1 || \
		(/bin/bash -c "$$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)")
	@command -v xcodegen >/dev/null 2>&1 || brew install xcodegen
	@echo "✔ Dependencies OK"

# ─── Regenerate the Xcode project from project.yml ───────────────────────────
generate: setup
	xcodegen generate --spec project.yml --project .

# ─── Build Release binary ─────────────────────────────────────────────────────
build: generate
	xcodebuild \
		-project $(PROJECT) \
		-scheme  $(SCHEME) \
		-configuration Release \
		-derivedDataPath $(BUILD_DIR) \
		ONLY_ACTIVE_ARCH=NO \
		CODE_SIGN_IDENTITY=- \
		CODE_SIGNING_REQUIRED=NO \
		CODE_SIGNING_ALLOWED=NO

# ─── Build + copy to /Applications ───────────────────────────────────────────
install: build
	rm -rf "$(INSTALLED)"
	cp -R "$(BUILD_DIR)/Build/Products/Release/$(APP_NAME)" "$(INSTALLED)"
	xattr -cr "$(INSTALLED)" 2>/dev/null || true
	@echo "✔ Installed at $(INSTALLED)"

# ─── Build + install + launch ─────────────────────────────────────────────────
run: install
	open "$(INSTALLED)"

# ─── Remove build artefacts ───────────────────────────────────────────────────
clean:
	rm -rf $(BUILD_DIR)
	@echo "✔ Build directory removed"

# ─── Remove the installed app ─────────────────────────────────────────────────
uninstall:
	@pkill -f "MacOs Mixer" 2>/dev/null || true
	rm -rf "$(INSTALLED)"
	@echo "✔ MacOs Mixer uninstalled"

# ─── Help ─────────────────────────────────────────────────────────────────────
help:
	@echo ""
	@echo "  make            — build and install to /Applications (same as 'make install')"
	@echo "  make run        — install and launch immediately"
	@echo "  make build      — build Release binary without installing"
	@echo "  make generate   — regenerate MacOsMixer.xcodeproj from project.yml"
	@echo "  make setup      — install Homebrew + XcodeGen if missing"
	@echo "  make clean      — delete build/ directory"
	@echo "  make uninstall  — quit and remove /Applications/MacOsMixer.app"
	@echo ""
