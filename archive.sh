#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
: "${APPLE_TEAM_ID:?Define APPLE_TEAM_ID con tu equipo Apple Developer antes de archivar.}"
xcodebuild -project IGSaverPro.xcodeproj -scheme IGSaverPro \
  -configuration Release -destination 'generic/platform=iOS' \
  -archivePath build/IGSaverPro.xcarchive \
  DEVELOPMENT_TEAM="$APPLE_TEAM_ID" -allowProvisioningUpdates archive
