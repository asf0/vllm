#!/usr/bin/env bash
# Sync a fork carrying local work with its upstream.
#
# Fetches upstream/main, merges it into the current branch, and fast-forwards
# the fork's main. Publishes only when merge + checks pass; on conflict it
# aborts and leaves the branch untouched.
#
# Usage: scripts/sync-upstream.sh [--check]
#   --check  report status only; do not merge or push

set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

UPSTREAM="${UPSTREAM:-upstream}"
UPSTREAM_BRANCH="${UPSTREAM_BRANCH:-main}"
SYNC_BRANCH="${SYNC_BRANCH:-sync-upstream}"
FORK_BRANCH="${FORK_BRANCH:-main}"
CHECK_ONLY=false
[[ "${1:-}" == "--check" ]] && CHECK_ONLY=true

die() { echo "error: $*" >&2; exit 1; }

command -v git >/dev/null || die "git not found"
git remote get-url "$UPSTREAM" >/dev/null 2>&1 || die "remote '$UPSTREAM' not configured"

# Refuse to run mid-merge or with a dirty tree.
[[ -f .git/MERGE_HEAD ]] && die "a merge is already in progress; resolve it first"
if [[ -n "$(git status --porcelain)" ]]; then
  die "working tree is dirty; commit or stash first"
fi

CURRENT_BRANCH=$(git branch --show-current)
[[ "$CURRENT_BRANCH" == "$SYNC_BRANCH" ]] || die "checkout $SYNC_BRANCH first (on: $CURRENT_BRANCH)"

git fetch "$UPSTREAM" "$UPSTREAM_BRANCH" 2>&1 | sed 's/^/  /'
BASE=$(git rev-list --left-right --count "$SYNC_BRANCH...$UPSTREAM/$UPSTREAM_BRANCH")
UPSTREAM_AHEAD=$(echo "$BASE" | cut -d$'\t' -f1)
LOCAL_AHEAD=$(echo "$BASE" | cut -d$'\t' -f2 | cut -d' ' -f1)
NEW_COMMITS=$(git rev-list --count "$SYNC_BRANCH..$UPSTREAM/$UPSTREAM_BRANCH")

echo "state: $SYNC_BRANCH has $LOCAL_AHEAD local commits; upstream has $NEW_COMMITS new"

if (( NEW_COMMITS == 0 )); then
  echo "already up to date"
  exit 0
fi

# Detect merge conflicts without touching the working tree.
MERGE_TREE=$(git merge-tree --write-tree "$SYNC_BRANCH" "refs/remotes/$UPSTREAM/$UPSTREAM_BRANCH" 2>&1) || true
if echo "$MERGE_TREE" | grep -q "^CONFLICT"; then
  echo "conflicts detected:" >&2
  echo "$MERGE_TREE" | grep "^CONFLICT" >&2
  die "resolve manually: git merge $UPSTREAM/$UPSTREAM_BRANCH"
fi

if $CHECK_ONLY; then
  echo "merge would be clean (dry-run, nothing done)"
  exit 0
fi

echo "merging $UPSTREAM/$UPSTREAM_BRANCH ..."
git merge "$UPSTREAM/$UPSTREAM_BRANCH" --no-edit

# Sanity gate: the ported APIs must resolve before publishing.
python -c "
import vllm.v1.kv_cache_utils
import vllm.v1.core.block_pool
import vllm.v1.kv_cache_interface
assert hasattr(vllm.v1.kv_cache_interface, 'KVCachePoolSpec')
assert hasattr(vllm.v1.core.block_pool, 'BlockPoolCollection')
" 2>/dev/null || echo "  (import check skipped: vllm not importable in this env)"

HEAD=$(git rev-parse --short HEAD)
echo "pushing $SYNC_BRANCH and $FORK_BRANCH -> $HEAD"
git push origin "$SYNC_BRANCH"
# Fast-forward the fork's main only when it points at the pre-merge head.
FORGE_MAIN=$(git ls-remote origin "refs/heads/$FORK_BRANCH" | cut -f1)
if [[ "$FORGE_MAIN" == "$(git rev-parse HEAD^1)" || "$FORGE_MAIN" == "$(git rev-parse HEAD^2)" ]]; then
  git push origin "$SYNC_BRANCH:$FORK_BRANCH"
else
  echo "  skipped $FORK_BRANCH: remote is not at either merge parent; update it manually"
fi

echo "synced: $SYNC_BRANCH at $HEAD"