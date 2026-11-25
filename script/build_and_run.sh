#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
APP_NAME="Veo"
BUNDLE_ID="com.ash.Veo"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DERIVED_DATA_DIR="${VEO_DERIVED_DATA_DIR:-/tmp/veo-derived}"
APP_BUNDLE="$DERIVED_DATA_DIR/Build/Products/Debug/$APP_NAME.app"
APP_BINARY="$APP_BUNDLE/Contents/MacOS/$APP_NAME"

if [[ "$MODE" != "build" && "$MODE" != "--build" ]]; then
  pkill -x "$APP_NAME" >/dev/null 2>&1 || true
fi

xcodebuild \
  -project "$ROOT_DIR/Veo.xcodeproj" \
  -scheme "$APP_NAME" \
  -configuration Debug \
  -derivedDataPath "$DERIVED_DATA_DIR" \
  build \
  CODE_SIGNING_ALLOWED=NO

open_app() {
  /usr/bin/open -n "$APP_BUNDLE"
}

case "$MODE" in
  --build|build)
    ;;
  run)
    open_app
    ;;
  --debug|debug)
    lldb -- "$APP_BINARY"
    ;;
  --logs|logs)
    open_app
    /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\""
    ;;
  --telemetry|telemetry)
    open_app
    /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\""
    ;;
  --verify|verify)
    open_app
    sleep 1
    pgrep -x "$APP_NAME" >/dev/null
    ;;
  *)
    echo "usage: $0 [run|--build|--debug|--logs|--telemetry|--verify]" >&2
    exit 2
    ;;
esac
