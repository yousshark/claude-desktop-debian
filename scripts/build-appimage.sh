#!/bin/bash
set -e

# Arguments passed from the main script
VERSION="$1"
ARCHITECTURE="$2"
WORK_DIR="$3" # The top-level build directory (e.g., ./build)
APP_STAGING_DIR="$4" # Directory containing the prepared app files (e.g., ./build/electron-app)
PACKAGE_NAME="$5"
# MAINTAINER and DESCRIPTION might not be directly used by AppImage tools but passed for consistency

echo "--- Starting AppImage Build ---"
echo "Version: $VERSION"
echo "Architecture: $ARCHITECTURE"
echo "Work Directory: $WORK_DIR"
echo "App Staging Directory: $APP_STAGING_DIR"
echo "Package Name: $PACKAGE_NAME"

# Define AppDir structure path
APPDIR_PATH="$WORK_DIR/${PACKAGE_NAME}.AppDir"
rm -rf "$APPDIR_PATH"
mkdir -p "$APPDIR_PATH/usr/bin"
mkdir -p "$APPDIR_PATH/usr/lib"
mkdir -p "$APPDIR_PATH/usr/share/icons/hicolor/256x256/apps"
mkdir -p "$APPDIR_PATH/usr/share/applications"

echo "📦 Staging application files into AppDir..."
# Copy the core application files (asar, unpacked resources, node_modules if present)
# Explicitly copy required components to ensure hidden files/dirs like .bin are included
if [ -f "$APP_STAGING_DIR/app.asar" ]; then
    cp -a "$APP_STAGING_DIR/app.asar" "$APPDIR_PATH/usr/lib/"
fi
if [ -d "$APP_STAGING_DIR/app.asar.unpacked" ]; then
    cp -a "$APP_STAGING_DIR/app.asar.unpacked" "$APPDIR_PATH/usr/lib/"
fi
if [ -d "$APP_STAGING_DIR/node_modules" ]; then
    echo "Copying node_modules from staging to AppDir..."
    cp -a "$APP_STAGING_DIR/node_modules" "$APPDIR_PATH/usr/lib/"
fi

# Ensure Electron is bundled within the AppDir for portability
# Check if electron was copied into the staging dir's node_modules
# The actual executable is usually inside the 'dist' directory
BUNDLED_ELECTRON_PATH="$APPDIR_PATH/usr/lib/node_modules/electron/dist/electron"
echo "Checking for executable at: $BUNDLED_ELECTRON_PATH"
if [ ! -x "$BUNDLED_ELECTRON_PATH" ]; then # Check if it exists and is executable
    echo "❌ Electron executable not found or not executable in staging area ($BUNDLED_ELECTRON_PATH)."
    echo "   AppImage requires Electron to be bundled. Ensure the main script copies it correctly."
    exit 1
fi
# Ensure the bundled electron is executable (redundant check, but safe)
chmod +x "$BUNDLED_ELECTRON_PATH"

# --- Create AppRun Script ---
echo "🚀 Creating AppRun script..."
# Note: We use $VERSION and $PACKAGE_NAME from the build script environment here
# They will be embedded into the AppRun script.
DESKTOP_FILE_BASENAME="${PACKAGE_NAME}-${VERSION}.desktop" # Unique name
cat > "$APPDIR_PATH/AppRun" << EOF
#!/bin/bash
set -e

# Find the location of the AppRun script and the AppImage file itself
APPDIR=\$(dirname "\$0")
# Try to get the absolute path of the AppImage file being run
# $APPIMAGE is often set by the AppImage runtime, otherwise try readlink
APPIMAGE_PATH="\${APPIMAGE:-}"
if [ -z "\$APPIMAGE_PATH" ]; then
    # Find the AppRun script itself, which should be $0
    # Use readlink -f to get the absolute path, handling symlinks
    # Go up one level from AppRun's dir to get the AppImage path (usually)
    # This might be fragile if AppRun is not at the root, but it's standard.
    APPIMAGE_PATH=\$(readlink -f "\$APPDIR/../$(basename "$APPDIR" .AppDir).AppImage" 2>/dev/null || readlink -f "\$0" 2>/dev/null)
    # As a final fallback, just use $0, hoping it's the AppImage path
    if [ -z "\$APPIMAGE_PATH" ] || [ ! -f "\$APPIMAGE_PATH" ]; then
        APPIMAGE_PATH="\$0"
    fi
fi

