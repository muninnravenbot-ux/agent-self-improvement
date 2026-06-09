#!/bin/bash
# src/smoke-test.sh — Stage 4: real smoke test using the actual build tool.
#
# Runs BUILD_CMD in the given directory. Returns 0 + "PASS" on success, 1 + error on failure.
#
# CRITICAL: this is the REAL build tool, not `tsc --noEmit` or `npm list`. Examples:
#   - bun build src/main.ts --target=bun --outfile=/dev/null
#   - npm run build -- --dry-run
#   - cargo check
#   - go build ./...
#
# Usage: smoke-test.sh <test-dir>
# Env: BUILD_CMD

set -uo pipefail

test_dir="${1:-.}"
BUILD_CMD="${BUILD_CMD:-bun build src/main.ts --target=bun --outfile=/dev/null}"

# Ensure node_modules are available (link if needed).
if [ -d "../node_modules" ] && [ ! -d "$test_dir/node_modules" ]; then
  ln -s "$(cd "$test_dir/.." && pwd)/node_modules" "$test_dir/node_modules" 2>/dev/null || true
fi

# Run the build.
cd "$test_dir" || exit 1
output=$(eval "$BUILD_CMD" 2>&1)
rc=$?

if [ "$rc" -eq 0 ] && ! echo "$output" | grep -qiE "error:|failed|cannot find"; then
  echo "PASS"
  exit 0
else
  echo "FAIL"
  echo "$output" | tail -20
  exit 1
fi
