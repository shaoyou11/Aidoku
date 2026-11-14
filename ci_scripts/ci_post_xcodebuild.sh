#!/bin/sh
set -eu
case "${CI_XCODE_CLOUD:-}" in TRUE|true|1) ;; *) exit 0 ;; esac
[ "${CI_XCODEBUILD_ACTION:-}" = archive ] || exit 0
[ "${CI_XCODEBUILD_EXIT_CODE:-0}" = 0 ] || exit 0
cd "${CI_PRIMARY_REPOSITORY_PATH:?}"
python3 scripts/check_customizations.py
python3 Tests/LibraryRefresh/run.py
bash Tests/SourceURLs/run.sh
python3 scripts/test_icloud_safety.py
export NAS_ZIP_PACKAGE="${CI_DERIVED_DATA_PATH:?}/SourcePackages/checkouts/ZIPFoundation/Sources/ZIPFoundation"
export NAS_NUKE_PACKAGE="${CI_DERIVED_DATA_PATH:?}/SourcePackages/checkouts/Nuke"
bash Tests/run-nas-sync.sh "${CI_ARCHIVE_PATH:?}/Products/Applications/Aidoku.app/Aidoku.momd/0.9.mom"
echo 'AidokuT customizations and NAS/iCloud regression passed before TestFlight distribution.'
