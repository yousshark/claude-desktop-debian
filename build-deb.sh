#!/bin/bash
set -e

# --- Architecture Detection ---
echo "⚙️ Detecting system architecture..."
HOST_ARCH=$(dpkg --print-architecture)
echo "Detected host architecture: $HOST_ARCH"

if [ "$HOST_ARCH" = "amd64" ]; then
    CLAUDE_DOWNLOAD_URL="https://storage.googleapis.com/osprey-downloads-c02f6a0d-347c-492b-a752-3e0651722e97/nest-win-x64/Claude-Setup-x64.exe"
    ARCHITECTURE="amd64"
    CLAUDE_EXE_FILENAME="Claude-Setup-x64.exe"
    echo "Configured for amd64 build."
elif [ "$HOST_ARCH" = "arm64" ]; then
    CLAUDE_DOWNLOAD_URL="https://storage.googleapis.com/osprey-downloads-c02f6a0d-347c-492b-a752-3e0651722e97/nest-win-arm64/Claude-Setup-arm64.exe"
    ARCHITECTURE="arm64"
    CLAUDE_EXE_FILENAME="Claude-Setup-arm64.exe"
    echo "Configured for arm64 build."
else
    echo "❌ Unsupported architecture: $HOST_ARCH. This script currently supports amd64 and arm64."
    exit 1
fi
# --- End Architecture Detection ---


# Check for Debian-based system
if [ ! -f "/etc/debian_version" ]; then
    echo "❌ This script requires a Debian-based Linux distribution"
    exit 1
fi

# Check for root/sudo
IS_SUDO=false
if [ "$EUID" -eq 0 ]; then
    IS_SUDO=true
    # Check if running via sudo (and not directly as root)
    if [ -n "$SUDO_USER" ]; then
        ORIGINAL_USER="$SUDO_USER"
        ORIGINAL_HOME=$(eval echo ~$ORIGINAL_USER)
    else
        # Running directly as root, no original user context
        ORIGINAL_USER="root"
        ORIGINAL_HOME="/root"
    fi
else
    echo "Please run with sudo to install dependencies"
    exit 1
fi

# Preserve NVM path if running under sudo and NVM exists for the original user
if [ "$IS_SUDO" = true ] && [ "$ORIGINAL_USER" != "root" ] && [ -d "$ORIGINAL_HOME/.nvm" ]; then
    echo "Found NVM installation for user $ORIGINAL_USER, attempting to preserve npm/npx path..."
    # Source NVM script to set up NVM environment variables temporarily
    export NVM_DIR="$ORIGINAL_HOME/.nvm"
    [ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh" # This loads nvm

    # Find the path to the currently active or default Node version's bin directory
    # nvm_find_node_version might not be available, try finding the latest installed version
    NODE_BIN_PATH=$(find "$NVM_DIR/versions/node" -maxdepth 2 -type d -name 'bin' | sort -V | tail -n 1)

    if [ -n "$NODE_BIN_PATH" ] && [ -d "$NODE_BIN_PATH" ]; then
        echo "Adding $NODE_BIN_PATH to PATH"
        export PATH="$NODE_BIN_PATH:$PATH"
    else
        echo "Warning: Could not determine NVM Node bin path. npm/npx might not be found."
    fi
fi


# Print system information
echo "System Information:"
echo "Distribution: $(cat /etc/os-release | grep "PRETTY_NAME" | cut -d'"' -f2)"
echo "Debian version: $(cat /etc/debian_version)"
echo "Target Architecture: $ARCHITECTURE" # Display the target architecture

# --- Build Format Selection ---
# Function to display the menu
display_menu() {
    clear
    echo -e "\n\033[1;34m====== Select Build Format ======\033[0m"
    echo -e "\033[1;32m  [1] Debian Package (.deb)\033[0m"
    echo -e "\033[1;32m  [2] AppImage       (.AppImage)\033[0m"
    echo -e "\033[1;34m=================================\033[0m"
}

while true; do
    display_menu
    read -n 1 -p $'\nEnter choice (1 or 2, any other key to cancel): ' BUILD_FORMAT
    echo 

    case $BUILD_FORMAT in
        "1") echo -e "\033[1;36m✔ You selected Debian Package (.deb)\033[0m"; break ;;
        "2") echo -e "\033[1;36m✔ You selected AppImage (.AppImage)\033[0m"; exit 0 ;;
        *) echo -e "\033[1;31m✖ Cancelled.\033[0m"; exit 1 ;;
    esac
done
# --- End Build Format Selection ---


# Function to check if a command exists
check_command() {
    if ! command -v "$1" &> /dev/null; then
        echo "❌ $1 not found"
        return 1
    else
        echo "✓ $1 found"
        return 0
    fi
}