# --- Attempt to Register claude:// URI Scheme Handler ---
register_uri_scheme() {
    local desktop_file_basename="$1"
    local appimage_exec_path="$2"
    local scheme="claude"

    echo "AppRun: Attempting to register x-scheme-handler/$scheme..."

    # Check if necessary tools exist
    if ! command -v xdg-mime >/dev/null 2>&1 || ! command -v update-desktop-database >/dev/null 2>&1; then
        echo "AppRun: Warning - xdg-mime or update-desktop-database not found. Cannot register URI scheme."
        return 1
    fi

    # Define user's local applications directory
    local user_apps_dir="\$HOME/.local/share/applications"
    mkdir -p "\$user_apps_dir"

    local desktop_file_path="\$user_apps_dir/\$desktop_file_basename"

    echo "AppRun: Creating desktop file at \$desktop_file_path"
    # Create the .desktop file
    # Use the determined absolute path to the AppImage for Exec
    cat > "\$desktop_file_path" << DESKTOP_EOF
[Desktop Entry]
Name=Claude (AppImage $VERSION)
Comment=Claude Desktop (AppImage Version $VERSION)
Exec=$appimage_exec_path %u
Icon=$PACKAGE_NAME
Type=Application
Terminal=false
Categories=Office;Utility;Network;
MimeType=x-scheme-handler/$scheme;
StartupWMClass=Claude
X-AppImage-Version=$VERSION
X-AppImage-Name=Claude Desktop (AppImage)
DESKTOP_EOF

    echo "AppRun: Running xdg-mime default..."
    xdg-mime default "\$desktop_file_basename" "x-scheme-handler/\$scheme"

    echo "AppRun: Running update-desktop-database..."
    update-desktop-database "\$user_apps_dir"

    echo "AppRun: URI scheme registration attempted."
}

# Run registration in the background to avoid delaying app start significantly
# Pass the unique desktop file name and the determined AppImage path
register_uri_scheme "$DESKTOP_FILE_BASENAME" "\$APPIMAGE_PATH" &

# --- End URI Scheme Handler Registration ---


# Set up environment variables if needed (e.g., LD_LIBRARY_PATH)
# export LD_LIBRARY_PATH="\$APPDIR/usr/lib:\$LD_LIBRARY_PATH"

# Detect if Wayland is likely running
IS_WAYLAND=false
if [ ! -z "\$WAYLAND_DISPLAY" ]; then
  IS_WAYLAND=true
fi

# Path to the bundled Electron executable
# Use the path relative to AppRun within the 'electron/dist' module directory
ELECTRON_EXEC="\$APPDIR/usr/lib/node_modules/electron/dist/electron"
APP_PATH="\$APPDIR/usr/lib/app.asar"

# Base command arguments array
ELECTRON_ARGS=("\$APP_PATH")

# Add Wayland flags if Wayland is detected
if [ "\$IS_WAYLAND" = true ]; then
  echo "AppRun: Wayland detected, adding flags."
  ELECTRON_ARGS+=("--enable-features=UseOzonePlatform,WaylandWindowDecorations" "--ozone-platform=wayland")
fi

# Change to the application resources directory (where app.asar is)
cd "\$APPDIR/usr/lib" || exit 1

# Execute Electron with app path, flags, and script arguments passed to AppRun
echo "AppRun: Executing \$ELECTRON_EXEC \${ELECTRON_ARGS[@]} \$@"
exec "\$ELECTRON_EXEC" "\${ELECTRON_ARGS[@]}" "\$@"
EOF
chmod +x "$APPDIR_PATH/AppRun"
echo "✓ AppRun script created with URI scheme registration logic"

# --- Create Desktop Entry (Bundled inside AppDir) ---
echo "📝 Creating bundled desktop entry..."
# Use package name for icon (AppImage tools expect this)
ICON_NAME=$PACKAGE_NAME
# This is the desktop file *inside* the AppImage, used by tools like appimaged
cat > "$APPDIR_PATH/$PACKAGE_NAME.desktop" << EOF
[Desktop Entry]
Name=Claude
Exec=AppRun %u
Icon=$ICON_NAME
Type=Application
Terminal=false
Categories=Office;Utility;Network;
Comment=Claude Desktop for Linux
MimeType=x-scheme-handler/claude;
StartupWMClass=Claude
X-AppImage-Version=$VERSION
X-AppImage-Name=Claude Desktop
EOF
# Also place it in the standard location for tools like appimaged
cp "$APPDIR_PATH/$PACKAGE_NAME.desktop" "$APPDIR_PATH/usr/share/applications/"
echo "✓ Bundled desktop entry created"

