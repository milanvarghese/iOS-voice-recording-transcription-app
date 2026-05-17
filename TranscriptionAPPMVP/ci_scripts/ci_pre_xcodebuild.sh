#!/bin/sh
#
# Xcode Cloud — pre-xcodebuild script.
# Runs after dependencies resolve, right before xcodebuild starts.
#
# Use this for last-minute sanity checks. Today it just verifies Config.swift
# exists (i.e. that ci_post_clone.sh did its job).

set -euo pipefail

REPO_ROOT="${CI_PRIMARY_REPOSITORY_PATH:-$(cd "$(dirname "$0")/.." && pwd)}"
CONFIG_PATH="$REPO_ROOT/TranscriptionAPPMVP/TranscriptionAPPMVP/Config.swift"

if [ ! -f "$CONFIG_PATH" ]; then
  echo "❌ Config.swift missing. Did ci_post_clone.sh run successfully?"
  exit 1
fi

echo "✓ Config.swift present, proceeding to xcodebuild"