# Check and install dependencies
echo "Checking dependencies..."
DEPS_TO_INSTALL=""

# Check system package dependencies
# Note: dpkg-deb is now only needed by the sub-script, but checking here ensures it's available if needed later
# AppImage might need different dependencies (e.g., fuse, appimagetool) - adjust if implementing AppImage
for cmd in p7zip wget wrestool icotool convert npx dpkg-deb; do
    if ! check_command "$cmd"; then
        case "$cmd" in
            "p7zip")
                DEPS_TO_INSTALL="$DEPS_TO_INSTALL p7zip-full"
                ;;
            "wget")
                DEPS_TO_INSTALL="$DEPS_TO_INSTALL wget"
                ;;
            "wrestool"|"icotool")
                DEPS_TO_INSTALL="$DEPS_TO_INSTALL icoutils"
                ;;
            "convert")
                DEPS_TO_INSTALL="$DEPS_TO_INSTALL imagemagick"
                ;;
            "npx")
                DEPS_TO_INSTALL="$DEPS_TO_INSTALL nodejs npm"
                ;;
            "dpkg-deb")
                # Only add dpkg-dev if building a deb
                if [ "$BUILD_FORMAT" = "1" ]; then
                    DEPS_TO_INSTALL="$DEPS_TO_INSTALL dpkg-dev"
                fi
                ;;
        esac
    fi
done

# Install system dependencies if any
if [ ! -z "$DEPS_TO_INSTALL" ]; then
    echo "Installing system dependencies: $DEPS_TO_INSTALL"
    apt update
    apt install -y $DEPS_TO_INSTALL
    echo "System dependencies installed successfully"
fi

# Check for electron - first local, then global
LOCAL_ELECTRON="" # Initialize variable
# Check for local electron in node_modules
if [ -f "$(pwd)/node_modules/.bin/electron" ]; then
    echo "✓ local electron found in node_modules"
    LOCAL_ELECTRON="$(pwd)/node_modules/.bin/electron"
    export PATH="$(pwd)/node_modules/.bin:$PATH"
elif ! check_command "electron"; then
    echo "Installing electron via npm..."
    # Try local installation first
    if [ -f "package.json" ]; then
        echo "Found package.json, installing electron locally..."
        npm install --save-dev electron
        if [ -f "$(pwd)/node_modules/.bin/electron" ]; then
            echo "✓ Local electron installed successfully"
            LOCAL_ELECTRON="$(pwd)/node_modules/.bin/electron"
            export PATH="$(pwd)/node_modules/.bin:$PATH"
        else
            # Fall back to global installation if local fails
            echo "Local electron install failed or not possible, trying global..."
            npm install -g electron
            # Attempt to fix permissions if installed globally
            if check_command "electron"; then
                ELECTRON_PATH=$(command -v electron)
                echo "Attempting to fix permissions for global electron at $ELECTRON_PATH..."
                chmod -R a+rx "$(dirname "$ELECTRON_PATH")/../lib/node_modules/electron" || echo "Warning: Failed to chmod global electron installation directory. Permissions might be incorrect."
            fi
            if ! check_command "electron"; then
                echo "Failed to install electron globally. Please install it manually:"
                echo "npm install -g electron # or npm install --save-dev electron in project root"
                exit 1
            fi
            echo "Global electron installed successfully"
        fi
    else
        # No package.json, try global installation
        echo "No package.json found, trying global electron installation..."
        npm install -g electron
        # Attempt to fix permissions if installed globally
        if check_command "electron"; then
            ELECTRON_PATH=$(command -v electron)
            echo "Attempting to fix permissions for global electron at $ELECTRON_PATH..."
            chmod -R a+rx "$(dirname "$ELECTRON_PATH")/../lib/node_modules/electron" || echo "Warning: Failed to chmod global electron installation directory. Permissions might be incorrect."
        fi
        if ! check_command "electron"; then
            echo "Failed to install electron globally. Please install it manually:"
            echo "npm install -g electron"
            exit 1
        fi
        echo "Global electron installed successfully"
    fi
fi

PACKAGE_NAME="claude-desktop"
# ARCHITECTURE is set based on detection above
MAINTAINER="Claude Desktop Linux Maintainers"
DESCRIPTION="Claude Desktop for Linux"
# Create working directories
WORK_DIR="$(pwd)/build" # Top-level build directory
APP_STAGING_DIR="$WORK_DIR/electron-app" # Staging for app files before packaging

# Clean previous build
rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR"
mkdir -p "$APP_STAGING_DIR" # Create the app staging directory explicitly

# Install asar if needed
if ! npm list -g asar > /dev/null 2>&1; then
    echo "Installing asar package globally..."
    npm install -g asar
