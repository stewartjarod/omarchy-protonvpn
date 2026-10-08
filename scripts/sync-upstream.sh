#!/usr/bin/env bash
# Bring the jarod branch up to date with upstream, then push it to our fork.
#
# Run by hand, or from `omarchy update` through the post-update hook
# (~/.config/omarchy/hooks/post-update.d/protonvpn-sync).
#
# Our changes (feature work, then the jarod.protonvpn id rename) sit on top of
# upstream main. If upstream moved, we rebase them onto it. If the rebase
# conflicts, we undo it and stop, so the branch is never left half-rebased.
# Fix it by hand with:
#   git rebase origin/main
#
# Unlike workspace-display, our fork's main carries our own commits, so it is
# never overwritten with upstream's main here.
set -euo pipefail

PLUGIN_DIR=${PROTONVPN_DIR:-$HOME/.config/omarchy/plugins/jarod.protonvpn}
BRANCH=jarod

cd "$PLUGIN_DIR"

# Never rebase over uncommitted edits.
if [[ -n $(git status --porcelain) ]]; then
  echo "protonvpn sync: uncommitted changes in $PLUGIN_DIR, skipping" >&2
  exit 1
fi

git fetch --quiet origin
git fetch --quiet fork

git checkout --quiet "$BRANCH"

if ! git rebase --quiet origin/main; then
  git rebase --abort
  echo "protonvpn sync: rebase onto origin/main conflicts, branch left unchanged." >&2
  echo "protonvpn sync: resolve with: cd $PLUGIN_DIR && git rebase origin/main" >&2
  exit 1
fi

git push --quiet --force-with-lease fork "$BRANCH"

echo "protonvpn sync: $BRANCH is $(git rev-parse --short HEAD), pushed to fork."
