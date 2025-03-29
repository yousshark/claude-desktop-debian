# Maintainer: Your Name <your_email@domain.com> # Please update maintainer info
_pkgname=claude-desktop
pkgname=$_pkgname
pkgver=0.9.0 # Hardcode version - update manually for new releases
pkgrel=1
pkgdesc="Claude Desktop for Linux – an AI assistant from Anthropic"
arch=('x86_64')
url="https://github.com/aaddrick/claude-desktop-debian"
license=('custom: LICENSE-MIT AND LICENSE-APACHE')
depends=('nodejs' 'npm' 'electron' 'p7zip' 'icoutils' 'imagemagick')
makedepends=('wget' 'p7zip') # p7zip needed in build()
# Use a generic name for the installer in source array
_installer_filename="Claude-Setup-x64.exe"
source=("$_installer_filename::https://storage.googleapis.com/osprey-downloads-c02f6a0d-347c-492b-a752-3e0651722e97/nest-win-x64/Claude-Setup-x64.exe"
        "LICENSE-MIT::https://raw.githubusercontent.com/aaddrick/claude-desktop-debian/main/LICENSE-MIT"
        "LICENSE-APACHE::https://raw.githubusercontent.com/aaddrick/claude-desktop-debian/main/LICENSE-APACHE")
sha256sums=('SKIP' # Installer checksum changes with version
            'SKIP' # MIT License
            'SKIP') # Apache License

build() {
  cd "$srcdir"
  # Use the downloaded installer filename
  local _installer_file="$srcdir/$_installer_filename"

  mkdir -p build
  cd build

  echo "Extracting Windows installer..."
  7z x -y "$_installer_file" || { echo "Extraction failed"; exit 1; }

  # The installer contains a .nupkg file named using the version
  echo "Extracting nupkg for version ${pkgver}..."
  # Find the nupkg file using the hardcoded pkgver
  local _nupkg_path="./AnthropicClaude-${pkgver}-full.nupkg"
  if [ ! -f "$_nupkg_path" ]; then
      echo "❌ Could not find nupkg file for version ${pkgver}: $_nupkg_path"
      # List files to help debug if needed
      ls -la
      exit 1
  fi
  echo "✓ Using nupkg: $_nupkg_path"

  7z x -y "$_nupkg_path" || { echo "nupkg extraction failed"; exit 1; }


  echo "Processing icons..."
  # Extract icons from the exe (wrestool and icotool come from icoutils)
  wrestool -x -t 14 "lib/net45/claude.exe" -o claude.ico || { echo "wrestool failed"; exit 1; }
  icotool -x claude.ico || { echo "icotool failed"; exit 1; }

  echo "Preparing Electron app..."
  mkdir -p electron-app
  cp "lib/net45/resources/app.asar" electron-app/
  cp -r "lib/net45/resources/app.asar.unpacked" electron-app/

  cd electron-app
  # Extract the asar package to allow modifications
  npx asar extract app.asar app.asar.contents || { echo "asar extract failed"; exit 1; }


  echo "Creating stub native module..."
  mkdir -p app.asar.contents/node_modules/claude-native
  cat > app.asar.contents/node_modules/claude-native/index.js << 'EOF'
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

  echo "Copying tray and i18n resources..."
  mkdir -p app.asar.contents/resources
  cp ../lib/net45/resources/Tray* app.asar.contents/resources/
  # Copy i18n files
  mkdir -p app.asar.contents/resources/i18n
  cp ../lib/net45/resources/*-*.json app.asar.contents/resources/i18n/


  echo "Repacking asar..."
  npx asar pack app.asar.contents app.asar || { echo "asar pack failed"; exit 1; }


  # Return to the build directory root
  cd "$srcdir/build"
}

package() {
  cd "$srcdir/build"

  echo "Installing files..."
  # Create installation directories
  install -d "$pkgdir/usr/lib/$_pkgname"
  install -d "$pkgdir/usr/share/applications"
  install -d "$pkgdir/usr/share/icons/hicolor"
  install -d "$pkgdir/usr/bin"

  # Install the Electron app (app.asar and its unpacked resources)
  cp electron-app/app.asar "$pkgdir/usr/lib/$_pkgname/"
  cp -r electron-app/app.asar.unpacked "$pkgdir/usr/lib/$_pkgname/"

  echo "Installing icons..."
  # Map icon sizes to the extracted filenames
  for size in 16 24 32 48 64 256; do
    icon_file=""
    case "$size" in
      16) icon_file="claude_13_16x16x32.png" ;;
      24) icon_file="claude_11_24x24x32.png" ;;
      32) icon_file="claude_10_32x32x32.png" ;;
      48) icon_file="claude_8_48x48x32.png" ;;
      64) icon_file="claude_7_64x64x32.png" ;;
      256) icon_file="claude_6_256x256x32.png" ;;
    esac
    if [ -f "$srcdir/build/$icon_file" ]; then
      install -Dm644 "$srcdir/build/$icon_file" "$pkgdir/usr/share/icons/hicolor/${size}x${size}/apps/${_pkgname}.png"
    else
      echo "Warning: Missing ${size}x${size} icon"
    fi
  done

  echo "Creating desktop entry..."
  cat > "$pkgdir/usr/share/applications/${_pkgname}.desktop" << EOF
[Desktop Entry]
Name=Claude
Exec=$_pkgname %u
Icon=$_pkgname
Type=Application
Terminal=false
Categories=Office;Utility;
MimeType=x-scheme-handler/claude;
StartupWMClass=Claude
EOF

  echo "Creating launcher script..."
  # Add Wayland flags similar to the debian script
  cat > "$pkgdir/usr/bin/$_pkgname" << EOF
#!/bin/bash
# Detect if Wayland is likely running
IS_WAYLAND=false
if [ ! -z "\$WAYLAND_DISPLAY" ]; then
  IS_WAYLAND=true
fi

# Base command arguments
ELECTRON_ARGS=("/usr/lib/$_pkgname/app.asar")

# Add Wayland flags if Wayland is detected
if [ "\$IS_WAYLAND" = true ]; then
  echo "Wayland detected, adding Wayland flags to Electron..."
  ELECTRON_ARGS+=("--enable-features=UseOzonePlatform,WaylandWindowDecorations" "--ozone-platform=wayland")
fi

# Append any arguments passed to the script
ELECTRON_ARGS+=("\$@")

# Execute electron with arguments
electron "\${ELECTRON_ARGS[@]}"
EOF
  chmod +x "$pkgdir/usr/bin/$_pkgname"

  # Install license files fetched by makepkg
  install -Dm644 "$srcdir/LICENSE-MIT" "$pkgdir/usr/share/licenses/$pkgname/LICENSE-MIT"
  install -Dm644 "$srcdir/LICENSE-APACHE" "$pkgdir/usr/share/licenses/$pkgname/LICENSE-APACHE"
}
