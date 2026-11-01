#!/bin/zsh
# Run Jambul's unit tests and print one line per test.
set -uo pipefail
cd "${0:A:h}/.."

export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
log=$(mktemp)
xcodebuild -project Jambul.xcodeproj -scheme Jambul -destination "platform=macOS,arch=$(uname -m)" \
  -derivedDataPath build/DerivedData test >"$log" 2>&1
test_status=$?
# Compiler warnings show too: the build behind the tests is often the only one that compiles a change, so they'd go
# unseen otherwise. "Error Domain" lines are system log noise from the test host, not test failures.
grep -E "^[✔✘]|error:|^/.*: warning:|\*\* TEST" "$log" | grep -v "Error Domain"
if [[ $test_status -ne 0 ]]; then
  # On CI the log file can't be opened afterwards, so show its end.
  [[ -n ${CI:-} ]] && tail -n 80 "$log"
  echo "Full log: $log"
else
  rm -f "$log"
fi
exit $test_status
