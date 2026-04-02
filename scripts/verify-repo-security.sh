#!/usr/bin/env bash
set -euo pipefail

# Verifies that a GitHub repository has the required branch protection rulesets
# on the 'main' branch.
#
# Usage: ./scripts/verify-repo-security.sh <github-repo-name>
#   e.g. ./scripts/verify-repo-security.sh myuser/my-rust-project
#
# Requires: GH_TOKEN or GITHUB_TOKEN environment variable set with a
# fine-grained access token that has "Administration: Read" permission.

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
GH_CMD="$(command -v gh 2>/dev/null || echo "$(git rev-parse --show-toplevel 2>/dev/null)/tools/gh")"

echo "==> Verifying GitHub repository branch protections..."
echo "    Checking that 'main' branch has the required rulesets..."

# Fetch repository rulesets
RULESETS=$("$GH_CMD" api "repos/${REPO_NAME}/rulesets" 2>&1) || {
  echo "ERROR: Could not fetch repository rulesets."
  echo ""
  if echo "$RULESETS" | grep -q "Resource not accessible by personal access token"; then
    echo "       Your fine-grained access token does not have permission to read rulesets."
    echo "       To fix, go to https://github.com/settings/tokens and edit your token to add:"
    echo "         - Repository permission: 'Administration' -> 'Read'"
  fi
  echo "       Raw response: $RULESETS"
  exit 1
}

# Get IDs of active rulesets that target the main branch, then fetch their full details
RULESET_IDS=$(echo "$RULESETS" | python3 -c "
import sys, json
rulesets = json.load(sys.stdin)
for rs in rulesets:
    if rs.get('enforcement', '') == 'active':
        print(rs['id'])
" 2>/dev/null)

if [ -z "$RULESET_IDS" ]; then
  echo "ERROR: No active rulesets found for the repository."
  echo "       Please configure rulesets at: https://github.com/${REPO_NAME}/settings/rules"
  exit 1
fi

# Collect all rules from all active rulesets that apply to main
ALL_RULES="[]"
for RSID in $RULESET_IDS; do
  DETAIL=$("$GH_CMD" api "repos/${REPO_NAME}/rulesets/${RSID}" 2>&1) || continue
  # Check if this ruleset targets the main branch
  TARGETS_MAIN=$(echo "$DETAIL" | python3 -c "
import sys, json
rs = json.load(sys.stdin)
conditions = rs.get('conditions', {})
ref_name = conditions.get('ref_name', {})
includes = ref_name.get('include', [])
for pattern in includes:
    if pattern in ('refs/heads/main', '~DEFAULT_BRANCH', '~ALL'):
        print('yes')
        sys.exit(0)
print('no')
" 2>/dev/null)
  if [ "$TARGETS_MAIN" = "yes" ]; then
    ALL_RULES=$(echo "$DETAIL" | python3 -c "
import sys, json
existing = json.loads('$ALL_RULES')
rs = json.load(sys.stdin)
existing.extend(rs.get('rules', []))
print(json.dumps(existing))
" 2>/dev/null)
  fi
done

# Now check all required protections against the collected rules
echo "$ALL_RULES" | python3 -c "
import sys, json

rules = json.load(sys.stdin)
rule_types = {r['type'] for r in rules}
errors = []

# Check: Restrict creations
if 'creation' not in rule_types:
    errors.append('Restrict creations is NOT enabled')
else:
    print('    [OK] Restrict creations is enabled')

# Check: Restrict updates
if 'update' not in rule_types:
    errors.append('Restrict updates is NOT enabled')
else:
    print('    [OK] Restrict updates is enabled')

# Check: Restrict deletions
if 'deletion' not in rule_types:
    errors.append('Restrict deletions is NOT enabled')
else:
    print('    [OK] Restrict deletions is enabled')

# Check: Require a pull request before merging
pr_rules = [r for r in rules if r['type'] == 'pull_request']
if not pr_rules:
    errors.append('Require a pull request before merging is NOT configured')
else:
    print('    [OK] Pull request required before merging')
    pr_params = pr_rules[0].get('parameters', {})

    # Check: Require at least one approval
    approvals = pr_params.get('required_approving_review_count', 0)
    if approvals >= 1:
        print(f'    [OK] At least {approvals} approval(s) required')
    else:
        errors.append(f'Require at least one approval is NOT configured (found: {approvals})')

    # Check: Require approval of the most recent reviewable push
    dismiss_stale = pr_params.get('dismiss_stale_reviews_on_push', False)
    if dismiss_stale:
        print('    [OK] Dismiss stale reviews on new pushes is enabled')
    else:
        errors.append('Dismiss stale reviews (require approval of most recent push) is NOT enabled')

if errors:
    print()
    print('WARNING: The following branch protection rules are NOT in place:')
    for e in errors:
        print(f'  - {e}')
    sys.exit(1)
else:
    print()
    print('All branch protections are correctly configured!')
" 2>/dev/null
RESULT=$?

if [ $RESULT -ne 0 ]; then
  echo ""
  echo "Please configure these protections in GitHub repository settings:"
  echo "  https://github.com/${REPO_NAME}/settings/rules"
  exit 1
fi
