#!/usr/bin/env bash
set -euo pipefail

echo "==> Building (fail on errors and warnings)..."
RUSTFLAGS="-D warnings" cargo build

echo "==> Running clippy (fail on errors and warnings)..."
cargo clippy -- -D warnings

echo "==> Running tests with coverage (fail if < 100%)..."
COVERAGE_OUTPUT="$(cargo llvm-cov --fail-under-lines 100 2>&1)" || {
  echo "$COVERAGE_OUTPUT"
  echo "ERROR: Test coverage is below 100% or tests failed"
  exit 1
}
echo "$COVERAGE_OUTPUT"

echo "==> Checking formatting..."
cargo fmt -- --check

echo "==> All checks passed!"
