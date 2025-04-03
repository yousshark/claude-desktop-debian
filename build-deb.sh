#!/bin/bash
set -e

# --- Architecture Detection ---
echo -e "\033[1;36m--- Architecture Detection ---\033[0m"
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
echo -e "\033[1;36m--- End Architecture Detection ---\033[0m"


# Check for Debian-based system
if [ ! -f "/etc/debian_version" ]; then
    echo "❌ This script requires a Debian-based Linux distribution"
    exit 1
fi

# Check for root/sudo
IS_SUDO=false
ORIGINAL_USER=""
ORIGINAL_HOME=""
if [ "$EUID" -eq 0 ]; then
    IS_SUDO=true
    # Check if running via sudo (and not directly as root)
    if [ -n "$SUDO_USER" ]; then
        ORIGINAL_USER="$SUDO_USER"
        ORIGINAL_HOME=$(getent passwd "$SUDO_USER" | cut -d: -f6) # More reliable way to get home dir
        echo "Running with sudo as user: $ORIGINAL_USER (Home: $ORIGINAL_HOME)"
    else
        # Running directly as root, no original user context
        ORIGINAL_USER="root"
        ORIGINAL_HOME="/root"
        echo "Running directly as root."
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
    if [ -s "$NVM_DIR/nvm.sh" ]; then
        \. "$NVM_DIR/nvm.sh" # This loads nvm
        # Find the path to the currently active or default Node version's bin directory
        NODE_BIN_PATH=$(nvm which current | xargs dirname 2>/dev/null || find "$NVM_DIR/versions/node" -maxdepth 2 -type d -name 'bin' | sort -V | tail -n 1)

        if [ -n "$NODE_BIN_PATH" ] && [ -d "$NODE_BIN_PATH" ]; then
            echo "Adding $NODE_BIN_PATH to PATH"
            export PATH="$NODE_BIN_PATH:$PATH"
        else
            echo "Warning: Could not determine NVM Node bin path. npm/npx might not be found."
        fi
    else
        echo "Warning: nvm.sh script not found or not sourceable."
    fi
fi


# Print system information
echo "System Information:"
echo "Distribution: $(cat /etc/os-release | grep "PRETTY_NAME" | cut -d'"' -f2)"
echo "Debian version: $(cat /etc/debian_version)"
echo "Target Architecture: $ARCHITECTURE" # Display the target architecture

# Define common variables needed before the split
PACKAGE_NAME="claude-desktop"
MAINTAINER="Claude Desktop Linux Maintainers"
DESCRIPTION="Claude Desktop for Linux"
PROJECT_ROOT="$(pwd)" # Save project root
WORK_DIR="$PROJECT_ROOT/build" # Top-level build directory
APP_STAGING_DIR="$WORK_DIR/electron-app" # Staging for app files before packaging
VERSION="" # Will be determined after download

# --- Build Format Selection ---
echo -e "\033[1;36m--- Build Format Selection ---\033[0m"
# Function to display the menu
display_menu() {
    clear
    echo -e "\n\033[1;34m====== Select Build Format ======\033[0m"
    echo -e "\033[1;32m  [1] Debian Package (.deb)\033[0m"
    echo -e "\033[1;32m  [2] AppImage       (.AppImage)\033[0m"
    echo -e "\033[1;34m=================================\033[0m"
}

BUILD_FORMAT=""
while true; do
    display_menu
    read -n 1 -p $'\nEnter choice (1 or 2, any other key to cancel): ' BUILD_FORMAT_CHOICE
    echo

    case $BUILD_FORMAT_CHOICE in
        "1")
            echo -e "\033[1;36m✔ You selected Debian Package (.deb)\033[0m"
            BUILD_FORMAT="deb"
            break
            ;;
        "2")
            echo -e "\033[1;36m✔ You selected AppImage (.AppImage)\033[0m"
            BUILD_FORMAT="appimage"
            break
            ;;
        *)
            echo # Add newline for clarity
            echo -e "\033[1;31m✖ Cancelled.\033[0m"
            exit 1
            ;;
    esac
