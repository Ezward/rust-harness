#!/usr/bin/env bash
set -euo pipefail

# ── Argument validation ──────────────────────────────────────────────────────
if [ $# -ne 1 ]; then
  echo "Usage: $0 <owner/repo>"
  echo "  e.g. $0 myuser/my-rust-project"
  exit 1
fi

REPO_NAME="$1"

if [[ "$REPO_NAME" != */* ]]; then
  echo "Error: repository name must be in 'owner/repo' format (e.g. myuser/my-rust-project)"
  echo "       Got: $REPO_NAME"
  exit 1
fi
PROJECT_DIR="$(pwd)"
TOOLS_DIR="$PROJECT_DIR/tools"

# ── Ask for GitHub fine-grained access token ─────────────────────────────────
if [ -n "${GH_TOKEN:-}" ]; then
  echo "==> Using GH_TOKEN from environment."
else
  read -rsp "Enter your GitHub fine-grained access token: " GH_TOKEN
  echo
  if [ -z "$GH_TOKEN" ]; then
    echo "Error: token cannot be empty"
    exit 1
  fi
  export GH_TOKEN
fi
export GITHUB_TOKEN="$GH_TOKEN"

# ── Initialize git ───────────────────────────────────────────────────────────
if [ -d "$PROJECT_DIR/.git" ]; then
  echo "==> Git repository already initialized, skipping."
else
  echo "==> Initializing git repository..."
  git init
  git checkout -b main 2>/dev/null || git switch -c main 2>/dev/null || true
fi

# ── Create tools folder and install gh CLI ───────────────────────────────────
echo "==> Setting up tools directory..."
mkdir -p "$TOOLS_DIR"

if command -v gh &>/dev/null; then
  GH_CMD="$(command -v gh)"
  echo "==> GitHub CLI already available at: $GH_CMD"
elif [ -f "$TOOLS_DIR/gh" ]; then
  GH_CMD="$TOOLS_DIR/gh"
  echo "==> GitHub CLI already installed at: $GH_CMD"
else
  echo "==> Installing GitHub CLI into tools/..."
  OS="$(uname -s | tr '[:upper:]' '[:lower:]')"
  ARCH="$(uname -m)"
  case "$ARCH" in
    x86_64) ARCH="amd64" ;;
    aarch64|arm64) ARCH="arm64" ;;
  esac
  GH_VERSION="$(curl -sL https://api.github.com/repos/cli/cli/releases/latest | grep tag_name | head -1 | sed 's/.*"v\(.*\)".*/\1/')"
  GH_ARCHIVE="gh_${GH_VERSION}_${OS}_${ARCH}.tar.gz"
  curl -sL "https://github.com/cli/cli/releases/download/v${GH_VERSION}/${GH_ARCHIVE}" -o "/tmp/${GH_ARCHIVE}"
  tar -xzf "/tmp/${GH_ARCHIVE}" -C /tmp
  cp "/tmp/gh_${GH_VERSION}_${OS}_${ARCH}/bin/gh" "$TOOLS_DIR/gh"
  chmod +x "$TOOLS_DIR/gh"
  rm -rf "/tmp/${GH_ARCHIVE}" "/tmp/gh_${GH_VERSION}_${OS}_${ARCH}"
  GH_CMD="$TOOLS_DIR/gh"
  echo "==> GitHub CLI installed at: $GH_CMD"
fi

# GH_TOKEN env var is used directly by gh for authentication

# ── Initialize Cargo project ─────────────────────────────────────────────────
if [ -f "$PROJECT_DIR/Cargo.toml" ]; then
  echo "==> Cargo project already initialized, skipping."
else
  echo "==> Initializing Cargo project..."
  cargo init --name "$(basename "$PROJECT_DIR")"

  # Replace default main.rs with a testable version for 100% coverage
  cat > "$PROJECT_DIR/src/main.rs" <<'MAINRS'
fn run() -> String {
    "Hello, world!".to_string()
}

#[cfg(not(coverage))]
fn main() {
    println!("{}", run());
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_run() {
        assert_eq!(run(), "Hello, world!");
    }
}
MAINRS

  # Allow the coverage cfg used by cargo-llvm-cov
  cat >> "$PROJECT_DIR/Cargo.toml" <<'CARGOCFG'

[lints.rust]
unexpected_cfgs = { level = "warn", check-cfg = ['cfg(coverage)'] }
CARGOCFG
fi

# ── Rust toolchain setup ─────────────────────────────────────────────────────
echo "==> Ensuring Rust stable toolchain..."
rustup default stable
rustup update stable

echo "==> Ensuring clippy is installed..."
rustup component add clippy

if cargo llvm-cov --version &>/dev/null; then
  echo "==> cargo-llvm-cov already installed."
else
  echo "==> Installing cargo-llvm-cov..."
  cargo install cargo-llvm-cov
fi

echo "==> Ensuring cross-compilation targets..."
rustup target add x86_64-unknown-linux-gnu
rustup target add aarch64-unknown-linux-gnu

# ── Cargo format configuration (120 char line length) ────────────────────────
if [ -f "$PROJECT_DIR/rustfmt.toml" ]; then
  echo "==> rustfmt.toml already exists, skipping."
else
  echo "==> Creating rustfmt.toml..."
  cat > "$PROJECT_DIR/rustfmt.toml" <<'RUSTFMT'
max_width = 120
RUSTFMT
fi

# ── Create scripts/check.sh ─────────────────────────────────────────────────
if [ -f "$PROJECT_DIR/scripts/check.sh" ]; then
  echo "==> scripts/check.sh already exists, skipping."
else
  echo "==> Creating scripts/check.sh..."
  cat > "$PROJECT_DIR/scripts/check.sh" <<'CHECKSH'
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
CHECKSH
  chmod +x "$PROJECT_DIR/scripts/check.sh"
fi

# ── .gitignore ───────────────────────────────────────────────────────────────
if [ -f "$PROJECT_DIR/.gitignore" ]; then
  echo "==> .gitignore already exists, skipping."
else
  echo "==> Creating .gitignore..."
  cat > "$PROJECT_DIR/.gitignore" <<'GITIGNORE'
# Rust / Cargo
/target/
**/*.rs.bk
Cargo.lock

# IDE
.idea/
.vscode/
*.swp
*.swo
*~

# OS
.DS_Store
Thumbs.db

# Tools (local installs)
/tools/

# Environment
.env
GITIGNORE
fi

# ── README.md ────────────────────────────────────────────────────────────────
if [ -f "$PROJECT_DIR/README.md" ]; then
  echo "==> README.md already exists, skipping."
else
  echo "==> Creating README.md..."
  REPO_BASENAME="$(basename "$REPO_NAME")"
  cat > "$PROJECT_DIR/README.md" <<README
# $REPO_BASENAME

A Rust project initialized with the claude-code harness.

## Development

### Prerequisites
- Rust (stable)
- cargo-llvm-cov

### Running checks
\`\`\`bash
./scripts/check.sh
\`\`\`

This runs:
- Compilation (fail on warnings)
- Clippy linting (fail on warnings)
- Test coverage (must be 100%)
- Format checking
README
fi

# ── Git pre-commit hook ──────────────────────────────────────────────────────
if [ -f "$PROJECT_DIR/.git/hooks/pre-commit" ]; then
  echo "==> Git pre-commit hook already exists, skipping."
else
  echo "==> Creating git pre-commit hook..."
  mkdir -p "$PROJECT_DIR/.git/hooks"
  cat > "$PROJECT_DIR/.git/hooks/pre-commit" <<'HOOK'
#!/usr/bin/env bash
set -euo pipefail
echo "Running pre-commit checks..."
exec "$(git rev-parse --show-toplevel)/scripts/check.sh"
HOOK
  chmod +x "$PROJECT_DIR/.git/hooks/pre-commit"
fi

# ── GitHub Actions workflow ──────────────────────────────────────────────────
if [ -f "$PROJECT_DIR/.github/workflows/ci.yml" ]; then
  echo "==> GitHub Actions CI workflow already exists, skipping."
else
  echo "==> Creating GitHub Actions CI workflow..."
  mkdir -p "$PROJECT_DIR/.github/workflows"
  cat > "$PROJECT_DIR/.github/workflows/ci.yml" <<'CIWORKFLOW'
name: CI

on:
  pull_request:
    branches: [main]

jobs:
  check:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Install Rust stable
        uses: dtolnay/rust-toolchain@stable
        with:
          components: clippy, rustfmt, llvm-tools-preview

      - name: Install cargo-llvm-cov
        uses: taiki-e/install-action@cargo-llvm-cov

      - name: Run checks
        run: ./scripts/check.sh
CIWORKFLOW
fi

# ── Claude Code hooks ────────────────────────────────────────────────────────
if [ -f "$PROJECT_DIR/.claude/settings.json" ]; then
  echo "==> Claude Code hooks configuration already exists, skipping."
else
  echo "==> Creating Claude Code hooks configuration..."
  mkdir -p "$PROJECT_DIR/.claude"
  cat > "$PROJECT_DIR/.claude/settings.json" <<'CLAUDESETTINGS'
{
  "hooks": {
    "PostToolUse": [
      {
        "matcher": "Edit|Write",
        "hooks": [
          {
            "type": "command",
            "command": "changed_files=$(git diff --name-only HEAD 2>/dev/null; git diff --name-only --cached 2>/dev/null; git ls-files --others --exclude-standard 2>/dev/null); if echo \"$changed_files\" | grep -q '\\.rs$'; then ./scripts/check.sh 2>&1; fi"
          }
        ]
      }
    ],
    "PreToolUse": [
      {
        "matcher": "Edit|Write",
        "hooks": [
          {
            "type": "command",
            "command": "if echo \"$TOOL_INPUT\" | grep -q '.git/hooks'; then echo '{\"decision\": \"block\", \"reason\": \"Modifications to .git/hooks are not allowed\"}'; fi"
          }
        ]
      }
    ],
    "SessionStart": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "echo 'Please provide your GitHub fine-grained access token to enable GitHub access for this session.' && read -rsp 'GitHub Token: ' token && echo && export GH_TOKEN=\"$token\" && export GITHUB_TOKEN=\"$token\" && echo \"$token\" | gh auth login --with-token 2>/dev/null && echo 'GitHub authenticated successfully.'"
          }
        ]
      }
    ],
    "SessionEnd": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "unset GH_TOKEN && unset GITHUB_TOKEN && gh auth logout --hostname github.com 2>/dev/null; echo 'GitHub token cleared.'"
          }
        ]
      }
    ]
  }
}
CLAUDESETTINGS
fi

# ── .file-guard to protect .git/hooks and scripts ────────────────────────────
if [ -f "$PROJECT_DIR/.file-guard" ]; then
  echo "==> .file-guard already exists, skipping."
else
  echo "==> Creating .file-guard to protect .git/hooks and scripts..."
  cat > "$PROJECT_DIR/.file-guard" <<'FILEGUARD'
.git/hooks
scripts/init.sh
scripts/check.sh
scripts/verify-repo-security.sh
FILEGUARD
fi

# ── Initial commit ───────────────────────────────────────────────────────────
if git log --oneline -1 &>/dev/null; then
  echo "==> Git history already exists, skipping initial commit."
else
  echo "==> Creating initial commit..."
  git add -A
  git commit -m "Initial project setup with Rust harness

- Cargo project with stable toolchain
- clippy, cargo-llvm-cov, rustfmt configured
- Cross-compilation targets (x86_64 + aarch64 linux-gnu)
- scripts/check.sh: build, lint, coverage, format checks
- Git pre-commit hook running check.sh
- GitHub Actions CI workflow for PRs
- Claude Code hooks for automated checks and GitHub auth
- .file-guard protecting .git/hooks"
fi

# ── Connect to origin and push ───────────────────────────────────────────────
if git remote get-url origin &>/dev/null; then
  echo "==> Origin remote already configured, skipping."
else
  echo "==> Connecting to origin: $REPO_NAME..."
  git remote add origin "https://github.com/${REPO_NAME}.git"
fi

if git rev-parse --verify origin/main &>/dev/null; then
  echo "==> Main branch already pushed to origin, skipping push."
else
  echo "==> Pushing to origin..."
  git push -u origin main
fi

# ── Verify branch protections ────────────────────────────────────────────────
"$PROJECT_DIR/scripts/verify-repo-security.sh" "$REPO_NAME"

echo ""
echo "==> Initialization complete! Repository is ready for development."
