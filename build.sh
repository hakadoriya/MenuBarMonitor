#!/usr/bin/env bash
set -Eeuo pipefail

# LICENSE: https://github.com/hakadoriya/log.sh/blob/HEAD/LICENSE
# Common
if [ "${LOGSH_COLOR:-}" ] || [ -t 2 ] ; then LOGSH_COLOR=true; else LOGSH_COLOR=''; fi
_logshRFC3339() { date "+%Y-%m-%dT%H:%M:%S%z" | sed "s/\(..\)$/:\1/"; }
_logshCmd() { for a in "$@"; do if echo "${a:-}" | grep -Eq "[[:blank:]]"; then printf "'%s' " "${a:-}"; else printf "%s " "${a:-}"; fi; done | sed "s/ $//"; }
# Color
LogshDefault() { test "  ${LOGSH_LEVEL:-0}" -gt 000 || echo "$*" | awk "{print   \"$(_logshRFC3339) [${LOGSH_COLOR:+\\033[0;35m}  DEFAULT${LOGSH_COLOR:+\\033[0m}] \"\$0\"\"}" 1>&2; }
LogshDebug() { test "    ${LOGSH_LEVEL:-0}" -gt 100 || echo "$*" | awk "{print   \"$(_logshRFC3339) [${LOGSH_COLOR:+\\033[0;34m}    DEBUG${LOGSH_COLOR:+\\033[0m}] \"\$0\"\"}" 1>&2; }
LogshInfo() { test "     ${LOGSH_LEVEL:-0}" -gt 200 || echo "$*" | awk "{print   \"$(_logshRFC3339) [${LOGSH_COLOR:+\\033[0;32m}     INFO${LOGSH_COLOR:+\\033[0m}] \"\$0\"\"}" 1>&2; }
LogshNotice() { test "   ${LOGSH_LEVEL:-0}" -gt 300 || echo "$*" | awk "{print   \"$(_logshRFC3339) [${LOGSH_COLOR:+\\033[0;36m}   NOTICE${LOGSH_COLOR:+\\033[0m}] \"\$0\"\"}" 1>&2; }
LogshWarn() { test "     ${LOGSH_LEVEL:-0}" -gt 400 || echo "$*" | awk "{print   \"$(_logshRFC3339) [${LOGSH_COLOR:+\\033[0;33m}     WARN${LOGSH_COLOR:+\\033[0m}] \"\$0\"\"}" 1>&2; }
LogshWarning() { test "  ${LOGSH_LEVEL:-0}" -gt 400 || echo "$*" | awk "{print   \"$(_logshRFC3339) [${LOGSH_COLOR:+\\033[0;33m}  WARNING${LOGSH_COLOR:+\\033[0m}] \"\$0\"\"}" 1>&2; }
LogshError() { test "    ${LOGSH_LEVEL:-0}" -gt 500 || echo "$*" | awk "{print   \"$(_logshRFC3339) [${LOGSH_COLOR:+\\033[0;31m}    ERROR${LOGSH_COLOR:+\\033[0m}] \"\$0\"\"}" 1>&2; }
LogshExec() { LogshInfo "$ $(_logshCmd "$@")" && "$@"; }

if ! LogshExec cd "$(dirname "$0")"; then
  LogshError "Failed to change directory"
  exit 1
fi

APP_NAME="MenuBarMonitor"
APP_BUNDLE="${APP_NAME:?}.app"
BUILD_DIR="$(pwd -P)/.build/release"
APP_DIR="${BUILD_DIR:?}/${APP_BUNDLE:?}"

# Build for release
LogshExec swift build --configuration release

# Create necessary directories
LogshExec mkdir -p "${APP_DIR:?}/Contents/MacOS"
LogshExec mkdir -p "${APP_DIR:?}/Contents/Resources"

# Copy the executable
LogshExec cp -a "${BUILD_DIR:?}/${APP_NAME:?}" "${APP_DIR:?}/Contents/MacOS/"

# Create Info.plist
LogshExec tee "${APP_DIR:?}/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>${APP_NAME:?}</string>
    <key>CFBundleIdentifier</key>
    <string>com.example.${APP_NAME:?}</string>
    <key>CFBundleName</key>
    <string>${APP_NAME:?}</string>
    <key>CFBundleVersion</key>
    <string>1.0</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>LSUIElement</key>
    <true/>
    <key>SMLoginItem</key>
    <true/>
    <key>NSAppleEventsUsageDescription</key>
    <string>This application uses Apple Events to send commands to Terminal for displaying logs.</string>
</dict>
</plist>
EOF

# Show the build result in Finder
LogshExec open "${BUILD_DIR:?}"
