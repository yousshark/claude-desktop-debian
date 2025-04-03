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

# --- Desktop Integration (Handled by AppImageLauncher) ---
# The bundled .desktop file (claude-desktop-appimage.desktop) inside the AppImage
# contains the necessary MimeType=x-scheme-handler/claude; entry.
# AppImageLauncher (or similar tools) will use this file to integrate
# the AppImage with the system, including setting up the URI scheme handler,
# if the user chooses to integrate. No manual registration is needed here.
# --- End Desktop Integration ---


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
# Add --no-sandbox flag to avoid sandbox issues within AppImage
ELECTRON_ARGS=("--no-sandbox" "\$APP_PATH")

# Add Wayland flags if Wayland is detected
if [ "\$IS_WAYLAND" = true ]; then
  echo "AppRun: Wayland detected, adding flags."
  ELECTRON_ARGS+=("--enable-features=UseOzonePlatform,WaylandWindowDecorations" "--ozone-platform=wayland")
fi

# Change to the application resources directory (where app.asar is)
cd "\$APPDIR/usr/lib" || exit 1

# Define log file path in user's home directory
LOG_FILE="\$HOME/claude-desktop-launcher.log"

# Change to HOME directory before exec'ing Electron to avoid CWD permission issues
cd "\$HOME" || exit 1

# Execute Electron with app path, flags, and script arguments passed to AppRun
# Redirect stdout and stderr to the log file (append)
echo "AppRun: Executing \$ELECTRON_EXEC \${ELECTRON_ARGS[@]} \$@ >> \$LOG_FILE 2>&1"
exec "\$ELECTRON_EXEC" "\${ELECTRON_ARGS[@]}" "\$@" >> "\$LOG_FILE" 2>&1
EOF
chmod +x "$APPDIR_PATH/AppRun"
echo "✓ AppRun script created (with logging to \$HOME/claude-desktop-launcher.log, --no-sandbox, and CWD set to \$HOME)"

# --- Create Desktop Entry (Bundled inside AppDir) ---
echo "📝 Creating bundled desktop entry..."
# This is the desktop file *inside* the AppImage, used by tools like appimaged
cat > "$APPDIR_PATH/$PACKAGE_NAME.desktop" << EOF
[Desktop Entry]
Name=Claude
Exec=AppRun %u
Icon=$PACKAGE_NAME
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
echo "✓ Bundled desktop entry created"

# --- Copy Icons ---
echo "🎨 Copying icons..."
# Use the 256x256 icon as the main AppImage icon
ICON_SOURCE_PATH="$WORK_DIR/claude_6_256x256x32.png"
if [ -f "$ICON_SOURCE_PATH" ]; then
    # Standard location within AppDir
    cp "$ICON_SOURCE_PATH" "$APPDIR_PATH/usr/share/icons/hicolor/256x256/apps/${PACKAGE_NAME}.png"
    # Top-level icon (used by appimagetool) - Should match the Icon field in the .desktop file
    cp "$ICON_SOURCE_PATH" "$APPDIR_PATH/${PACKAGE_NAME}.png"
    # Top-level icon without extension (fallback for some tools)
    cp "$ICON_SOURCE_PATH" "$APPDIR_PATH/${PACKAGE_NAME}"
    # Hidden .DirIcon (fallback for some systems/tools)
    cp "$ICON_SOURCE_PATH" "$APPDIR_PATH/.DirIcon"
    echo "✓ Icon copied to standard path, top-level (.png and no ext), and .DirIcon"
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