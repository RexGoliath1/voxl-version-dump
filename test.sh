#!/bin/sh
# Run voxl_version_dump.sh inside each test container and validate output.
# Usage: sh test.sh

set -e
PASS=0
FAIL=0

run_test() {
  name=$1
  dockerfile=$2
  image="voxl-dump-test-$(echo "$name" | tr '[:upper:]' '[:lower:]')"
  outfile="output_${name}.txt"

  echo ""
  echo "=== $name ==="
  docker build -f "$dockerfile" -t "$image" . -q
  docker run --rm "$image" > "$outfile" 2>&1

  lines=$(wc -l < "$outfile" | tr -d ' ')
  echo "  lines: $lines"

  # validate expected section headers are present
  failed=0
  for section in "DEVICE IDENTITY" "VOXL / MODALAI" "GIT REPOS" "DOCKER" \
                 "RUNNING SERVICES" "FULL PROCESS LIST" "NETWORK INTERFACES" \
                 "ACTIVE NETWORK" "MPA PIPES" "KEY BINARY FINGERPRINTS" \
                 "DUMP COMPLETE"; do
    if grep -q "$section" "$outfile"; then
      printf "  [ok] %s\n" "$section"
    else
      printf "  [MISSING] %s\n" "$section"
      failed=1
    fi
  done

  if [ $failed -eq 0 ]; then
    echo "  RESULT: PASS"
    PASS=$((PASS + 1))
  else
    echo "  RESULT: FAIL"
    FAIL=$((FAIL + 1))
  fi
}

run_test "bionic" "docker/Dockerfile.bionic"
run_test "noble"  "docker/Dockerfile.noble"

echo ""
echo "================================"
echo "Results: $PASS passed, $FAIL failed"
[ $FAIL -eq 0 ]