# --- Copy Icons ---
echo "🎨 Copying icons..."
# Use the 256x256 icon as the main AppImage icon
ICON_SOURCE_PATH="$WORK_DIR/claude_6_256x256x32.png"
if [ -f "$ICON_SOURCE_PATH" ]; then
    # Standard location within AppDir
    cp "$ICON_SOURCE_PATH" "$APPDIR_PATH/usr/share/icons/hicolor/256x256/apps/${PACKAGE_NAME}.png"
    # Top-level icon (used by appimagetool)
    cp "$ICON_SOURCE_PATH" "$APPDIR_PATH/${ICON_NAME}.png"
    echo "✓ Icon copied"
else
    echo "Warning: Missing 256x256 icon at $ICON_SOURCE_PATH. AppImage icon might be missing."
fi

# --- Get appimagetool ---
APPIMAGETOOL_PATH=""
if command -v appimagetool &> /dev/null; then
    APPIMAGETOOL_PATH=$(command -v appimagetool)
    echo "✓ Found appimagetool in PATH: $APPIMAGETOOL_PATH"
elif [ -f "$WORK_DIR/appimagetool-x86_64.AppImage" ]; then # Check for specific arch first
    APPIMAGETOOL_PATH="$WORK_DIR/appimagetool-x86_64.AppImage"
    echo "✓ Found downloaded x86_64 appimagetool: $APPIMAGETOOL_PATH"
elif [ -f "$WORK_DIR/appimagetool-aarch64.AppImage" ]; then # Check for other arch
    APPIMAGETOOL_PATH="$WORK_DIR/appimagetool-aarch64.AppImage"
    echo "✓ Found downloaded aarch64 appimagetool: $APPIMAGETOOL_PATH"
else
    echo "🛠️ Downloading appimagetool..."
    # Determine architecture for download URL
    TOOL_ARCH=""
    case "$ARCHITECTURE" in
        "amd64") TOOL_ARCH="x86_64" ;;
        "arm64") TOOL_ARCH="aarch64" ;;
        *) echo "❌ Unsupported architecture for appimagetool download: $ARCHITECTURE"; exit 1 ;;
    esac

    APPIMAGETOOL_URL="https://github.com/AppImage/AppImageKit/releases/download/continuous/appimagetool-${TOOL_ARCH}.AppImage"
    APPIMAGETOOL_PATH="$WORK_DIR/appimagetool-${TOOL_ARCH}.AppImage"

    if wget -q -O "$APPIMAGETOOL_PATH" "$APPIMAGETOOL_URL"; then
        chmod +x "$APPIMAGETOOL_PATH"
        echo "✓ Downloaded appimagetool to $APPIMAGETOOL_PATH"
    else
        echo "❌ Failed to download appimagetool from $APPIMAGETOOL_URL"
        rm -f "$APPIMAGETOOL_PATH" # Clean up partial download
        exit 1
    fi
fi

# --- Build AppImage ---
echo "📦 Building AppImage..."
OUTPUT_FILENAME="${PACKAGE_NAME}-${VERSION}-${ARCHITECTURE}.AppImage"
OUTPUT_PATH="$WORK_DIR/$OUTPUT_FILENAME"

# Ensure chrome-sandbox has correct permissions within AppDir before building
SANDBOX_PATH="$APPDIR_PATH/usr/lib/node_modules/electron/dist/chrome-sandbox"
if [ -f "$SANDBOX_PATH" ]; then
    echo "Setting permissions for bundled chrome-sandbox..."
    # No need for chown root:root inside AppDir, just setuid
    chmod 4755 "$SANDBOX_PATH" || echo "Warning: Failed to chmod chrome-sandbox"
else
    # Try alternative sandbox path sometimes found directly in electron dir
    SANDBOX_PATH_ALT="$APPDIR_PATH/usr/lib/node_modules/electron/chrome-sandbox"
    if [ -f "$SANDBOX_PATH_ALT" ]; then
         echo "Setting permissions for bundled chrome-sandbox (alternative path)..."
         chmod 4755 "$SANDBOX_PATH_ALT" || echo "Warning: Failed to chmod chrome-sandbox (alternative path)"
         SANDBOX_PATH="$SANDBOX_PATH_ALT" # Update SANDBOX_PATH if found here
    else
        echo "Warning: Bundled chrome-sandbox not found at standard or alternative paths."
    fi
fi

# Execute appimagetool
# Export ARCH instead of using env
export ARCH="$ARCHITECTURE"
echo "Using ARCH=$ARCH" # Debug output
if "$APPIMAGETOOL_PATH" "$APPDIR_PATH" "$OUTPUT_PATH"; then
    echo "✓ AppImage built successfully: $OUTPUT_PATH"
else
    echo "❌ Failed to build AppImage using $APPIMAGETOOL_PATH"
    exit 1
fi

echo "--- AppImage Build Finished ---"

exit 0