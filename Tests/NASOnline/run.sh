#!/bin/bash
set -eu
cd "$(dirname "$0")/../.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
NAS_ONLINE_TEST_DIR=$(mktemp -d /tmp/aidoku-nas-online.XXXXXX)
NAS_ZIP_SOURCES="${1:-../Aidoku-build/SourcePackages/checkouts/ZIPFoundation/Sources/ZIPFoundation}"
python3 Tests/NASOnline/fixtures.py "$NAS_ONLINE_TEST_DIR"
xcrun swiftc -emit-library -emit-module -module-name ZIPFoundation "$NAS_ZIP_SOURCES"/*.swift -o "$NAS_ONLINE_TEST_DIR/libZIPFoundation.dylib" -emit-module-path "$NAS_ONLINE_TEST_DIR/ZIPFoundation.swiftmodule"
xcrun swiftc -parse-as-library -I "$NAS_ONLINE_TEST_DIR" -L "$NAS_ONLINE_TEST_DIR" -lZIPFoundation \
  -Xlinker -rpath -Xlinker "$NAS_ONLINE_TEST_DIR" \
  Aidoku/Core/Sync/NASSyncDocument.swift Aidoku/Core/Sync/NASWebDAVClient.swift \
  Aidoku/Core/Sync/NASFolderListing.swift Aidoku/Core/Sync/NASComicDirectory.swift \
  Aidoku/Core/Sync/NASRequestRouter.swift Aidoku/Core/Sync/NASComicClient.swift \
  Aidoku/Core/Sync/NASZIPIndex.swift "$NAS_ONLINE_TEST_DIR/Decode.swift" Tests/NASOnline/main.swift \
  -o "$NAS_ONLINE_TEST_DIR/online"
"$NAS_ONLINE_TEST_DIR/online" "$NAS_ONLINE_TEST_DIR"
