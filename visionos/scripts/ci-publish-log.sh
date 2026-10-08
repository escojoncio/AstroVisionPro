#!/usr/bin/env bash
# Keeps a CI log in the repository's ci-logs branch, so that it can be read without access to
# GitHub's Actions pages: ci-publish-log.sh <name> <log file> [<log file> ...]
# For a long log, the lines with errors (and what surrounds them) come first, then its end.
set -uo pipefail

NAME="$1"
shift
OUT=$(mktemp -d)
{
  echo "# $NAME - ${GITHUB_SHA:-local} - $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  for LOG in "$@"; do
    [[ -f "$LOG" ]] || continue
    echo
    echo "## $(basename "$LOG"): $(wc -l < "$LOG") lines"
    echo "### errors"
    grep -n -E -B2 -A6 "error:|Error |ERROR:|FAILED|fatal error|undefined symbol|ld: |CMake Error|\*\* BUILD FAILED" "$LOG" | head -1500
    echo "### end"
    tail -n 150 "$LOG"
  done
} > "$OUT/$NAME.txt"

git config user.name "ci"
git config user.email "ci@users.noreply.github.com"
WORK=$(mktemp -d)
for ATTEMPT in 1 2 3 4 5; do
  rm -rf "$WORK"
  if git fetch -q origin ci-logs 2>/dev/null; then
    git worktree add -q -f "$WORK" FETCH_HEAD 2>/dev/null || { sleep 3; continue; }
    git -C "$WORK" checkout -q -B ci-logs
  else
    git worktree add -q -f --detach "$WORK" 2>/dev/null || { sleep 3; continue; }
    git -C "$WORK" checkout -q --orphan ci-logs
    git -C "$WORK" rm -rfq . 2>/dev/null || true
  fi
  cp "$OUT/$NAME.txt" "$WORK/$NAME.txt"
  git -C "$WORK" add "$NAME.txt"
  git -C "$WORK" commit -qm "$NAME ${GITHUB_SHA:-local}" || true
  if git -C "$WORK" push -q origin HEAD:ci-logs; then
    git worktree remove -f "$WORK" || true
    exit 0
  fi
  git worktree remove -f "$WORK" || true
  sleep $((ATTEMPT * 5))
done
echo "Could not publish the log" >&2
exit 0
