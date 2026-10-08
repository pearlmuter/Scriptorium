#!/bin/bash
# Rebuilds and relaunches the app with the debug control channel enabled.
set -e
cd "$(dirname "$0")/.."
bash Scripts/build_app.sh | tail -1
pkill -x Transcriptaze || true
sleep 1
open --env TRANSCRIPTAZE_DEBUG=1 build/Transcriptaze.app
for i in $(seq 1 40); do curl -s -m 1 http://127.0.0.1:7337/debug/state >/dev/null && break; sleep 0.5; done
