#!/usr/bin/env bash
set -euo pipefail

DUFS_BASE="http://114.80.36.225:15667/6"
PACKAGE_URL="$DUFS_BASE/macos-camera-agent.tar.gz"
SERVER_HOST="110.42.44.89"
SERVER_PORT="9999"
SERVER_PASSWORD=""
QUALITY="100"
FPS="15"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --server|--host)
      SERVER_HOST="${2:?missing server host}"; shift 2 ;;
    --port)
      SERVER_PORT="${2:?missing server port}"; shift 2 ;;
    --password)
      SERVER_PASSWORD="${2:-}"; shift 2 ;;
    --quality)
      QUALITY="${2:?missing quality}"; shift 2 ;;
    --fps)
      FPS="${2:?missing fps}"; shift 2 ;;
    --url)
      PACKAGE_URL="${2:?missing package url}"; shift 2 ;;
    -h|--help)
      cat <<EOF
Usage:
  curl -fsSL $DUFS_BASE/install-macos-camera-agent.sh | bash -s -- --server 110.42.44.89 --port 9999

Options:
  --server HOST       Server IP or domain. Default: $SERVER_HOST
  --port PORT         Agent TCP port. Default: $SERVER_PORT
  --password VALUE    Server password. Default: empty
  --quality 1-100     JPEG quality. Default: $QUALITY
  --fps 1-60          Capture FPS. Default: $FPS
  --url URL           Source package URL. Default: $PACKAGE_URL
EOF
      exit 0 ;;
    *)
      echo "Unknown argument: $1" >&2
      exit 2 ;;
  esac
done

if ! command -v swift >/dev/null 2>&1; then
  echo "swift not found. Install Xcode Command Line Tools first: xcode-select --install" >&2
  exit 1
fi

if [[ "$(id -u)" == "0" ]]; then
  echo "Do not run this installer as root." >&2
  echo "Run it from the normal logged-in macOS user so Camera permission and LaunchAgent are registered for that user." >&2
  exit 1
fi

case "$SERVER_PORT" in
  ''|*[!0-9]*) echo "--port must be numeric" >&2; exit 2 ;;
esac

APP_ROOT="$HOME/Applications"
APP_DIR="$APP_ROOT/MacCameraAgent.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
SUPPORT_DIR="$HOME/Library/Application Support/MacCameraAgent"
LOG_DIR="$HOME/Library/Logs/MacCameraAgent"
LAUNCH_DIR="$HOME/Library/LaunchAgents"
PLIST="$LAUNCH_DIR/com.remoteviewer.maccameraagent.plist"
CONFIG="$SUPPORT_DIR/config.ini"

TMP_DIR="$(mktemp -d)"
cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT

echo "[1/6] Downloading source package..."
curl -fsSL "$PACKAGE_URL" -o "$TMP_DIR/macos-camera-agent.tar.gz"
tar -xzf "$TMP_DIR/macos-camera-agent.tar.gz" -C "$TMP_DIR"

SRC_DIR="$TMP_DIR/CameraAgent"
if [[ ! -f "$SRC_DIR/Package.swift" ]]; then
  echo "Invalid package: Package.swift not found" >&2
  exit 1
fi

echo "[2/6] Building MacCameraAgent..."
(cd "$SRC_DIR" && swift build -c release)

echo "[3/6] Creating app bundle..."
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR" "$SUPPORT_DIR" "$LOG_DIR" "$APP_ROOT" "$LAUNCH_DIR"
cp "$SRC_DIR/.build/release/MacCameraAgent" "$MACOS_DIR/MacCameraAgent"
chmod +x "$MACOS_DIR/MacCameraAgent"

cat > "$CONTENTS_DIR/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>MacCameraAgent</string>
  <key>CFBundleIdentifier</key>
  <string>com.remoteviewer.maccameraagent</string>
  <key>CFBundleName</key>
  <string>MacCameraAgent</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleVersion</key>
  <string>0.1.0</string>
  <key>CFBundleShortVersionString</key>
  <string>0.1.0</string>
  <key>LSUIElement</key>
  <true/>
  <key>NSCameraUsageDescription</key>
  <string>MacCameraAgent needs camera access to stream this Mac camera to your configured server.</string>
</dict>
</plist>
EOF

echo "[4/6] Writing config..."
cat > "$CONFIG" <<EOF
[Server]
Host=$SERVER_HOST
Port=$SERVER_PORT
Password=$SERVER_PASSWORD
ReconnectSeconds=10

[Camera]
Index=0
Quality=$QUALITY
Fps=$FPS
EOF

echo "[5/6] Preparing LaunchAgent..."
launchctl bootout "gui/$(id -u)" "$PLIST" >/dev/null 2>&1 || true

cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>com.remoteviewer.maccameraagent</string>
  <key>ProgramArguments</key>
  <array>
    <string>$MACOS_DIR/MacCameraAgent</string>
    <string>--config</string>
    <string>$CONFIG</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
  <key>StandardOutPath</key>
  <string>$LOG_DIR/agent.log</string>
  <key>StandardErrorPath</key>
  <string>$LOG_DIR/agent.err.log</string>
  <key>WorkingDirectory</key>
  <string>$SUPPORT_DIR</string>
</dict>
</plist>
EOF

chmod 644 "$PLIST"

echo "[6/6] Starting agent..."
open "$APP_DIR" --args --config "$CONFIG" >/dev/null 2>&1 || true
sleep 3
pkill -f "$MACOS_DIR/MacCameraAgent" >/dev/null 2>&1 || true
launchctl bootstrap "gui/$(id -u)" "$PLIST" >/dev/null 2>&1 || launchctl load "$PLIST"
launchctl kickstart -k "gui/$(id -u)/com.remoteviewer.maccameraagent" >/dev/null 2>&1 || true

echo ""
echo "MacCameraAgent installed."
echo "Server: $SERVER_HOST:$SERVER_PORT"
echo "Config: $CONFIG"
echo "Logs:   $LOG_DIR/agent.log"
echo ""
echo "If macOS asks for camera permission, allow MacCameraAgent."
