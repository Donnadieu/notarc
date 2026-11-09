#!/bin/bash
# WHY: app/main_window.mm and app/main.mm are the repo's de facto god-objects;
# this ratchet stops them from growing further while a split is planned,
# without blocking everything else in the repo. Baseline counts may only
# shrink (see --update).
set -u

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
DEFAULT_BASELINE="$REPO_ROOT/.hardening/file-length-baseline.txt"

usage() {
  echo "Usage: $0 [--init <seed-file>|--update|--prove|--verify-base <ref>]" >&2
  echo "  (no flag)           check tracked files against the baseline" >&2
  echo "  --init <seed>       seed/overwrite the baseline from <seed>'s paths' current line counts" >&2
  echo "  --update            shrink baseline entries down to current counts (never raises one)" >&2
  echo "  --prove             run a self-contained canary proving the check actually blocks" >&2
  echo "  --verify-base <ref> fail if any baseline entry is higher than it is at <ref> (catches editing the ratchet itself)" >&2
}

line_count() { wc -l < "$1" | tr -d ' '; }

cmd_init() {
  local seed="$1" baseline="$2"
  : > "$baseline"
  while read -r path _; do
    [ -n "$path" ] || continue
    [ -f "$REPO_ROOT/$path" ] || { echo "FIX: $path listed in $seed does not exist" >&2; return 1; }
    printf '%s %s\n' "$path" "$(line_count "$REPO_ROOT/$path")" >> "$baseline"
  done < "$seed"
  echo "wrote $(wc -l < "$baseline" | tr -d ' ') baseline entries to $baseline"
}

cmd_update() {
  local baseline="$1"
  [ -f "$baseline" ] || { echo "no $baseline to update" >&2; return 1; }
  local tmp; tmp=$(mktemp)
  while read -r path baseline_count; do
    [ -n "$path" ] || continue
    if [ ! -f "$REPO_ROOT/$path" ]; then
      echo "FIX: $path is in the ratchet but no longer exists; remove its line from $baseline" >&2
      rm -f "$tmp"
      return 1
    fi
    local current; current=$(line_count "$REPO_ROOT/$path")
    if [ "$current" -lt "$baseline_count" ]; then
      printf '%s %s\n' "$path" "$current" >> "$tmp"
    else
      printf '%s %s\n' "$path" "$baseline_count" >> "$tmp"
    fi
  done < "$baseline"
  mv "$tmp" "$baseline"
  echo "updated $baseline"
}

cmd_check() {
  local baseline="$1" fail=0
  [ -f "$baseline" ] || { echo "no $baseline found; run with --init first" >&2; return 1; }
  while read -r path baseline_count; do
    [ -n "$path" ] || continue
    if [ ! -f "$REPO_ROOT/$path" ]; then
      echo "FIX: $path is in the ratchet ($baseline) but no longer exists; remove its line from the baseline." >&2
      fail=1
      continue
    fi
    local current; current=$(line_count "$REPO_ROOT/$path")
    if [ "$current" -gt "$baseline_count" ]; then
      echo "FILE-LENGTH-RATCHET: $path grew from $baseline_count to $current lines." >&2
      echo "WHY: $path is a de facto god-object; it may only shrink until it's split up." >&2
      echo "FIX: extract the new code into its own file/class. If it genuinely cannot shrink, shrink it elsewhere first, then run 'scripts/lint/file-length-ratchet.sh --update'." >&2
      fail=1
    fi
  done < "$baseline"
  [ "$fail" -eq 0 ] && echo "file-length-ratchet: ok ($(wc -l < "$baseline" | tr -d ' ') files tracked)"
  return $fail
}

cmd_prove() {
  local tmp; tmp=$(mktemp -d)
  trap 'rm -rf "$tmp"' RETURN
  printf 'line1\nline2\nline3\n' > "$tmp/canary.mm"
  printf 'canary.mm 3\n' > "$tmp/baseline.txt"

  if ! REPO_ROOT="$tmp" cmd_check "$tmp/baseline.txt" > /dev/null; then
    echo "PROVE FAILED: an unmodified file at its baseline count should pass" >&2
    return 1
  fi

  printf 'line1\nline2\nline3\nline4\n' > "$tmp/canary.mm"
  if REPO_ROOT="$tmp" cmd_check "$tmp/baseline.txt" > /dev/null 2>&1; then
    echo "PROVE FAILED: growing a baselined file by one line did not block" >&2
    return 1
  fi
  echo "file-length-ratchet --prove: ok (canary blocked a one-line regression)"
}

cmd_verify_base() {
  local ref="$1" baseline_rel=".hardening/file-length-baseline.txt" fail=0
  local base_content; base_content=$(git -C "$REPO_ROOT" show "$ref:$baseline_rel" 2>/dev/null) || {
    echo "no $baseline_rel at $ref -- nothing to compare against" >&2
    return 0
  }
  while read -r path base_count; do
    [ -n "$path" ] || continue
    local current_count; current_count=$(awk -v p="$path" '$1==p{print $2}' "$DEFAULT_BASELINE")
    if [ -n "$current_count" ] && [ "$current_count" -gt "$base_count" ]; then
      echo "RATCHET-BASELINE-RAISED: $path's baseline went from $base_count ($ref) to $current_count." >&2
      echo "WHY: a baseline may only shrink; raising it here defeats the ratchet instead of fixing the regression." >&2
      echo "FIX: shrink $path back down, or revert the baseline edit." >&2
      fail=1
    fi
  done <<< "$base_content"
  [ "$fail" -eq 0 ] && echo "file-length-ratchet --verify-base: ok (baseline did not grow vs $ref)"
  return $fail
}

case "${1:-}" in
  --init) [ -z "${2:-}" ] && { usage; exit 1; }; cmd_init "$2" "$DEFAULT_BASELINE" ;;
  --update) cmd_update "$DEFAULT_BASELINE" ;;
  --prove) cmd_prove ;;
  --verify-base) [ -z "${2:-}" ] && { usage; exit 1; }; cmd_verify_base "$2" ;;
  "") cmd_check "$DEFAULT_BASELINE" ;;
  -h|--help) usage ;;
  *) usage; exit 1 ;;
esac
