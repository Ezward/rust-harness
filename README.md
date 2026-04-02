# rust-harness

A Rust project initialized with the claude-code harness.

## Development

### Prerequisites
- Rust (stable)
- cargo-llvm-cov

### Running checks
```bash
./scripts/check.sh
```

This runs:
- Compilation (fail on warnings)
- Clippy linting (fail on warnings)
- Test coverage (must be 100%)
- Format checking