done
echo "-------------------------------------" # Add separator after selection/before next steps
# --- Cleanup Selection ---
echo -e "\033[1;36m--- Cleanup Selection ---\033[0m"
PERFORM_CLEANUP=false # Default to keeping files
display_cleanup_menu() {
    echo -e "\n\033[1;34m====== Cleanup Build Files ======\033[0m"
    echo -e "This refers to the intermediate files created in the '$WORK_DIR' directory."
    echo -e "\033[1;32m  [1] Yes, remove intermediate build files after completion\033[0m"
    echo -e "\033[1;32m  [2] No, keep intermediate build files\033[0m"
    echo -e "\033[1;34m=================================\033[0m"
}

CLEANUP_CHOICE=""
while true; do
    display_cleanup_menu
    read -n 1 -p $'\nEnter choice (1 or 2, any other key defaults to "No".): ' CLEANUP_CHOICE
    echo

    case $CLEANUP_CHOICE in
        "1")
            echo -e "\033[1;36m✔ Intermediate build files will be removed upon completion.\033[0m"
            PERFORM_CLEANUP=true
            break
            ;;
        "2")
            echo -e "\033[1;36m✔ Intermediate build files will be kept.\033[0m"
            PERFORM_CLEANUP=false
            break
            ;;
        *)
            echo # Add newline for clarity
            echo -e "\033[1;33m⚠ Skipping cleanup decision. Build files will be kept.\033[0m"
            PERFORM_CLEANUP=false # Default to keeping files
            break
            ;;
    esac
done
echo "-------------------------------------"
echo -e "\033[1;36m--- End Cleanup Selection ---\033[0m"


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

# Check and install dependencies (Common + Format Specific)
echo "Checking dependencies..."
DEPS_TO_INSTALL=""
# Common dependencies needed for extraction/staging
COMMON_DEPS="p7zip wget wrestool icotool convert npx"
# Format specific dependencies
DEB_DEPS="dpkg-dev"
APPIMAGE_DEPS="" # appimagetool handled by its script

ALL_DEPS_TO_CHECK="$COMMON_DEPS"
if [ "$BUILD_FORMAT" = "deb" ]; then
    ALL_DEPS_TO_CHECK="$ALL_DEPS_TO_CHECK $DEB_DEPS"
elif [ "$BUILD_FORMAT" = "appimage" ]; then
    ALL_DEPS_TO_CHECK="$ALL_DEPS_TO_CHECK $APPIMAGE_DEPS"
fi

for cmd in $ALL_DEPS_TO_CHECK; do
    if ! check_command "$cmd"; then
        case "$cmd" in
            "p7zip") DEPS_TO_INSTALL="$DEPS_TO_INSTALL p7zip-full" ;;
            "wget") DEPS_TO_INSTALL="$DEPS_TO_INSTALL wget" ;;
            "wrestool"|"icotool") DEPS_TO_INSTALL="$DEPS_TO_INSTALL icoutils" ;;
            "convert") DEPS_TO_INSTALL="$DEPS_TO_INSTALL imagemagick" ;;
            "npx") DEPS_TO_INSTALL="$DEPS_TO_INSTALL nodejs npm" ;;
            "dpkg-deb") DEPS_TO_INSTALL="$DEPS_TO_INSTALL dpkg-dev" ;;
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

# Clean previous build directory FIRST
rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR"
mkdir -p "$APP_STAGING_DIR" # Create the app staging directory explicitly

# --- Electron & Asar Handling ---
echo -e "\033[1;36m--- Electron & Asar Handling ---\033[0m"
CHOSEN_ELECTRON_MODULE_PATH="" # Path to the electron module directory to be copied
ASAR_EXEC="" # Path to the asar executable
TEMP_PACKAGE_JSON_CREATED=false

# Always ensure local Electron & Asar installation in WORK_DIR
echo "Ensuring local Electron and Asar installation in $WORK_DIR..."
cd "$WORK_DIR" # Change to build dir for local install

# Create dummy package.json if none exists in build dir
if [ ! -f "package.json" ]; then
    echo "Creating temporary package.json in $WORK_DIR for local install..."
    echo '{"name":"claude-desktop-build","version":"0.0.1","private":true}' > package.json
    TEMP_PACKAGE_JSON_CREATED=true
