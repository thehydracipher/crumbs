#!/bin/zsh
# Runs Crumbs' tests. Uses only fake files in a temporary folder (no password, nothing real is touched).
set -u
cd "${0:A:h}/.."
W=$(mktemp -d "${${TMPDIR:-/tmp}%/}/crumbs-tests.XXXXXX")
pass=0; fail=0
run() {   # run <name> <extra sources...>
  local name=$1; shift
  swiftc -O -swift-version 5 Sources/Scanner.swift "$@" "tests/$name/main.swift" -o "$W/$name" 2>&1 | grep error && { echo "BUILD FAILED: $name"; fail=$((fail+1)); return; }
  mkdir -p "$W/$name-work"
  HOME="$W/$name-work/home" "$W/$name" "$W/$name-work" > "$W/$name.log" 2>&1
  local p=$(grep -c '^PASS' "$W/$name.log"); local f=$(grep -c '^FAIL' "$W/$name.log")
  pass=$((pass+p)); fail=$((fail+f))
  echo "$name: $p passed, $f failed"; grep '^FAIL' "$W/$name.log"
  grep '^TRASHED:' "$W/$name.log" | sed 's/^TRASHED://' | while read -r t; do rm -rf "$t"; done   # clean test items out of the Trash
}
run safety
run admin Sources/Admin.swift
run scan
run update Sources/Admin.swift Sources/Updater.swift
rm -rf "$W"; for d in /private/var/tmp/crumbs.*(N) /private/var/tmp/crumbs-undo.*(N); do rmdir "$d"/* "$d" 2>/dev/null; done
echo "TOTAL: $pass passed, $fail failed"
[ $fail -eq 0 ]
