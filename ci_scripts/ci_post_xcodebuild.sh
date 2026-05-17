#!/bin/sh
#
# Xcode Cloud — post-xcodebuild script.
# Runs after xcodebuild (and tests, if the workflow runs them) finish.
#
# Currently a no-op placeholder. Hook things here when you have them:
#   - upload symbols to a crash reporter
#   - notify Slack/Discord on build status
#   - publish test result artifacts

set -euo pipefail

echo "✓ ci_post_xcodebuild: nothing to do"