fi

# Download Claude Windows installer for the target architecture
echo "📥 Downloading Claude Desktop installer for $ARCHITECTURE..."
CLAUDE_EXE_PATH="$WORK_DIR/$CLAUDE_EXE_FILENAME" # Use the arch-specific filename
if ! wget -O "$CLAUDE_EXE_PATH" "$CLAUDE_DOWNLOAD_URL"; then
    echo "❌ Failed to download Claude Desktop installer from $CLAUDE_DOWNLOAD_URL"
    exit 1
fi
echo "✓ Download complete: $CLAUDE_EXE_FILENAME"

# Extract resources
echo "📦 Extracting resources from $CLAUDE_EXE_FILENAME..."
cd "$WORK_DIR"
if ! 7z x -y "$CLAUDE_EXE_PATH"; then # Use the arch-specific path
    echo "❌ Failed to extract installer"
    exit 1
fi

# Extract nupkg filename and version
# The nupkg name might differ slightly for arm64, adjust find pattern if needed
# Assuming it still starts with AnthropicClaude- for now
NUPKG_PATH=$(find . -name "AnthropicClaude-*.nupkg" | head -1)
if [ -z "$NUPKG_PATH" ]; then
    echo "❌ Could not find AnthropicClaude nupkg file in $WORK_DIR"
    exit 1
fi
echo "Found nupkg: $NUPKG_PATH"

# Extract version from the nupkg filename (using LC_ALL=C for locale compatibility)
# Assuming version format is consistent across architectures
VERSION=$(echo "$NUPKG_PATH" | LC_ALL=C grep -oP 'AnthropicClaude-\K[0-9]+\.[0-9]+\.[0-9]+(?=-full|-arm64-full)') # Adjusted regex slightly
if [ -z "$VERSION" ]; then
    echo "❌ Could not extract version from nupkg filename: $NUPKG_PATH"
    exit 1
fi
echo "✓ Detected Claude version: $VERSION"

if ! 7z x -y "$NUPKG_PATH"; then
    echo "❌ Failed to extract nupkg"
    exit 1
fi
echo "✓ Resources extracted"

# Extract and convert icons (needed by the packaging script later)
# Assuming claude.exe exists in the extracted structure for both archs
EXE_RELATIVE_PATH="lib/net45/claude.exe" # Check if this path is correct for arm64 too
if [ ! -f "$EXE_RELATIVE_PATH" ]; then
    echo "❌ Cannot find claude.exe at expected path: $EXE_RELATIVE_PATH"
    # Add alternative path check if needed for arm64
    # find . -name claude.exe # Uncomment to help debug if needed
    exit 1
fi
echo "🎨 Processing icons from $EXE_RELATIVE_PATH..."
if ! wrestool -x -t 14 "$EXE_RELATIVE_PATH" -o claude.ico; then
    echo "❌ Failed to extract icons from exe"
    exit 1
fi

if ! icotool -x claude.ico; then
    echo "❌ Failed to convert icons"
    exit 1
fi
echo "✓ Icons processed (will be used by packaging script)"

# Process app.asar
# Assuming app.asar structure is consistent across architectures
echo "⚙️ Processing app.asar..."
cp "lib/net45/resources/app.asar" "$APP_STAGING_DIR/"
cp -r "lib/net45/resources/app.asar.unpacked" "$APP_STAGING_DIR/"

cd "$APP_STAGING_DIR"
npx asar extract app.asar app.asar.contents

# Replace native module with stub implementation
echo "Creating stub native module..."
cat > app.asar.contents/node_modules/claude-native/index.js << EOF
// Stub implementation of claude-native using KeyboardKey enum values
const KeyboardKey = {
  Backspace: 43,
  Tab: 280,
  Enter: 261,
  Shift: 272,
  Control: 61,
  Alt: 40,
  CapsLock: 56,
  Escape: 85,
  Space: 276,
  PageUp: 251,
  PageDown: 250,
  End: 83,
  Home: 154,
  LeftArrow: 175,
  UpArrow: 282,
  RightArrow: 262,
  DownArrow: 81,
  Delete: 79,
  Meta: 187
};

Object.freeze(KeyboardKey);

module.exports = {
  getWindowsVersion: () => "10.0.0", // Keep this generic?
  setWindowEffect: () => {},
  removeWindowEffect: () => {},
  getIsMaximized: () => false,
  flashFrame: () => {},
  clearFlashFrame: () => {},
  showNotification: () => {},
  setProgressBar: () => {},
  clearProgressBar: () => {},
  setOverlayIcon: () => {},
  clearOverlayIcon: () => {},
  KeyboardKey
};
EOF

