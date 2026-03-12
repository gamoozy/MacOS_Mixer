#!/usr/bin/env bash
# MacOs Mixer — one-command installer
# Usage (from the repo directory):   ./install.sh
# Usage (fresh machine via curl):    bash <(curl -fsSL https://raw.githubusercontent.com/gamoozy/MacOS_Mixer/main/install.sh)
set -euo pipefail

REPO_URL="https://github.com/gamoozy/MacOS_Mixer.git"
APP_BUNDLE="MacOs Mixer.app"
INSTALL_DIR="/Applications"
INSTALLED_APP="$INSTALL_DIR/MacOsMixer.app"
MIN_MACOS_MAJOR=14
MIN_MACOS_MINOR=2

# ─── Colours ─────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info()    { echo -e "${CYAN}▶ $*${NC}"; }
success() { echo -e "${GREEN}✔ $*${NC}"; }
warn()    { echo -e "${YELLOW}⚠ $*${NC}"; }
error()   { echo -e "${RED}✖ $*${NC}"; exit 1; }

echo ""
echo -e "${CYAN}╔══════════════════════════════════════╗${NC}"
echo -e "${CYAN}║        MacOs Mixer — Installer       ║${NC}"
echo -e "${CYAN}╚══════════════════════════════════════╝${NC}"
echo ""

# ─── 1. macOS version check ───────────────────────────────────────────────────
info "Checking macOS version…"
OS_VER=$(sw_vers -productVersion)
MAJOR=$(echo "$OS_VER" | cut -d. -f1)
MINOR=$(echo "$OS_VER" | cut -d. -f2)
if [[ $MAJOR -lt $MIN_MACOS_MAJOR ]] || { [[ $MAJOR -eq $MIN_MACOS_MAJOR ]] && [[ $MINOR -lt $MIN_MACOS_MINOR ]]; }; then
    error "macOS $MIN_MACOS_MAJOR.$MIN_MACOS_MINOR or later required (you have $OS_VER). The CoreAudio Tap API used by this app was introduced in macOS 14.2."
fi
success "macOS $OS_VER — OK"

# ─── 2. Xcode check ──────────────────────────────────────────────────────────
info "Checking for Xcode…"
if ! xcodebuild -version &>/dev/null; then
    warn "Xcode not found. Opening App Store…"
    open "https://apps.apple.com/app/xcode/id497799835"
    error "Install Xcode from the App Store, launch it once to accept the licence, then re-run this script."
fi
XCODE_VER=$(xcodebuild -version | head -1 | awk '{print $2}')
success "Xcode $XCODE_VER — OK"

# Accept Xcode licence silently if not yet accepted
sudo xcodebuild -license accept 2>/dev/null || true

# ─── 3. Homebrew check ───────────────────────────────────────────────────────
info "Checking for Homebrew…"
if ! command -v brew &>/dev/null; then
    info "Installing Homebrew…"
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
    # Add brew to PATH for Apple Silicon
    if [[ -f /opt/homebrew/bin/brew ]]; then
        eval "$(/opt/homebrew/bin/brew shellenv)"
    fi
fi
success "Homebrew $(brew --version | head -1) — OK"

# ─── 4. XcodeGen check ───────────────────────────────────────────────────────
info "Checking for XcodeGen…"
if ! command -v xcodegen &>/dev/null; then
    info "Installing XcodeGen…"
    brew install xcodegen
fi
success "XcodeGen $(xcodegen --version 2>/dev/null | head -1) — OK"

# ─── 5. Source code ──────────────────────────────────────────────────────────
# Detect whether we're already inside the cloned repo.
if [[ -f "project.yml" && -d "MacOsMixer" ]]; then
    REPO_DIR="$(pwd)"
    info "Using existing repo at $REPO_DIR"
else
    REPO_DIR="$HOME/MacOs_Mixer"
    if [[ -d "$REPO_DIR/.git" ]]; then
        info "Updating existing clone at $REPO_DIR…"
        git -C "$REPO_DIR" pull --ff-only
    else
        info "Cloning repository to $REPO_DIR…"
        git clone "$REPO_URL" "$REPO_DIR"
    fi
    cd "$REPO_DIR"
fi

# ─── 6. Generate Xcode project ───────────────────────────────────────────────
info "Generating Xcode project…"
xcodegen generate --spec project.yml --project . --quiet
success "Xcode project generated"

# ─── 7. Build ────────────────────────────────────────────────────────────────
info "Building MacOs Mixer (Release)… this may take a minute"
xcodebuild \
    -project MacOsMixer.xcodeproj \
    -scheme MacOsMixer \
    -configuration Release \
    -derivedDataPath build \
    ONLY_ACTIVE_ARCH=NO \
    CODE_SIGN_IDENTITY=- \
    CODE_SIGNING_REQUIRED=NO \
    CODE_SIGNING_ALLOWED=NO \
    2>&1 | grep -E "(error:|warning:|BUILD SUCCEEDED|BUILD FAILED)" || true

BUILT_APP="build/Build/Products/Release/$APP_BUNDLE"
if [[ ! -d "$BUILT_APP" ]]; then
    error "Build failed — run 'xcodebuild ... 2>&1 | cat' manually to see the full log."
fi
success "Build succeeded"

# ─── 8. Install to /Applications ────────────────────────────────────────────
info "Installing to $INSTALL_DIR…"
rm -rf "$INSTALLED_APP"
cp -R "$BUILT_APP" "$INSTALLED_APP"
# Remove quarantine attribute so Gatekeeper doesn't block the app.
xattr -cr "$INSTALLED_APP" 2>/dev/null || true
success "Installed at $INSTALLED_APP"

# ─── 9. Launch ───────────────────────────────────────────────────────────────
info "Launching MacOs Mixer…"
open "$INSTALLED_APP"

echo ""
success "Done! MacOs Mixer is running in your menu bar (🎚 slider icon)."
echo ""
echo -e "  ${YELLOW}First launch:${NC} macOS will ask for microphone permission — allow it."
echo -e "  ${YELLOW}Login item:${NC}   The app auto-registers to launch at login on first run."
echo -e "  ${YELLOW}Uninstall:${NC}    run  ${CYAN}make uninstall${NC}  or delete /Applications/MacOsMixer.app"
echo ""
