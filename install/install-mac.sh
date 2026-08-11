#!/bin/bash
# Archie beta installer (macOS). Double-click won't work for .sh — run:
#   bash install/install-mac.sh
set -e
cd "$(dirname "$0")"

if ! command -v uv >/dev/null 2>&1; then
  echo "uv is required (fast Python manager). Install now? [y/N]"
  read -r yn
  if [ "$yn" = "y" ] || [ "$yn" = "Y" ]; then
    curl -LsSf https://astral.sh/uv/install.sh | sh
    export PATH="$HOME/.local/bin:$PATH"
  else
    echo "aborted — install uv first: curl -LsSf https://astral.sh/uv/install.sh | sh"
    exit 1
  fi
fi

if command -v python3 >/dev/null 2>&1; then
  python3 install.py
else
  uv run --no-project python install.py
fi
