#!/usr/bin/env bash
# Render every Excalidraw scene in this directory. Set EXCALIDRAW_BROWSER_PATH
# to a Chrome, Chromium, Edge, or Firefox binary before running.
set -euo pipefail

FIGURES="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
: "${EXCALIDRAW_BROWSER_PATH:?set EXCALIDRAW_BROWSER_PATH to a browser binary}"

cd "$FIGURES"
python3 -B generate.py

for scene in architecture import search deployment; do
  excalidraw render "${scene}.excalidraw" \
    --out "${scene}.png" \
    --scale 2 \
    --max-width 3200 \
    --browser-path "$EXCALIDRAW_BROWSER_PATH"
done