fi

# Install electron and asar locally if not already present
# Check for Electron dist dir and Asar binary first
ELECTRON_DIST_PATH="$WORK_DIR/node_modules/electron/dist"
ASAR_BIN_PATH="$WORK_DIR/node_modules/.bin/asar"

INSTALL_NEEDED=false
if [ ! -d "$ELECTRON_DIST_PATH" ]; then
    echo "Electron distribution not found."
    INSTALL_NEEDED=true
fi
if [ ! -f "$ASAR_BIN_PATH" ]; then
    echo "Asar binary not found."
    INSTALL_NEEDED=true
fi

if [ "$INSTALL_NEEDED" = true ]; then
    echo "Installing Electron and Asar locally into $WORK_DIR..."
    # Use --no-save to avoid modifying the temp package.json unnecessarily
    if ! npm install --no-save electron asar; then
        echo "❌ Failed to install Electron and/or Asar locally."
        cd "$PROJECT_ROOT"
        exit 1
    fi
    echo "✓ Electron and Asar installation command finished."
else
    echo "✓ Local Electron distribution and Asar binary already present."
fi

# Verify Electron installation by checking for the essential 'dist' directory
if [ -d "$ELECTRON_DIST_PATH" ]; then
    echo "✓ Found Electron distribution directory at $ELECTRON_DIST_PATH."
    CHOSEN_ELECTRON_MODULE_PATH="$(realpath "$WORK_DIR/node_modules/electron")"
    echo "✓ Setting Electron module path for copying to $CHOSEN_ELECTRON_MODULE_PATH."
else
    echo "❌ Failed to find Electron distribution directory at '$ELECTRON_DIST_PATH' after installation attempt."
    echo "   Cannot proceed without the Electron distribution files."
    cd "$PROJECT_ROOT" # Go back before exiting
    exit 1
fi

# Verify Asar installation
if [ -f "$ASAR_BIN_PATH" ]; then
    ASAR_EXEC="$(realpath "$ASAR_BIN_PATH")"
    echo "✓ Found local Asar binary at $ASAR_EXEC."
else
    echo "❌ Failed to find Asar binary at '$ASAR_BIN_PATH' after installation attempt."
    cd "$PROJECT_ROOT"
    exit 1
fi

cd "$PROJECT_ROOT" # Go back to project root

# Final check for the chosen Electron module path (redundant but safe)
if [ -z "$CHOSEN_ELECTRON_MODULE_PATH" ] || [ ! -d "$CHOSEN_ELECTRON_MODULE_PATH" ]; then
     echo "❌ Critical error: Could not resolve a valid Electron module path to copy."
     exit 1
fi
echo "Using Electron module path: $CHOSEN_ELECTRON_MODULE_PATH"
echo "Using asar executable: $ASAR_EXEC"


echo -e "\033[1;36m--- Download the latest Claude executable ---\033[0m"
# Download Claude Windows installer for the target architecture
echo "📥 Downloading Claude Desktop installer for $ARCHITECTURE..."
CLAUDE_EXE_PATH="$WORK_DIR/$CLAUDE_EXE_FILENAME"
if ! wget -O "$CLAUDE_EXE_PATH" "$CLAUDE_DOWNLOAD_URL"; then
    echo "❌ Failed to download Claude Desktop installer from $CLAUDE_DOWNLOAD_URL"
    exit 1
fi
echo "✓ Download complete: $CLAUDE_EXE_FILENAME"

# Extract resources into a dedicated subdirectory to avoid conflicts
echo "📦 Extracting resources from $CLAUDE_EXE_FILENAME into separate directory..."
CLAUDE_EXTRACT_DIR="$WORK_DIR/claude-extract"
mkdir -p "$CLAUDE_EXTRACT_DIR"
if ! 7z x -y "$CLAUDE_EXE_PATH" -o"$CLAUDE_EXTRACT_DIR"; then # Extract to specific dir
    echo "❌ Failed to extract installer"
    cd "$PROJECT_ROOT" && exit 1
