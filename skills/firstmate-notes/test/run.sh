#!/usr/bin/env bash
# Offline behavior tests for fm-notes.sh. No firstmate repo, no network, no real
# fleet data - every fixture is a throwaway git repo under a temp dir.
# Run: ~/.claude/skills/firstmate-notes/test/run.sh
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
NOTES="$HERE/../fm-notes.sh"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/fm-notes-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
FAILED=0

pass() { echo "ok - $1"; }
fail() { echo "FAIL - $1"; FAILED=1; }
present() { [ -e "$1" ] || { fail "${2:-missing: $1}"; return 1; }; }
absent() { [ ! -e "$1" ] || { fail "${2:-unexpectedly present: $1}"; return 1; }; }
# shellcheck disable=SC2016 # the single quotes are literal; the enclosing string is double-quoted, so $2 and $1 do expand
contains() { case "$1" in *"$2"*) ;; *) fail "${3:-expected '$2' in: $1}" ;; esac; }

# A throwaway git repo, returned as its resolved path (macOS /var vs /private/var).
new_repo() {
  local repo="$TMP/$1"
  mkdir -p "$repo"
  git -C "$repo" init -q
  git -C "$repo" config user.email t@example.com
  git -C "$repo" config user.name test
  git -C "$repo" commit -q --allow-empty -m init
  (CDPATH='' cd -- "$repo" && pwd -P)
}

# --- the claim the lane exists for -------------------------------------------
# Two same-repo tasks that each record durable knowledge must stop colliding,
# and the fold must still deliver both facts afterwards.
test_two_tasks_stop_colliding() {
  local repo main note rc
  repo=$(new_repo collide)
  printf '# Project agent memory\n\n- seed\n' > "$repo/AGENTS.md"
  git -C "$repo" add AGENTS.md; git -C "$repo" commit -qm seed
  main=$(git -C "$repo" rev-parse --abbrev-ref HEAD)

  # Old convention: both tasks edit the shared document in their own branch.
  git -C "$repo" checkout -qb old-a "$main"
  printf -- '- task a learned something\n' >> "$repo/AGENTS.md"
  git -C "$repo" commit -qam "old a"
  git -C "$repo" checkout -qb old-b "$main"
  printf -- '- task b learned something else\n' >> "$repo/AGENTS.md"
  git -C "$repo" commit -qam "old b"
  git -C "$repo" checkout -q "$main"
  git -C "$repo" merge -q --no-edit old-a
  git -C "$repo" merge --no-edit old-b >/dev/null 2>&1
  rc=$?
  [ "$rc" -ne 0 ] || fail "expected the old convention to conflict on the shared document"
  git -C "$repo" merge --abort >/dev/null 2>&1
  git -C "$repo" reset -q --hard HEAD

  # The lane: same two tasks, each writing only its own note.
  git -C "$repo" checkout -qb task-a "$main"
  note=$("$NOTES" new task-a --dir "$repo")
  printf -- '- task a learned something\n' >> "$note"
  git -C "$repo" add -A; git -C "$repo" commit -qm "task a"
  git -C "$repo" checkout -qb task-b "$main"
  note=$("$NOTES" new task-b --dir "$repo")
  printf -- '- task b learned something else\n' >> "$note"
  git -C "$repo" add -A; git -C "$repo" commit -qm "task b"
  git -C "$repo" checkout -q "$main"
  git -C "$repo" merge -q --no-edit task-a || fail "first note-lane merge failed"
  git -C "$repo" merge -q --no-edit task-b \
    || fail "two tasks still collided after moving to per-task notes"
  present "$repo/.agents/notes/task-a.md" "task-a's note did not survive the merges"
  present "$repo/.agents/notes/task-b.md" "task-b's note did not survive the merges"

  # The fold: one pass writes the shared document and retires both notes.
  grep -h '^- ' "$repo/.agents/notes/task-a.md" "$repo/.agents/notes/task-b.md" >> "$repo/AGENTS.md"
  "$NOTES" retire task-a task-b --dir "$repo" >/dev/null || fail "fold retire failed"
  git -C "$repo" add -A; git -C "$repo" commit -qm "fold notes"
  grep -q "task a learned something" "$repo/AGENTS.md" || fail "the fold lost task a's knowledge"
  grep -q "task b learned something else" "$repo/AGENTS.md" || fail "the fold lost task b's knowledge"
  [ "$("$NOTES" count --dir "$repo")" = 0 ] || fail "the fold left notes pending"
  pass "two same-repo tasks merge cleanly and the fold still lands both facts"
}

test_note_path_is_unique_per_task() {
  local repo a b
  repo=$(new_repo unique)
  a=$("$NOTES" new alpha --dir "$repo")
  b=$("$NOTES" new beta --dir "$repo")
  [ "$a" != "$b" ] || fail "two task ids resolved to the same note path"
  contains "$a" "/.agents/notes/alpha.md" "note path is not derived from the task id"
  contains "$b" "/.agents/notes/beta.md" "note path is not derived from the task id"
  pass "each task id owns a distinct note path"
}

