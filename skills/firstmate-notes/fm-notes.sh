#!/usr/bin/env bash
# Own the per-task project-note lane: where a crewmate records durable
# project-intrinsic knowledge, and how that knowledge later reaches the
# project's shared documents.
#
# Why the lane exists: a shared document edited by every task in its own branch
# is a guaranteed same-repo collision, and it is the worst kind, because two
# agents' contradictory prose merges without failing and the file quietly ends
# up saying two things. So an ordinary task writes only its own note at
# .agents/notes/<task-id>.md - a path no other task can hold - and a single fold
# pass folds every pending note into AGENTS.md (or the document a note names)
# and retires it.
#
# Usage: fm-notes.sh <command> [args] [--dir <project-dir>]
#   path <task-id>        print the canonical note path (never touches disk)
#   new <task-id>         create the note from a template when absent, then
#                         print its path; re-running is a no-op, so a task that
#                         learns more can append to the same file
#   list [--ids]          print "<task-id><TAB><path>" per pending note, or bare
#                         ids with --ids; prints nothing when the lane is empty
#   count                 print the number of pending notes
#   retire <task-id>...   delete exactly the named notes after folding them, and
#                         print one "retired: <task-id>" line each; refuses an id
#                         with no note so a typo cannot silently retire nothing
#   scan [<dir>...]       report every repo holding unfolded notes (see below)
#
# --dir defaults to the current directory and is resolved to the enclosing git
# worktree root when there is one, so a crewmate can run these from anywhere in
# its tree.
#
# A pending note is a note that exists: retiring is what marks one folded, and
# nothing else records fold state. That is deliberate. An unfolded note stays on
# the default branch, keeps being counted by `scan`, and folds correctly whenever
# the fold finally runs, so a fold that is late, skipped, or failed loses nothing
# and stays visible. Git history keeps a retired note recoverable.
#
# scan is the loud counter. With explicit directories it scans exactly those,
# each resolved to its enclosing worktree root like --dir, and a repo named more
# than once - as itself and as one of its own subdirectories, say - is one root
# to scan, counted and printed once. With none it needs
# FM_HOME and scans that home's projects/* clones AND FM_HOME itself, because a
# firstmate home IS a firstmate checkout: the firstmate repo is never under
# projects/, so anything that iterates only projects/ silently skips the one repo
# its own crewmates work in most. It prints one line per repo holding notes and a
# summary. Three outcomes, three exit codes, so it can be used as a mechanical
# check: 3 when any note is pending, 0 when every scanned repo is clear, and 1
# when a named directory cannot be read - an unreadable path is reported, never
# counted as nothing found, which would be indistinguishable from a clear lane.
#
# Every id is matched exactly, never by glob or prefix. An earlier design keyed
# on a "<name>-*" glob and a project named `web` collided with a live `web-api`;
# nothing here matches by prefix, and ids are restricted to [A-Za-z0-9._-] with
# no leading dot, because they become paths.
set -eu

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

NOTES_SUBDIR=.agents/notes

case "${1:-}" in
  -h|--help|'') usage; exit 0 ;;
esac

CMD=$1
shift

DIR=.
ARGS=()
want_dir=0
for a in "$@"; do
  if [ "$want_dir" -eq 1 ]; then
    DIR=$a
    want_dir=0
    continue
  fi
  case "$a" in
    --dir) want_dir=1 ;;
    --dir=*) DIR=${a#--dir=} ;;
    *) ARGS+=("$a") ;;
  esac
done
[ "$want_dir" -eq 0 ] || { echo "error: --dir requires a value" >&2; exit 1; }

