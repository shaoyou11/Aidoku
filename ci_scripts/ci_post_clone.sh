#!/bin/sh
set -eu

# Apply unattended plugin validation only to Xcode Cloud's disposable runner.
case "${CI_XCODE_CLOUD:-}" in
  TRUE|true|1) ;;
  *) echo "Not Xcode Cloud; local plugin validation unchanged."; exit 0 ;;
esac
cd "${CI_PRIMARY_REPOSITORY_PATH:?}"
python3 - <<'PYTHON'
import hashlib
from pathlib import Path
lock = Path("Aidoku.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved")
expected = "4f720fb61f9fd1b1065a9c98adee9a9cad99c20216bbefcf623f33ef46259792"
if hashlib.sha256(lock.read_bytes()).hexdigest() != expected:
    raise SystemExit("Dependency lock changed: review plugins before updating the cloud build pin.")
print("Dependency lock verified for the reviewed SwiftLint plugin.")
PYTHON
# SwiftLint's documented CI setting; no setting on the user's Mac is changed.
defaults write com.apple.dt.Xcode IDESkipPackagePluginFingerprintValidatation -bool YES
