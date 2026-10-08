#!/bin/zsh
# The three working branches and how they stand against main.
#
#   patch — bug fixes          → scripts/release.sh patch   (1.1.1 → 1.1.2)
#   minor — small features     → scripts/release.sh minor   (1.1.x → 1.2.0)
#   major — big updates        → scripts/release.sh major   (1.x   → 2.0.0)
#
#   scripts/branches.sh         # ahead/behind main and the last commit of each
#   scripts/branches.sh sync    # bring main into each branch and push (release.sh does this after a release)
#
# Syncing never touches your working copy: fast-forwards move the branch pointer, real merges happen in a
# temporary worktree. A branch with conflicts is left as it was and named at the end.
set -euo pipefail

branches=(patch minor major)
root=$(git rev-parse --show-toplevel)
cd "$root"

say() { print -P "%F{green}▸%f $1"; }
warn() { print -P "%F{yellow}▸%f $1"; }

status() {
  git fetch -q origin
  for b in $branches; do
    if ! git rev-parse -q --verify "refs/heads/$b" >/dev/null; then
      printf "%-6s  missing\n" "$b"
      continue
    fi
    local ahead=$(git rev-list --count "main..$b") behind=$(git rev-list --count "$b..main")
    printf "%-6s  +%-3s −%-3s  %s\n" "$b" "$ahead" "$behind" "$(git log -1 --format='%h %s (%cr)' "$b")"
  done
}

sync() {
  local current=$(git branch --show-current) conflicts=()
  for b in $branches; do
    git rev-parse -q --verify "refs/heads/$b" >/dev/null || continue
    if git merge-base --is-ancestor main "$b"; then
      continue                                   # already has everything from main
    fi
    if [[ $b == "$current" ]]; then
      warn "$b is checked out — run 'git merge main' in it yourself"
      continue
    fi
    if git merge-base --is-ancestor "$b" main; then
      git branch -f "$b" main                    # nothing of its own yet: fast-forward
    else
      local tmp="${TMPDIR:-/tmp}orbit-sync-$b"
      rm -rf "$tmp"
      git worktree add -q "$tmp" "$b"
      if git -C "$tmp" merge -q --no-edit main >/dev/null 2>&1; then
        :
      else
        git -C "$tmp" merge --abort 2>/dev/null || true
        conflicts+=("$b")
      fi
      git worktree remove --force "$tmp"
      [[ ${conflicts[(Ie)$b]} -gt 0 ]] && continue
    fi
    git push -q origin "$b"
    say "$b ← main"
  done
  (( ${#conflicts} == 0 )) || warn "Conflicts, merge by hand: ${conflicts[*]}  (git switch <branch> && git merge main)"
}

case ${1:-status} in
  status) status ;;
  sync) sync ;;
  *) echo "usage: scripts/branches.sh [status|sync]"; exit 1 ;;
esac