# Copy Tray icons
mkdir -p app.asar.contents/resources
mkdir -p app.asar.contents/resources/i18n

cp ../lib/net45/resources/Tray* app.asar.contents/resources/
# Copy only the language-specific JSON files (e.g., en-US.json)
cp ../lib/net45/resources/*-*.json app.asar.contents/resources/i18n/

echo "Downloading Main Window Fix Assets"
cd app.asar.contents
wget -O- https://github.com/emsi/claude-desktop/raw/refs/heads/main/assets/main_window.tgz | tar -zxvf -
cd ..

# Repackage app.asar
npx asar pack app.asar.contents app.asar

# Create native module stub within the staging area's unpacked directory
mkdir -p "$APP_STAGING_DIR/app.asar.unpacked/node_modules/claude-native"
cat > "$APP_STAGING_DIR/app.asar.unpacked/node_modules/claude-native/index.js" << EOF
// Stub implementation of claude-native using KeyboardKey enum values
const KeyboardKey = {
  Backspace: 43,
  Tab: 280,
  Enter: 261,
  Shift: 272,
  Control: 61,
  Alt: 40,
  CapsLock: 56,
  Escape: 85,
  Space: 276,
  PageUp: 251,
  PageDown: 250,
  End: 83,
  Home: 154,
  LeftArrow: 175,
  UpArrow: 282,
  RightArrow: 262,
  DownArrow: 81,
  Delete: 79,
  Meta: 187
};

Object.freeze(KeyboardKey);

module.exports = {
  getWindowsVersion: () => "10.0.0",
  setWindowEffect: () => {},
  removeWindowEffect: () => {},
  getIsMaximized: () => false,
  flashFrame: () => {},
  clearFlashFrame: () => {},
  showNotification: () => {},
  setProgressBar: () => {},
  clearProgressBar: () => {},
  setOverlayIcon: () => {},
  clearOverlayIcon: () => {},
  KeyboardKey
};
EOF

# Copy local electron if available
if [ ! -z "$LOCAL_ELECTRON" ]; then
    echo "Copying local electron to staging area..."
    # Ensure the target node_modules directory exists in staging
    mkdir -p "$APP_STAGING_DIR/node_modules"
    # Copy the entire electron module directory
    # Go up one level from the binary path to get the module root
    ELECTRON_MODULE_PATH=$(dirname "$LOCAL_ELECTRON")/..
    echo "Copying from $ELECTRON_MODULE_PATH to $APP_STAGING_DIR/node_modules/"
    cp -r "$ELECTRON_MODULE_PATH" "$APP_STAGING_DIR/node_modules/"
fi
echo "✓ app.asar processed and staged in $APP_STAGING_DIR"

# Return to the original directory (project root) before calling the packaging script
# We were in $APP_STAGING_DIR which is $WORK_DIR/electron-app
cd .. # Go back from build/electron-app to build/
cd .. # Go back from build/ to the project root

# --- Call the Debian Packaging Script ---
# This section only runs if BUILD_FORMAT was "1"
echo "📦 Calling Debian packaging script for $ARCHITECTURE..."
# Ensure the script is executable
chmod +x scripts/build-deb-package.sh

# Execute the script, passing necessary variables including the detected ARCHITECTURE
scripts/build-deb-package.sh \
    "$VERSION" \
    "$ARCHITECTURE" \
    "$WORK_DIR" \
    "$APP_STAGING_DIR" \
    "$PACKAGE_NAME" \
    "$MAINTAINER" \
    "$DESCRIPTION"

# Check the exit code of the packaging script
if [ $? -ne 0 ]; then
    echo "❌ Debian packaging script failed."
    exit 1
fi

# Capture the final deb file path (using the determined ARCHITECTURE)
# Find the .deb file in the work directory
DEB_FILE=$(find "$WORK_DIR" -maxdepth 1 -name "${PACKAGE_NAME}_${VERSION}_${ARCHITECTURE}.deb" | head -n 1)

echo "✓ Build complete!"
if [ -n "$DEB_FILE" ] && [ -f "$DEB_FILE" ]; then
    echo "Package created at: $DEB_FILE"
else
    echo "Warning: Could not determine final .deb file path from $WORK_DIR for ${ARCHITECTURE}."
fi

# Clean up intermediate files (optional, keep for debugging if needed)
# echo "🧹 Cleaning up intermediate files..."
# rm -rf "$WORK_DIR/lib" "$WORK_DIR/claude.ico" "$WORK_DIR"/*.png "$WORK_DIR/electron-app" "$WORK_DIR/package" "$WORK_DIR/RELEASES" "$WORK_DIR/Setup.exe" "$WORK_DIR/Setup.msi" "$WORK_DIR"/*.nupkg

exit 0