fi

# Extract nupkg filename and version
cd "$CLAUDE_EXTRACT_DIR" # Change into the extract dir to find files
NUPKG_PATH_RELATIVE=$(find . -maxdepth 1 -name "AnthropicClaude-*.nupkg" | head -1)
if [ -z "$NUPKG_PATH_RELATIVE" ]; then
    echo "❌ Could not find AnthropicClaude nupkg file in $CLAUDE_EXTRACT_DIR"
    cd "$PROJECT_ROOT" && exit 1
fi
NUPKG_PATH="$CLAUDE_EXTRACT_DIR/$NUPKG_PATH_RELATIVE" # Store full path
echo "Found nupkg: $NUPKG_PATH_RELATIVE (in $CLAUDE_EXTRACT_DIR)"

# Extract version from the nupkg filename (using LC_ALL=C for locale compatibility)
VERSION=$(echo "$NUPKG_PATH_RELATIVE" | LC_ALL=C grep -oP 'AnthropicClaude-\K[0-9]+\.[0-9]+\.[0-9]+(?=-full|-arm64-full)')
if [ -z "$VERSION" ]; then
    echo "❌ Could not extract version from nupkg filename: $NUPKG_PATH_RELATIVE"
    cd "$PROJECT_ROOT" && exit 1
fi
echo "✓ Detected Claude version: $VERSION"

# Extract nupkg within its directory
if ! 7z x -y "$NUPKG_PATH_RELATIVE"; then # Use relative path since we are in CLAUDE_EXTRACT_DIR
    echo "❌ Failed to extract nupkg"
    cd "$PROJECT_ROOT" && exit 1
fi
echo "✓ Resources extracted from nupkg"

# Extract and convert icons (needed by the packaging script later)
# Still operating within CLAUDE_EXTRACT_DIR
EXE_RELATIVE_PATH="lib/net45/claude.exe" # Check if this path is correct for arm64 too
if [ ! -f "$EXE_RELATIVE_PATH" ]; then
    echo "❌ Cannot find claude.exe at expected path within extraction dir: $CLAUDE_EXTRACT_DIR/$EXE_RELATIVE_PATH"
    cd "$PROJECT_ROOT" && exit 1
fi
echo "🎨 Processing icons from $EXE_RELATIVE_PATH..."
# Output icons within the extraction directory
if ! wrestool -x -t 14 "$EXE_RELATIVE_PATH" -o claude.ico; then # Output relative to current dir (CLAUDE_EXTRACT_DIR)
    echo "❌ Failed to extract icons from exe"
    cd "$PROJECT_ROOT" && exit 1
fi

if ! icotool -x claude.ico; then # Input relative to current dir (CLAUDE_EXTRACT_DIR)
    echo "❌ Failed to convert icons"
    cd "$PROJECT_ROOT" && exit 1
fi
# Copy extracted icons to WORK_DIR for packaging scripts to find easily
cp claude_*.png "$WORK_DIR/"
echo "✓ Icons processed and copied to $WORK_DIR"

# Process app.asar
echo "⚙️ Processing app.asar..."
# Copy resources to staging dir first, using full paths from the extraction dir
cp "$CLAUDE_EXTRACT_DIR/lib/net45/resources/app.asar" "$APP_STAGING_DIR/"
cp -a "$CLAUDE_EXTRACT_DIR/lib/net45/resources/app.asar.unpacked" "$APP_STAGING_DIR/" # Use -a to preserve links/permissions

cd "$APP_STAGING_DIR" # Change to staging dir for asar processing
"$ASAR_EXEC" extract app.asar app.asar.contents

