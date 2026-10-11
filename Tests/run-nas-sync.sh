#!/bin/bash
set -eu
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
NAS_TEST_DIR=$(mktemp -d /tmp/aidoku-nas-tests.XXXXXX)
NAS_MODEL_PATH="${1:-../Aidoku-build/Build/Products/Release-iphoneos/Aidoku.app/Aidoku.momd/0.9.mom}"
xcrun swiftc Aidoku/Core/Sync/NASSyncDocument.swift Tests/NASSync/main.swift -o "$NAS_TEST_DIR/merge"
"$NAS_TEST_DIR/merge"
xcrun swiftc -parse-as-library Aidoku/Core/Sync/NASSyncDocument.swift Aidoku/Core/Sync/NASWebDAVClient.swift Aidoku/Core/Sync/NASComicDirectory.swift Aidoku/Core/Sync/NASRequestRouter.swift Aidoku/Core/Sync/NASFolderListing.swift Tests/NASWebDAV/main.swift -o "$NAS_TEST_DIR/transport"
"$NAS_TEST_DIR/transport"
# The host harness replaces only UIKit import and private access. The database algorithm is unchanged.
python3 - "$NAS_TEST_DIR/Manager.swift" <<'PY'
from pathlib import Path
import sys
source = Path('Aidoku/Core/Sync/NASSyncManager.swift').read_text()
source = source.replace('import UIKit', 'import Foundation\nimport Combine')
source = source.replace('nonisolated private func snapshot', 'nonisolated func snapshot')
source = source.replace('nonisolated private func apply', 'nonisolated func apply')
Path(sys.argv[1]).write_text(source)
PY
xcrun swiftc -parse-as-library Aidoku/Core/Sync/NASSyncDocument.swift Aidoku/Core/Sync/NASWebDAVClient.swift Aidoku/Core/Sync/NASComicDirectory.swift Aidoku/Core/Sync/NASRequestRouter.swift Aidoku/Core/Sync/NASFolderListing.swift "$NAS_TEST_DIR/Manager.swift" Aidoku/Core/Database/Objects/LibraryMangaObject.swift Aidoku/Core/Database/Objects/HistoryObject.swift Tests/NASDatabase/Stubs.swift Tests/NASDatabase/main.swift -o "$NAS_TEST_DIR/database"
"$NAS_TEST_DIR/database" "$NAS_MODEL_PATH"

xcrun swiftc Aidoku/Core/Sync/NASSyncDocument.swift Aidoku/Core/Sync/NASWebDAVClient.swift Aidoku/Core/Sync/NASComicDirectory.swift Aidoku/Core/Sync/NASRequestRouter.swift Aidoku/Core/Sync/NASFolderListing.swift Tests/NASFolders/main.swift -o "$NAS_TEST_DIR/folders"
"$NAS_TEST_DIR/folders"

xcrun swiftc -parse-as-library Aidoku/Core/Sync/NASSyncDocument.swift Aidoku/Core/Sync/NASWebDAVClient.swift Aidoku/Core/Sync/NASFolderListing.swift Aidoku/Core/Sync/NASComicDirectory.swift Aidoku/Core/Sync/NASRequestRouter.swift Aidoku/Core/Sync/NASComicClient.swift Tests/NASComics/main.swift -o "$NAS_TEST_DIR/comics"
"$NAS_TEST_DIR/comics"

NAS_ZIP_PACKAGE="${NAS_ZIP_PACKAGE:-../Aidoku-build/SourcePackages/checkouts/ZIPFoundation/Sources/ZIPFoundation}"
if [ ! -d "$NAS_ZIP_PACKAGE" ]; then
    for candidate in "$HOME"/Library/Developer/Xcode/DerivedData/Aidoku-*/SourcePackages/checkouts/ZIPFoundation/Sources/ZIPFoundation; do
        if [ -d "$candidate" ]; then NAS_ZIP_PACKAGE="$candidate"; break; fi
    done
fi
if [ -d "$NAS_ZIP_PACKAGE" ]; then
    bash Tests/NASOnline/run.sh "$NAS_ZIP_PACKAGE"
else
    echo "ZIPFoundation sources missing: set NAS_ZIP_PACKAGE to run online ZIP/Range checks" >&2
    exit 1
fi

xcrun swiftc Aidoku/Core/Library/Models/MangaIdentifier.swift Aidoku/Core/Privacy/PrivacyDisplayPolicy.swift Tests/Privacy/main.swift -o "$NAS_TEST_DIR/privacy"
"$NAS_TEST_DIR/privacy"