id_valid() {
  case "$1" in
    ''|.*|*/*|*' '*) return 1 ;;
  esac
  case "$1" in
    *[!A-Za-z0-9._-]*) return 1 ;;
  esac
  return 0
}

# Resolve a project dir to the enclosing worktree root so notes land at one path
# per project no matter which subdirectory the caller ran from.
resolve_dir() {
  local want=$1 resolved root
  resolved=$(CDPATH='' cd -- "$want" 2>/dev/null && pwd -P) || {
    echo "error: not a directory: $want" >&2
    exit 1
  }
  if root=$(git -C "$resolved" rev-parse --show-toplevel 2>/dev/null) && [ -n "$root" ]; then
    resolved=$root
  fi
  printf '%s\n' "$resolved"
}

note_template() {
  cat <<EOF
# Task notes: $1

Durable project-intrinsic knowledge this task produced.
The fold routes each fact below into the destination document and then retires this file.
Keep the bar high: knowledge useful to almost every future session, and a pointer to the authoritative file or command rather than detail the code already shows.

## Destination

AGENTS.md

## Notes

EOF
}

# Pending notes, sorted, one path per line. Silent when the lane is empty or
# absent; an absent lane is the normal state for a repo that has never produced
# durable knowledge, not a fault.
pending_notes() {
  local dir=$1 note
  [ -d "$dir/$NOTES_SUBDIR" ] || return 0
  for note in "$dir/$NOTES_SUBDIR"/*.md; do
    [ -f "$note" ] || continue
    printf '%s\n' "$note"
  done
}

count_in() {
  local dir=$1 n=0
  while IFS= read -r _note; do
    n=$((n + 1))
  done < <(pending_notes "$dir")
  printf '%s\n' "$n"
}

# TARGETS is the set of roots scan visits, and this is the only way into it:
# a root already held is not added again, so several paths naming one repo
# cannot reach the counting loop as more than one repo.
hold_root() {
  local root=$1 held
  for held in ${TARGETS[@]+"${TARGETS[@]}"}; do
    [ "$held" != "$root" ] || return 0
  done
  TARGETS+=("$root")
}

case "$CMD" in
  path|new)
    ID=${ARGS[0]:-}
    [ "${#ARGS[@]}" -eq 1 ] || { echo "error: $CMD requires exactly one task id" >&2; exit 1; }
    id_valid "$ID" || { echo "error: unsafe task id: $ID" >&2; exit 1; }
    PROJECT_DIR=$(resolve_dir "$DIR")
    NOTE="$PROJECT_DIR/$NOTES_SUBDIR/$ID.md"
    if [ "$CMD" = new ] && [ ! -e "$NOTE" ]; then
      mkdir -p "$PROJECT_DIR/$NOTES_SUBDIR"
      note_template "$ID" > "$NOTE"
    fi
    printf '%s\n' "$NOTE"
    ;;

  list)
    IDS_ONLY=0
    for a in "${ARGS[@]+"${ARGS[@]}"}"; do
      case "$a" in
        --ids) IDS_ONLY=1 ;;
        *) echo "error: unknown list argument: $a" >&2; exit 1 ;;
      esac
    done
    PROJECT_DIR=$(resolve_dir "$DIR")
    while IFS= read -r note; do
      base=${note##*/}
      if [ "$IDS_ONLY" -eq 1 ]; then
        printf '%s\n' "${base%.md}"
      else
        printf '%s\t%s\n' "${base%.md}" "$note"
      fi
    done < <(pending_notes "$PROJECT_DIR")
    ;;

  count)
    count_in "$(resolve_dir "$DIR")"
    ;;

  retire)
    [ "${#ARGS[@]}" -ge 1 ] || { echo "error: retire requires at least one task id" >&2; exit 1; }
    PROJECT_DIR=$(resolve_dir "$DIR")
    # Validate every id before deleting anything, so a bad id in the middle of a
    # list cannot leave the fold half-retired.
    for id in "${ARGS[@]}"; do
      id_valid "$id" || { echo "error: unsafe task id: $id" >&2; exit 1; }
      [ -f "$PROJECT_DIR/$NOTES_SUBDIR/$id.md" ] || {
        echo "error: no pending note for task id: $id" >&2
        exit 1
      }
    done
    for id in "${ARGS[@]}"; do
      rm -f -- "$PROJECT_DIR/$NOTES_SUBDIR/$id.md"
      echo "retired: $id"
    done
    ;;

  scan)
    TARGETS=()
    if [ "${#ARGS[@]}" -gt 0 ]; then
      # Every named directory is resolved before anything is counted, the way
      # retire validates every id before deleting anything: a path scan cannot
      # read is an error naming it, never a skip that would read as a clear lane.
      for target in "${ARGS[@]}"; do
        resolved=$(resolve_dir "$target") || exit $?
        hold_root "$resolved"
      done
    else
      [ -n "${FM_HOME:-}" ] || {
        echo "error: scan needs FM_HOME, or explicit directories to scan" >&2
        exit 1
      }
      # FM_HOME itself is a firstmate checkout and is never under projects/,
      # so scan it alongside the clones or its own notes go uncounted forever.
      hold_root "$FM_HOME"
      if [ -d "$FM_HOME/projects" ]; then
        for proj in "$FM_HOME"/projects/*; do
          [ -d "$proj" ] || continue
          hold_root "$proj"
        done
      fi
    fi
    total=0
    for target in "${TARGETS[@]}"; do
      resolved=$(CDPATH='' cd -- "$target" 2>/dev/null && pwd -P) || continue
      n=$(count_in "$resolved")
      [ "$n" -gt 0 ] || continue
      total=$((total + n))
      echo "unfolded: ${resolved##*/}: $n note(s) in $resolved/$NOTES_SUBDIR"
      while IFS= read -r note; do
        base=${note##*/}
        echo "    ${base%.md}"
      done < <(pending_notes "$resolved")
    done
    if [ "$total" -gt 0 ]; then
      echo "$total note(s) waiting to be folded; fold them per the firstmate-notes skill"
      exit 3
    fi
    ;;

  *)
    echo "error: unknown command: $CMD" >&2
    usage >&2
    exit 1
    ;;
esac