# Replace native module with stub implementation
echo "Creating stub native module..."
cat > app.asar.contents/node_modules/claude-native/index.js << EOF
// Stub implementation of claude-native using KeyboardKey enum values
const KeyboardKey = { Backspace: 43, Tab: 280, Enter: 261, Shift: 272, Control: 61, Alt: 40, CapsLock: 56, Escape: 85, Space: 276, PageUp: 251, PageDown: 250, End: 83, Home: 154, LeftArrow: 175, UpArrow: 282, RightArrow: 262, DownArrow: 81, Delete: 79, Meta: 187 };
Object.freeze(KeyboardKey);
module.exports = { getWindowsVersion: () => "10.0.0", setWindowEffect: () => {}, removeWindowEffect: () => {}, getIsMaximized: () => false, flashFrame: () => {}, clearFlashFrame: () => {}, showNotification: () => {}, setProgressBar: () => {}, clearProgressBar: () => {}, setOverlayIcon: () => {}, clearOverlayIcon: () => {}, KeyboardKey };
EOF

# Copy Tray icons
mkdir -p app.asar.contents/resources
mkdir -p app.asar.contents/resources/i18n
# Copy from the extraction directory (use full path for clarity)
cp "$CLAUDE_EXTRACT_DIR/lib/net45/resources/Tray"* app.asar.contents/resources/
cp "$CLAUDE_EXTRACT_DIR/lib/net45/resources/"*-*.json app.asar.contents/resources/i18n/

echo "Downloading Main Window Fix Assets"
cd app.asar.contents
wget -O- https://github.com/emsi/claude-desktop/raw/refs/heads/main/assets/main_window.tgz | tar -zxvf -
cd .. # Back to APP_STAGING_DIR

# Repackage app.asar
"$ASAR_EXEC" pack app.asar.contents app.asar

# Create native module stub within the staging area's unpacked directory
mkdir -p "$APP_STAGING_DIR/app.asar.unpacked/node_modules/claude-native"
cat > "$APP_STAGING_DIR/app.asar.unpacked/node_modules/claude-native/index.js" << EOF
// Stub implementation of claude-native using KeyboardKey enum values
const KeyboardKey = { Backspace: 43, Tab: 280, Enter: 261, Shift: 272, Control: 61, Alt: 40, CapsLock: 56, Escape: 85, Space: 276, PageUp: 251, PageDown: 250, End: 83, Home: 154, LeftArrow: 175, UpArrow: 282, RightArrow: 262, DownArrow: 81, Delete: 79, Meta: 187 };
Object.freeze(KeyboardKey);
module.exports = { getWindowsVersion: () => "10.0.0", setWindowEffect: () => {}, removeWindowEffect: () => {}, getIsMaximized: () => false, flashFrame: () => {}, clearFlashFrame: () => {}, showNotification: () => {}, setProgressBar: () => {}, clearProgressBar: () => {}, setOverlayIcon: () => {}, clearOverlayIcon: () => {}, KeyboardKey };
EOF

# Copy the chosen electron installation to the staging area
echo "Copying chosen electron installation to staging area..."
# Ensure the target node_modules directory exists in staging
mkdir -p "$APP_STAGING_DIR/node_modules/"
# Extract the directory name to copy (e.g., "electron")
ELECTRON_DIR_NAME=$(basename "$CHOSEN_ELECTRON_MODULE_PATH")
echo "Copying from $CHOSEN_ELECTRON_MODULE_PATH to $APP_STAGING_DIR/node_modules/"
# Copy the directory itself into node_modules
cp -a "$CHOSEN_ELECTRON_MODULE_PATH" "$APP_STAGING_DIR/node_modules/" # Use cp -a to preserve links/permissions

# Explicitly set executable permission on the copied electron binary
STAGED_ELECTRON_BIN="$APP_STAGING_DIR/node_modules/$ELECTRON_DIR_NAME/dist/electron"
if [ -f "$STAGED_ELECTRON_BIN" ]; then
    echo "Setting executable permission on staged Electron binary: $STAGED_ELECTRON_BIN"
    chmod +x "$STAGED_ELECTRON_BIN"
else
    echo "Warning: Staged Electron binary not found at expected path: $STAGED_ELECTRON_BIN"
fi

echo "✓ app.asar processed and staged in $APP_STAGING_DIR"

# Return to the original directory (project root) before calling the packaging script
cd "$PROJECT_ROOT"

# --- Call the appropriate packaging script ---
echo -e "\033[1;36m--- Call Packaging Script ---\033[0m"
FINAL_OUTPUT_PATH="" # Initialize variable for final path
FINAL_DESKTOP_FILE_PATH="" # Initialize variable for desktop file path

