#!/bin/zsh
# Dev launch: wrap the release binary into .build/StudioAudioLane.app and open it.
# To install into /Applications, use scripts/install.sh.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
"$ROOT/scripts/bundle.sh"
open "$ROOT/.build/StudioAudioLane.app"
