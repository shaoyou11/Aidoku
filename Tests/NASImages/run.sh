#!/bin/bash
set -eu
cd "$(dirname "$0")/../.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
NAS_IMAGE_DIR=$(mktemp -d /tmp/aidoku-nas-images.XXXXXX)
NAS_NUKE_PACKAGE="${1:-../Aidoku-build/SourcePackages/checkouts/Nuke}"
python3 Tests/NASImages/generate.py "$NAS_IMAGE_DIR" "$NAS_NUKE_PACKAGE"
xcrun swift run --package-path "$NAS_IMAGE_DIR" Check
