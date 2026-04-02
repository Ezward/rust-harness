#!/usr/bin/env bash
set -euo pipefail

# ── Argument validation ──────────────────────────────────────────────────────
if [ $# -ne 1 ]; then
  echo "Usage: $0 <github-repo-name>"
  echo "  e.g. $0 myuser/my-rust-project"
  exit 1
fi

REPO_NAME="$1"
PROJECT_DIR="$(pwd)"
TOOLS_DIR="$PROJECT_DIR/tools"

# ── Ask for GitHub fine-grained access token ─────────────────────────────────
read -rsp "Enter your GitHub fine-grained access token: " GH_TOKEN
echo
if [ -z "$GH_TOKEN" ]; then
  echo "Error: token cannot be empty"
  exit 1
fi

export GH_TOKEN
export GITHUB_TOKEN="$GH_TOKEN"

# ── Initialize git ───────────────────────────────────────────────────────────
echo "==> Initializing git repository..."
git init
git checkout -b main 2>/dev/null || git switch -c main 2>/dev/null || true

# ── Create tools folder and install gh CLI ───────────────────────────────────
echo "==> Setting up tools directory..."
mkdir -p "$TOOLS_DIR"

if ! command -v gh &>/dev/null && [ ! -f "$TOOLS_DIR/gh" ]; then
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
else
  GH_CMD="$(command -v gh 2>/dev/null || echo "$TOOLS_DIR/gh")"
fi

echo "==> Using gh at: $GH_CMD"
# GH_TOKEN env var is used directly by gh for authentication

# ── Initialize Cargo project ─────────────────────────────────────────────────
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

# ── Rust toolchain setup ─────────────────────────────────────────────────────
echo "==> Setting up Rust stable toolchain..."
rustup default stable
rustup update stable

echo "==> Installing clippy..."
rustup component add clippy

echo "==> Installing cargo-llvm-cov..."
cargo install cargo-llvm-cov

echo "==> Installing cross-compilation targets..."
rustup target add x86_64-unknown-linux-gnu
rustup target add aarch64-unknown-linux-gnu

# ── Cargo format configuration (120 char line length) ────────────────────────
echo "==> Creating rustfmt.toml..."
cat > "$PROJECT_DIR/rustfmt.toml" <<'RUSTFMT'
max_width = 120
RUSTFMT

# ── Create scripts/check.sh ─────────────────────────────────────────────────
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

# ── .gitignore ───────────────────────────────────────────────────────────────
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

# ── README.md ────────────────────────────────────────────────────────────────
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

# ── Git pre-commit hook ──────────────────────────────────────────────────────
echo "==> Creating git pre-commit hook..."
mkdir -p "$PROJECT_DIR/.git/hooks"
cat > "$PROJECT_DIR/.git/hooks/pre-commit" <<'HOOK'
#!/usr/bin/env bash
set -euo pipefail
echo "Running pre-commit checks..."
exec "$(git rev-parse --show-toplevel)/scripts/check.sh"
HOOK
chmod +x "$PROJECT_DIR/.git/hooks/pre-commit"

# ── GitHub Actions workflow ──────────────────────────────────────────────────
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

# ── Claude Code hooks ────────────────────────────────────────────────────────
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

# ── .file-guard to protect .git/hooks ────────────────────────────────────────
echo "==> Creating .file-guard to protect .git/hooks..."
cat > "$PROJECT_DIR/.file-guard" <<'FILEGUARD'
.git/hooks
FILEGUARD

# ── Initial commit ───────────────────────────────────────────────────────────
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

# ── Connect to origin and push ───────────────────────────────────────────────
echo "==> Connecting to origin: $REPO_NAME..."
git remote add origin "https://github.com/${REPO_NAME}.git"
git push -u origin main

# ── Wait for push to complete and verify branch protections ──────────────────
echo "==> Verifying GitHub repository branch protections..."
echo "    Checking that 'main' branch has the required protections..."

PROTECTION_ERRORS=()

# Fetch branch protection rules
PROTECTION=$("$GH_CMD" api "repos/${REPO_NAME}/branches/main/protection" 2>&1) || {
  echo "ERROR: Could not fetch branch protection rules for 'main'."
  echo "       Please ensure branch protection is configured on GitHub."
  echo "       Response: $PROTECTION"
  exit 1
}

# Check: Restrict creations/updates/deletions (enforce_admins or restrictions)
if echo "$PROTECTION" | python3 -c "import sys,json; d=json.load(sys.stdin); assert d.get('enforce_admins',{}).get('enabled', False)" 2>/dev/null; then
  echo "    [OK] Admin enforcement is enabled"
else
  PROTECTION_ERRORS+=("Enforce admins (restrict creations/updates/deletions) is NOT enabled")
fi

# Check: Require pull request before merging
PR_REVIEWS=$(echo "$PROTECTION" | python3 -c "import sys,json; d=json.load(sys.stdin); pr=d.get('required_pull_request_reviews'); print('yes' if pr else 'no')" 2>/dev/null)
if [ "$PR_REVIEWS" = "yes" ]; then
  echo "    [OK] Pull request reviews are required"
else
  PROTECTION_ERRORS+=("Require a pull request before merging is NOT configured")
fi

# Check: Require at least one approval
APPROVAL_COUNT=$(echo "$PROTECTION" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('required_pull_request_reviews',{}).get('required_approving_review_count',0))" 2>/dev/null)
if [ "$APPROVAL_COUNT" -ge 1 ] 2>/dev/null; then
  echo "    [OK] At least $APPROVAL_COUNT approval(s) required"
else
  PROTECTION_ERRORS+=("Require at least one approval is NOT configured (found: ${APPROVAL_COUNT:-0})")
fi

# Check: Require approval of the most recent reviewable push
DISMISS_STALE=$(echo "$PROTECTION" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('required_pull_request_reviews',{}).get('dismiss_stale_reviews', False))" 2>/dev/null)
if [ "$DISMISS_STALE" = "True" ]; then
  echo "    [OK] Dismiss stale reviews on new pushes is enabled"
else
  PROTECTION_ERRORS+=("Dismiss stale reviews (require approval of most recent push) is NOT enabled")
fi

if [ ${#PROTECTION_ERRORS[@]} -gt 0 ]; then
  echo ""
  echo "WARNING: The following branch protection rules are NOT in place:"
  for err in "${PROTECTION_ERRORS[@]}"; do
    echo "  - $err"
  done
  echo ""
  echo "Please configure these protections in GitHub repository settings:"
  echo "  https://github.com/${REPO_NAME}/settings/branches"
  exit 1
else
  echo ""
  echo "All branch protections are correctly configured!"
fi

echo ""
echo "==> Initialization complete! Repository is ready for development."