test_path_does_not_write() {
  local repo out
  repo=$(new_repo pathonly)
  out=$("$NOTES" path some-task --dir "$repo")
  absent "$out" "path created the note file"
  absent "$repo/.agents/notes" "path created the notes directory"
  pass "path prints the note location without writing"
}

test_new_is_idempotent() {
  local repo note
  repo=$(new_repo idem)
  note=$("$NOTES" new keep --dir "$repo")
  printf 'a fact worth folding\n' >> "$note"
  "$NOTES" new keep --dir "$repo" >/dev/null
  grep -q "a fact worth folding" "$note" || fail "re-running new clobbered the note"
  pass "new is idempotent and never clobbers an existing note"
}

test_subdirectory_resolves_to_worktree_root() {
  local repo out
  repo=$(new_repo subdir)
  mkdir -p "$repo/src/deep"
  out=$("$NOTES" new deep --dir "$repo/src/deep")
  [ "$out" = "$repo/.agents/notes/deep.md" ] \
    || fail "a note written from a subdirectory did not land at the worktree root: $out"
  absent "$repo/src/deep/.agents" "a second notes lane was created inside a subdirectory"
  pass "notes land at the worktree root from any subdirectory"
}

test_retire_is_all_or_nothing() {
  local repo out rc
  repo=$(new_repo retirerefuse)
  "$NOTES" new real --dir "$repo" >/dev/null
  out=$("$NOTES" retire real typo --dir "$repo" 2>&1)
  rc=$?
  [ "$rc" -ne 0 ] || fail "expected a non-zero exit when retiring an unknown id"
  contains "$out" "typo" "refusal did not name the unknown id"
  present "$repo/.agents/notes/real.md" "a refused retire still deleted a valid note"
  pass "retire refuses an unknown id and deletes nothing"
}

test_retire_leaves_unfolded_notes_pending() {
  local repo
  repo=$(new_repo retire)
  "$NOTES" new folded --dir "$repo" >/dev/null
  "$NOTES" new leftbehind --dir "$repo" >/dev/null
  "$NOTES" retire folded --dir "$repo" >/dev/null
  absent "$repo/.agents/notes/folded.md" "retire left the folded note in place"
  # A partial fold must lose nothing: what it skipped stays pending and visible.
  present "$repo/.agents/notes/leftbehind.md" "retire removed a note it was not given"
  [ "$("$NOTES" count --dir "$repo")" = 1 ] || fail "expected 1 pending note after a partial fold"
  pass "retire clears exactly the named notes and leaves the rest pending"
}

test_unsafe_ids_refused() {
  local repo bad rc
  repo=$(new_repo unsafe)
  for bad in "../escape" ".hidden" "has space" "sub/dir"; do
    "$NOTES" new "$bad" --dir "$repo" >/dev/null 2>&1
    rc=$?
    [ "$rc" -ne 0 ] || fail "new accepted an unsafe task id: $bad"
  done
  absent "$repo/.agents/notes" "an unsafe task id created the notes lane"
  pass "unsafe task ids are refused before touching disk"
}

# --- the loud counter ---------------------------------------------------------
# An unfolded note is invisible in every diff, so scan is the only thing standing
# between a skipped fold and knowledge that silently stops shipping.
test_scan_reports_and_exits_3() {
  local repo out rc
  repo=$(new_repo scanned)
  out=$("$NOTES" scan "$repo"); rc=$?
  [ "$rc" -eq 0 ] || fail "scan of a clean repo should exit 0, got $rc"
  [ -z "$out" ] || fail "scan of a clean repo printed: $out"

  "$NOTES" new one --dir "$repo" >/dev/null
  "$NOTES" new two --dir "$repo" >/dev/null
  out=$("$NOTES" scan "$repo" 2>&1); rc=$?
  [ "$rc" -eq 3 ] || fail "scan with pending notes should exit 3, got $rc"
  contains "$out" "scanned: 2 note(s)" "scan did not count the pending notes"
  contains "$out" "one" "scan did not list a pending note id"
  contains "$out" "two" "scan did not list a pending note id"

  "$NOTES" retire one two --dir "$repo" >/dev/null
  out=$("$NOTES" scan "$repo"); rc=$?
  [ "$rc" -eq 0 ] || fail "scan should exit 0 once the notes are folded, got $rc"
  [ -z "$out" ] || fail "scan still reported after the fold: $out"
  pass "scan is loud with pending notes and silent once folded"
}

