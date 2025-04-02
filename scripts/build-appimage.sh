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
# Copy the core application files (asar, unpacked resources)
cp -r "$APP_STAGING_DIR/"* "$APPDIR_PATH/usr/lib/" # Copy contents into usr/lib

# Copy the launcher script (needs modification for AppDir context)
# TODO: Create an AppRun script or adapt the existing launcher

# Copy icons
echo "🎨 Copying icons..."
ICON_SOURCE_PATH="$WORK_DIR/claude_6_256x256x32.png" # Assuming 256x256 icon exists from previous steps
if [ -f "$ICON_SOURCE_PATH" ]; then
    cp "$ICON_SOURCE_PATH" "$APPDIR_PATH/usr/share/icons/hicolor/256x256/apps/${PACKAGE_NAME}.png"
    # Also copy to top-level for AppImage icon
    cp "$ICON_SOURCE_PATH" "$APPDIR_PATH/${PACKAGE_NAME}.png"
else
    echo "Warning: Missing 256x256 icon at $ICON_SOURCE_PATH"
fi

# Copy desktop file (needs modification for AppDir context)
echo "📝 Copying desktop file..."
DESKTOP_SOURCE_PATH="$APP_STAGING_DIR/../package/usr/share/applications/${PACKAGE_NAME}.desktop" # Assuming it was created for deb
# TODO: Adapt desktop file Exec= line for AppDir
# cp "$DESKTOP_SOURCE_PATH" "$APPDIR_PATH/" # Copy to top level

echo "🚧 AppImage building logic is not fully implemented yet."
echo "   - Need to create/adapt AppRun script."
echo "   - Need to adapt .desktop file."
echo "   - Need to download and use appimagetool."

# Example placeholder for final step:
# appimagetool "$APPDIR_PATH" "$WORK_DIR/${PACKAGE_NAME}-${VERSION}-${ARCHITECTURE}.AppImage"

echo "--- AppImage Build Placeholder Finished ---"

exit 0