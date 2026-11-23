#!/bin/bash
# Development loop: builds, launches the app with the chat window open, then
# relaunches it every time a new build lands. Leave it running in a terminal.
#
# Swift has no true hot reload, so this is the next best thing: after each
# `./scripts/build-app.sh` the app restarts on its own and reopens the
# conversation that was on screen.
set -euo pipefail

cd "$(dirname "$0")/.."

APP="build/Tachyon AI.app"
BIN="$APP/Contents/MacOS/TachyonAI"

launch() {
    pkill -x TachyonAI 2>/dev/null || true
    # Wait for the old instance to exit; `open` would otherwise just activate it.
    while pgrep -x TachyonAI >/dev/null; do sleep 0.1; done
    # `open` can fail for a moment right after the old instance exits or while the
    # bundle is being replaced, so try a few times instead of giving up.
    for attempt in 1 2 3 4 5 6; do
        if open "$APP" --args --chat 2>/dev/null; then
            echo "$(date +%T) launched"
            return
        fi
        sleep 0.5
    done
    echo "$(date +%T) could not launch; will retry on the next build"
}

stamp() {
    stat -f %m "$BIN" 2>/dev/null || echo 0
}

./scripts/build-app.sh
launch
last="$(stamp)"

echo "Watching for new builds. Press Ctrl-C to stop."
while sleep 0.5; do
    now="$(stamp)"
    [ "$now" = "$last" ] && continue
    # The bundle is rebuilt in steps; relaunch only once it is complete and signed.
    codesign --verify "$APP" 2>/dev/null || continue
    # Two builds in a row: wait until the bundle has stopped changing.
    sleep 0.5
    [ "$(stamp)" = "$now" ] || continue
    last="$now"
    launch
done