# The explicit-directory form is the one that takes paths a person typed, and it
# is the only form available without a firstmate home. A path it cannot read must
# be reported: counting nothing there is indistinguishable from a clear lane,
# which is the single failure this check exists to prevent.
test_scan_refuses_a_target_it_cannot_read() {
  local repo out rc
  repo=$(new_repo scanbad)
  "$NOTES" new pending-one --dir "$repo" >/dev/null

  out=$("$NOTES" scan "$repo-typo" 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "scan of a nonexistent path exited 0, reading as a clear lane"
  [ "$rc" -ne 3 ] || fail "scan of a nonexistent path exited 3, reading as pending notes"
  contains "$out" "$repo-typo" "scan's refusal did not name the unreadable path"

  : > "$TMP/not-a-repo"
  out=$("$NOTES" scan "$TMP/not-a-repo" 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "scan of a plain file exited 0, reading as a clear lane"
  [ "$rc" -ne 3 ] || fail "scan of a plain file exited 3, reading as pending notes"
  contains "$out" "not-a-repo" "scan's refusal did not name the non-directory path"

  # An unreadable target beside a clean one must not be absorbed into its 0.
  local clean
  clean=$(new_repo scanclean)
  out=$("$NOTES" scan "$clean" "$repo-typo" 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "an unreadable target beside a clean repo still exited 0"
  [ "$rc" -ne 3 ] || fail "an unreadable target beside a clean repo exited 3, reading as pending notes"
  contains "$out" "$repo-typo" "the mixed-target refusal did not name the unreadable path"
  pass "scan reports a target it cannot read instead of a clear lane"
}

# Every other command resolves its directory to the enclosing worktree root, so
# a repo's own subdirectory must count that repo's notes, not report zero.
test_scan_resolves_a_subdirectory_to_its_worktree_root() {
  local repo out rc
  repo=$(new_repo scansub)
  mkdir -p "$repo/src/deep"
  "$NOTES" new buried --dir "$repo" >/dev/null

  out=$("$NOTES" scan "$repo/src/deep" 2>&1); rc=$?
  [ "$rc" -eq 3 ] || fail "scan of a subdirectory missed its repo's pending note (exit $rc)"
  contains "$out" "buried" "scan of a subdirectory did not name the pending note"
  pass "scan resolves a subdirectory to its worktree root instead of reporting clean"
}

# The firstmate repo is never under projects/, so anything that iterates only
# projects/ silently skips the repo firstmate's own crewmates work in most.
test_scan_covers_the_firstmate_home_itself() {
  local home out rc
  home=$(new_repo fmhome)
  mkdir -p "$home/projects"
  local clone="$home/projects/SomeProj"
  mkdir -p "$clone"
  git -C "$clone" init -q

  "$NOTES" new firstmate-task --dir "$home" >/dev/null
  out=$(FM_HOME="$home" "$NOTES" scan 2>&1); rc=$?
  [ "$rc" -eq 3 ] || fail "scan missed a note in the firstmate home itself (exit $rc)"
  contains "$out" "firstmate-task" "scan did not name the firstmate-home note"

  "$NOTES" new clone-task --dir "$clone" >/dev/null
  out=$(FM_HOME="$home" "$NOTES" scan 2>&1)
  contains "$out" "firstmate-task" "scan dropped the firstmate-home note once a clone had one"
  contains "$out" "clone-task" "scan missed a note in a projects/ clone"
  contains "$out" "2 note(s) waiting" "scan did not total across both repos"
  pass "scan covers the firstmate home itself as well as projects/ clones"
}

# An earlier design keyed the fold on a "<name>-*" glob, so a live fold for
# `web-api` blocked `web`. Nothing here may match by prefix.
test_no_prefix_collision_between_similar_names() {
  local repo out
  repo=$(new_repo prefix)
  "$NOTES" new web-api --dir "$repo" >/dev/null
  "$NOTES" new web --dir "$repo" >/dev/null
  [ "$("$NOTES" count --dir "$repo")" = 2 ] || fail "similar ids did not both create notes"
  "$NOTES" retire web --dir "$repo" >/dev/null
  present "$repo/.agents/notes/web-api.md" "retiring 'web' also removed 'web-api'"
  absent "$repo/.agents/notes/web.md" "retiring 'web' did not remove it"
  out=$("$NOTES" list --ids --dir "$repo")
  [ "$out" = "web-api" ] || fail "expected only web-api pending, got: $out"
  pass "an id that is a prefix of another never collides with it"
}

test_two_tasks_stop_colliding
test_note_path_is_unique_per_task
test_path_does_not_write
test_new_is_idempotent
test_subdirectory_resolves_to_worktree_root
test_retire_is_all_or_nothing
test_retire_leaves_unfolded_notes_pending
test_unsafe_ids_refused
test_scan_reports_and_exits_3
test_scan_refuses_a_target_it_cannot_read
test_scan_resolves_a_subdirectory_to_its_worktree_root
test_scan_covers_the_firstmate_home_itself
test_no_prefix_collision_between_similar_names

if [ "$FAILED" -ne 0 ]; then
  echo "FAILED"
  exit 1
fi
echo "all tests passed"