if [ "$BUILD_FORMAT" = "deb" ]; then
    echo "📦 Calling Debian packaging script for $ARCHITECTURE..."
    chmod +x scripts/build-deb-package.sh
    scripts/build-deb-package.sh \
        "$VERSION" "$ARCHITECTURE" "$WORK_DIR" "$APP_STAGING_DIR" \
        "$PACKAGE_NAME" "$MAINTAINER" "$DESCRIPTION"
    if [ $? -ne 0 ]; then echo "❌ Debian packaging script failed."; exit 1; fi
    DEB_FILE=$(find "$WORK_DIR" -maxdepth 1 -name "${PACKAGE_NAME}_${VERSION}_${ARCHITECTURE}.deb" | head -n 1)
    echo "✓ Debian Build complete!"
    if [ -n "$DEB_FILE" ] && [ -f "$DEB_FILE" ]; then
        FINAL_OUTPUT_PATH="./$(basename "$DEB_FILE")" # Set final path using basename directly
        mv "$DEB_FILE" "$FINAL_OUTPUT_PATH"
        echo "Package created at: $FINAL_OUTPUT_PATH"
    else
        echo "Warning: Could not determine final .deb file path from $WORK_DIR for ${ARCHITECTURE}."
        FINAL_OUTPUT_PATH="Not Found"
    fi

elif [ "$BUILD_FORMAT" = "appimage" ]; then
    echo "📦 Calling AppImage packaging script for $ARCHITECTURE..."
    chmod +x scripts/build-appimage.sh
    scripts/build-appimage.sh \
        "$VERSION" "$ARCHITECTURE" "$WORK_DIR" "$APP_STAGING_DIR" "$PACKAGE_NAME"
    if [ $? -ne 0 ]; then echo "❌ AppImage packaging script failed."; exit 1; fi
    APPIMAGE_FILE=$(find "$WORK_DIR" -maxdepth 1 -name "${PACKAGE_NAME}-${VERSION}-${ARCHITECTURE}.AppImage" | head -n 1)
    echo "✓ AppImage Build complete!"
    if [ -n "$APPIMAGE_FILE" ] && [ -f "$APPIMAGE_FILE" ]; then
        FINAL_OUTPUT_PATH="./$(basename "$APPIMAGE_FILE")" # Set final path using basename directly
        mv "$APPIMAGE_FILE" "$FINAL_OUTPUT_PATH"
        echo "Package created at: $FINAL_OUTPUT_PATH"

        # --- Generate .desktop file for AppImage ---
        echo -e "\033[1;36m--- Generate .desktop file for AppImage ---\033[0m"
        FINAL_DESKTOP_FILE_PATH="./${PACKAGE_NAME}-appimage.desktop"
        APPIMAGE_ABS_PATH=$(realpath "$FINAL_OUTPUT_PATH")
        echo "📝 Generating .desktop file for AppImage at $FINAL_DESKTOP_FILE_PATH..."
        cat > "$FINAL_DESKTOP_FILE_PATH" << EOF
[Desktop Entry]
Name=Claude (AppImage)
Comment=Claude Desktop (AppImage Version $VERSION)
Exec=$APPIMAGE_ABS_PATH %u
Icon=claude-desktop
Type=Application
Terminal=false
Categories=Office;Utility;Network;
MimeType=x-scheme-handler/claude;
StartupWMClass=Claude
X-AppImage-Version=$VERSION
X-AppImage-Name=Claude Desktop (AppImage)
EOF
        echo "✓ .desktop file generated."

    else
        echo "Warning: Could not determine final .AppImage file path from $WORK_DIR for ${ARCHITECTURE}."
        FINAL_OUTPUT_PATH="Not Found"
    fi
fi

