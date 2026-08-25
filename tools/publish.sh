#!/bin/bash
# Publish a snapshot of the current tree to the public repository.
#
# The public repo never receives this repository's history: it contains real
# network addresses, device identifiers and light names. Each published commit is
# synthesised from the current tree alone, with the previous public commit as its
# parent, so the public history is a linear series of snapshots and contains
# nothing else.
#
# Snapshots land on `staging`. CI runs there, and `main` is updated only through a
# pull request gated by the same checks, so publishing does not bypass the
# protection on `main`.
#
# Usage: tools/publish.sh [--remote <name>] [--message <text>]
set -euo pipefail
cd "$(dirname "$0")/.."

REMOTE="public"
MESSAGE=""
while [ $# -gt 0 ]; do
    case "$1" in
        --remote)  REMOTE="$2"; shift 2 ;;
        --message) MESSAGE="$2"; shift 2 ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
done

if ! git remote get-url "$REMOTE" >/dev/null 2>&1; then
    echo "error: no remote named '$REMOTE'" >&2
    exit 1
fi

if [ -n "$(git status --porcelain)" ]; then
    echo "error: working tree is dirty. Commit or stash first — the snapshot is" >&2
    echo "       taken from the committed tree, so uncommitted work would be lost." >&2
    exit 1
fi

# The published tree is HEAD's tree, so anything unsafe to publish must not be in
# HEAD. These are the same checks CI runs; failing here costs a second rather than
# a force-push later.
echo "==> checking the tree"
./tools/check-no-secrets.sh
./tools/check-boundaries.sh >/dev/null && echo "  ok — boundaries"

git fetch -q "$REMOTE"

TREE=$(git rev-parse HEAD^{tree})
MAIN=$(git rev-parse --verify -q "$REMOTE/main" || true)
STAGING=$(git rev-parse --verify -q "$REMOTE/staging" || true)

# Stack onto staging while a snapshot is still waiting to be promoted; otherwise
# parent on main. Parenting on main while staging is ahead of it would produce a
# commit staging cannot fast-forward to.
PARENT="$MAIN"
if [ -n "$STAGING" ] && [ -n "$MAIN" ] && git merge-base --is-ancestor "$MAIN" "$STAGING"; then
    PARENT="$STAGING"
fi

if [ -n "$PARENT" ] && [ "$(git rev-parse "$PARENT^{tree}")" = "$TREE" ]; then
    echo "==> $REMOTE already has this exact tree; nothing to publish"
    exit 0
fi

if [ -z "$MESSAGE" ]; then
    MESSAGE="Snapshot $(date +%Y-%m-%d)"
fi

# `git commit-tree` builds the commit directly, so no branch is checked out and the
# working tree is never touched.
if [ -n "$PARENT" ]; then
    COMMIT=$(git commit-tree "$TREE" -p "$PARENT" -m "$MESSAGE")
else
    COMMIT=$(git commit-tree "$TREE" -m "$MESSAGE")
fi

# staging is a transient promotion branch. A rebase or squash merge leaves it
# pointing at commits that no longer exist on main, so it is reset rather than
# extended whenever it is not genuinely ahead of main.
echo "==> pushing $COMMIT to $REMOTE/staging"
if [ "$PARENT" = "$STAGING" ]; then
    git push -q "$REMOTE" "$COMMIT":refs/heads/staging
else
    git push -q --force-with-lease="refs/heads/staging:$STAGING" \
        "$REMOTE" "$COMMIT":refs/heads/staging
fi

REPO=$(git remote get-url "$REMOTE" | sed -E 's#(git@github.com:|https://github.com/)##; s#\.git$##')
echo
echo "Pushed to staging. CI is running:"
echo "  gh run watch --repo $REPO"
echo
echo "Open the pull request that promotes it to main:"
echo "  gh pr create --repo $REPO --base main --head staging \\"
echo "               --title \"$MESSAGE\" --body \"Snapshot of the development tree.\""
