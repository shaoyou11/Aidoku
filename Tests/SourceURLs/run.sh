#!/bin/bash
set -eu
cd "$(dirname "$0")/../.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
SOURCE_URL_TEST_DIR=$(mktemp -d /tmp/aidoku-source-url-tests.XXXXXX)
python3 - "$SOURCE_URL_TEST_DIR" <<'PYTHON'
from pathlib import Path
import sys
out = Path(sys.argv[1])
source = Path('Aidoku/Core/Sources/SourceList/ExternalSourceInfo.swift').read_text()
# Only external dependency types are stubbed; URL accessors are the production implementation.
source = source.replace('import AidokuRunner', '').replace('AidokuRunner.SourceContentRating', 'SourceContentRating')
manager = Path('Aidoku/Core/Sources/SourceManager.swift').read_text()
line = next(line.strip() for line in manager.splitlines() if line.strip().startswith('let sourceBaseURL = '))
assert 'externalSources[index].sourceUrl = sourceBaseURL' in manager
source += '\nfunc normalizeLegacyBase(_ url: URL) -> URL {\n    ' + line + '\n    return sourceBaseURL\n}\n'
(out / 'ExternalSourceInfo.swift').write_text(source)
PYTHON
xcrun swiftc -parse-as-library "$SOURCE_URL_TEST_DIR/ExternalSourceInfo.swift" Tests/SourceURLs/main.swift -o "$SOURCE_URL_TEST_DIR/source-urls"
"$SOURCE_URL_TEST_DIR/source-urls"
