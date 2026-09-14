#!/usr/bin/env bash
# Every suite. The d3 package needs no deps; src/app links ImGui.
set -euo pipefail
cd "$(dirname "$0")"
odin test src/d3
odin test src/app
