#!/bin/bash
# Run only on a Mac with Xcode. No result from this script has been claimed on Linux.
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ "$(uname -s)" != Darwin ]] || ! command -v xcodebuild >/dev/null; then
  echo 'NOT RUN: Native iOS/Mac verification requires macOS with Xcode.' >&2
  exit 2
fi
python3 Scripts/verify_static.py
xcodebuild -version
xcodebuild -list -project LocalChecklist.xcodeproj
xcodebuild build -project LocalChecklist.xcodeproj -scheme LocalChecklist \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath .build-check/ios CODE_SIGNING_ALLOWED=NO
xcodebuild build -project LocalChecklist.xcodeproj -scheme LocalChecklist-Mac \
  -destination 'platform=macOS,variant=Mac Catalyst' \
  -derivedDataPath .build-check/mac CODE_SIGNING_ALLOWED=NO
if [[ $# -eq 0 ]]; then
  echo 'Build finished. Tests NOT RUN: provide a real simulator ID as first argument.'
  xcodebuild -showdestinations -project LocalChecklist.xcodeproj -scheme LocalChecklist
else
  xcodebuild test -project LocalChecklist.xcodeproj -scheme LocalChecklist \
    -destination "platform=iOS Simulator,id=$1" -derivedDataPath .build-check/ios
fi
