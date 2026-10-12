#!/bin/bash
set -eu
cd "$(dirname "$0")/../.."
NAS_READER_TEST_DIR=$(mktemp -d /tmp/aidoku-nas-reader.XXXXXX)
# Compile the actual reader routing; only the iOS-only dependencies are replaced by minimal host doubles.
sed '/^import AidokuRunner$/d' Aidoku/Features/Reader/Readers/Paged/ReaderPagedViewModel.swift > "$NAS_READER_TEST_DIR/Reader.swift"
xcrun swiftc -parse-as-library Tests/NASReader/Stubs.swift "$NAS_READER_TEST_DIR/Reader.swift" Tests/NASReader/main.swift -o "$NAS_READER_TEST_DIR/reader"
"$NAS_READER_TEST_DIR/reader"