# --- Set Final Package Ownership ---
echo -e "\033[1;36m--- Set Final Package Ownership ---\033[0m"
if [ "$IS_SUDO" = true ] && [ "$ORIGINAL_USER" != "root" ]; then
    if [ "$FINAL_OUTPUT_PATH" != "Not Found" ] && [ -e "$FINAL_OUTPUT_PATH" ]; then
        echo "🔒 Setting ownership of $FINAL_OUTPUT_PATH to $ORIGINAL_USER..."
        chown "$ORIGINAL_USER":"$(id -gn "$ORIGINAL_USER")" "$FINAL_OUTPUT_PATH"
        echo "✓ Ownership set for package."
    fi
    # Set ownership for generated desktop file as well
    if [ -n "$FINAL_DESKTOP_FILE_PATH" ] && [ -e "$FINAL_DESKTOP_FILE_PATH" ]; then
         echo "🔒 Setting ownership of $FINAL_DESKTOP_FILE_PATH to $ORIGINAL_USER..."
         chown "$ORIGINAL_USER":"$(id -gn "$ORIGINAL_USER")" "$FINAL_DESKTOP_FILE_PATH"
         echo "✓ Ownership set for .desktop file."
    fi
fi

# --- Cleanup ---
echo -e "\033[1;36m--- Cleanup ---\033[0m"
if [ "$PERFORM_CLEANUP" = true ]; then
    echo "🧹 Cleaning up intermediate build files in $WORK_DIR..."
    # Simply remove the entire WORK_DIR, as final files are moved out
    if rm -rf "$WORK_DIR"; then
        echo "✓ Cleanup complete ($WORK_DIR removed)."
    else
        echo "⚠️ Cleanup command (rm -rf $WORK_DIR) failed."
    fi
else
    echo "Skipping cleanup of intermediate build files in $WORK_DIR."
fi

# Temporary package.json is inside WORK_DIR, so no separate removal needed

echo "✅ Build process finished."

# --- Post-Build Instructions ---
echo -e "\n\033[1;34m====== Next Steps ======\033[0m"
if [ "$BUILD_FORMAT" = "deb" ]; then
    if [ "$FINAL_OUTPUT_PATH" != "Not Found" ] && [ -e "$FINAL_OUTPUT_PATH" ]; then
        echo -e "📦 To install the Debian package, run:"
        echo -e "   \033[1;32msudo apt install $FINAL_OUTPUT_PATH\033[0m"
        echo -e "   (or \`sudo dpkg -i $FINAL_OUTPUT_PATH\`)"
    else
        echo -e "⚠️ Debian package file not found. Cannot provide installation instructions."
    fi
elif [ "$BUILD_FORMAT" = "appimage" ]; then
    if [ "$FINAL_OUTPUT_PATH" != "Not Found" ] && [ -e "$FINAL_OUTPUT_PATH" ]; then
        echo -e "✅ AppImage created at: \033[1;36m$FINAL_OUTPUT_PATH\033[0m"
        echo -e "\n\033[1;33mIMPORTANT:\033[0m This AppImage requires \033[1;36mAppImageLauncher\033[0m for proper desktop integration"
        echo -e "and to handle the \`claude://\` login process correctly."
        echo -e "\n🚀 To install AppImageLauncher (v2.2.0 for amd64):"
        echo -e "   1. Download:"
        echo -e "      \033[1;32mwget https://github.com/TheAssassin/AppImageLauncher/releases/download/v2.2.0/appimagelauncher_2.2.0-travis995.0f91801.bionic_amd64.deb -O /tmp/appimagelauncher.deb\033[0m"
        echo -e "       - or appropriate package from here: \033[1;34mhttps://github.com/TheAssassin/AppImageLauncher/releases/latest\033[0m"
        echo -e "   2. Install the package:"
        echo -e "      \033[1;32msudo dpkg -i /tmp/appimagelauncher.deb\033[0m"
        echo -e "   3. Fix any missing dependencies:"
        echo -e "      \033[1;32msudo apt --fix-broken install\033[0m"
        echo -e "\n   After installation, simply double-click \033[1;36m$FINAL_OUTPUT_PATH\033[0m and choose 'Integrate and run'."
    else
        echo -e "⚠️ AppImage file not found. Cannot provide usage instructions."
    fi
fi
echo -e "\033[1;34m======================\033[0m"

exit 0