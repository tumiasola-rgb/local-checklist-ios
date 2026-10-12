#!/bin/bash
# Local verification only. Does not register devices, upload, or provision signing.
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ -z "${DEVELOPER_DIR:-}" ]] && [[ "$(xcode-select -p)" != *.app/Contents/Developer ]]; then
  for candidate in /Applications/Xcode.app /Applications/Xcode-*.app; do
    if [[ -d "$candidate/Contents/Developer" ]]; then
      export DEVELOPER_DIR="$candidate/Contents/Developer"
      break
    fi
  done
fi
xcodebuild -version
case "${1:-simulator}" in
  simulator)
    xcodebuild build -jobs 2 -project LocalChecklist.xcodeproj -scheme LocalChecklist-iPhone \
      -destination 'generic/platform=iOS Simulator' -derivedDataPath .build-check/iphone \
      CODE_SIGNING_ALLOWED=NO
    ;;
  device)
    xcodebuild build -jobs 2 -project LocalChecklist.xcodeproj -scheme LocalChecklist-iPhone \
      -configuration Release -destination 'generic/platform=iOS' \
      -derivedDataPath .build-check/iphone-device CODE_SIGNING_ALLOWED=NO
    ;;
  test)
    if [[ -z "${2:-}" ]]; then
      echo 'Usage: bash Scripts/verify_iphone.sh test SIMULATOR_ID' >&2
      exit 2
    fi
    xcodebuild test -jobs 2 -parallel-testing-enabled NO -project LocalChecklist.xcodeproj -scheme LocalChecklist-iPhone \
      -destination "platform=iOS Simulator,id=$2" -derivedDataPath .build-check/iphone \
      CODE_SIGNING_ALLOWED=NO
    ;;
  *) echo 'Usage: bash Scripts/verify_iphone.sh [simulator|device|test SIMULATOR_ID]' >&2; exit 2 ;;
esac
