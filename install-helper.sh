#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ -x "$script_dir/setup/center-anchor" ]]; then
  "$script_dir/setup/center-anchor"
fi

if [[ -x "$script_dir/setup/sync-timer" ]]; then
  "$script_dir/setup/sync-timer"
fi
