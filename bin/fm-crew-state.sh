#!/usr/bin/env bash
# fm-crew-state.sh - deterministic read of a crew's CURRENT state.
#
# Why this exists: state/<id>.status is an append-only, best-effort EVENT LOG.
# Crews append only wake-worthy transitions (done/needs-decision/blocked/paused/failed)
# and nothing when they silently resume, so `tail -1` of that log reports the
# last EVENT, not the current STATE. After firstmate resolves a needs-decision
# or blocked and the crew resumes (responds to the gate, the pipeline fixes, it
# re-validates), the log's last line stays stale. This helper never infers the
# current state from a tail of the log: it reads the authoritative source (a
# no-mistakes run-step attributed to this crew's branch - on branch alone while
# the pipeline still holds the run, with code identity qualifying only a
# FINISHED one - else the pane busy-signature) and reconciles the possibly-stale
# log against it.
#
# The determinism lives entirely here - only run-step / pane / log reads plus
# fixed mapping logic, no heuristics and no LLM. Output is one stable, parseable,
# token-tight line firstmate can read every heartbeat:
#
#   state: <working|parked|done|blocked|paused|failed|unknown|unreadable> · source: <run-step|pane|status-log|run-source|none> · <detail>
#
# `unreadable` is deliberately NOT another flavour of `unknown`. A supervisor
# must be able to tell three cases apart, because they justify opposite actions:
#   - a healthy running lane          -> working · run-step
#   - no live run for this crew       -> unknown · none (the run source answered)
#   - the run source did not answer   -> unreadable · run-source
# Collapsing the third into the second renders an absence of measurement exactly
# like a measurement, and anything downstream that then absorbs on it would be
# spending evidence nobody gathered. The state token carries that distinction so
# no caller has to remember the rule (fm-classify-lib.sh's crew_absorb_class is
# the one place it is turned into an absorb decision).
#
# Logic, in order:
#   1. Resolve worktree + backend target + kind from state/<id>.meta.
#   2. Matching no-mistakes run for this crew's branch (from `axi status`, or the
#      coarse `no-mistakes runs` fallback)? LIVENESS is decided first, and code
#      identity only disambiguates FINISHED runs:
#      - a run the pipeline is still holding (an unfinished run whose
#        branch_sync block reports a live relationship to this branch, or an
#        active row in the coarse list) is attributed on branch alone. It has
#        to be: the pipeline commits its fix rounds in its OWN clone, so a
#        healthy run's head is routinely unresolvable in this worktree exactly
#        while the run is healthiest (fm_nm_head_matches_worktree owns why).
#        Attributing the `axi status` record itself keeps the step and gate
#        detail, so a live run parked at a gate is still reported as parked.
#      - a finished run must still match this worktree's code identity, so a
#        historical run on a reused or rewritten branch is never attributed.
#        A run matches when its head equals the worktree HEAD, or the worktree
#        HEAD is an ancestor of the run head. Local work that advanced past the
#        run head, or diverged from it, invalidates attribution.
#      The run-step is AUTHORITATIVE: running/fixing -> working, ci -> working,
#      awaiting_approval/fix_review -> parked (with gate findings), terminal
#      passed/checks-passed -> done, failed/cancelled -> failed. EXCEPT: while
#      the active step is ci, `axi status` alone cannot tell "still waiting on
#      checks" from "checks green, waiting on merge" (see nm_ci_checks_state) -
#      a ci-step log-tail check overrides working -> done once checks read
#      green, so a green PR is never silently read as still-validating.
#   3. Reconcile the status log: if its last line says needs-decision/blocked but
#      the run-step shows the run moved on, the log is deterministically stale and
#      is flagged superseded. A genuinely parked run plus a needs-decision log
#      agree, and are reported as parked.
#   4. No run for this crew (pre-validation, or kind=scout): probe the endpoint,
#      then fall back to the recorded backend's pane busy state, then the status
#      log's last line only when its verb maps to a recognized run-state.
#      Decision-only events such as `resolved` never become current state or
#      detail. The endpoint probe gates the busy read unconditionally: the busy
#      record has no time expiry, so reading it for a pane that no longer exists
#      would report a dead crew as a measured `working`.
#   5. Missing meta or torn-down worktree: report unknown · none. If no run is
#      attributed to this crew, a dead endpoint also reports unknown · none rather
#      than trusting a stale status log. If the run source itself never answered,
#      report unreadable · run-source instead, and route every NEGATIVE fallback
#      verdict (missing target, dead endpoint, unavailable harness state, status
#      log) into it rather than letting any of them pre-empt it into a
#      measured-looking unknown · none: until the run question is answered
#      nothing here can establish that the crew stopped. Only a positive direct
#      measurement of a LIVE endpoint - an exact busy verdict on a readable pane
#      - still answers, because that one IS a measurement.
#
# Read-only and side-effect free. Always exits 0 on a successful read regardless
# of state; exit 2 only on a usage error (no id).
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-tmux-lib.sh
. "$SCRIPT_DIR/fm-tmux-lib.sh"
# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-classify-lib.sh
. "$SCRIPT_DIR/fm-classify-lib.sh"
# shellcheck source=bin/fm-busy-lib.sh
. "$SCRIPT_DIR/fm-busy-lib.sh"
# shellcheck source=bin/fm-nm-run-lib.sh
. "$SCRIPT_DIR/fm-nm-run-lib.sh"

ID=${1:-}
[ -n "$ID" ] || { echo "usage: fm-crew-state.sh <id>" >&2; exit 2; }

META="$STATE/$ID.meta"
LOG="$STATE/$ID.status"
NM_TIMEOUT=${FM_CREW_STATE_NM_TIMEOUT:-10}
case "$NM_TIMEOUT" in ''|*[!0-9]*) NM_TIMEOUT=10 ;; esac
# How many of the most recent `no-mistakes runs` rows the cross-branch fallback
# (nm_runs_status_for_branch, below) scans. Generous enough to still find a
# branch's own run on a busy multi-crew fleet without listing the entire
# history every call.
FM_CREW_STATE_RUNS_LIMIT=${FM_CREW_STATE_RUNS_LIMIT:-200}
case "$FM_CREW_STATE_RUNS_LIMIT" in ''|*[!0-9]*) FM_CREW_STATE_RUNS_LIMIT=200 ;; esac
SEP=' · '

# Emit the one canonical line and exit 0. Detail is optional.
emit() {  # <state> <source> [detail]
  local line="state: $1${SEP}source: $2"
  [ -n "${3:-}" ] && line="$line${SEP}$3"
  printf '%s\n' "$line"
  exit 0
}

# --- meta resolution --------------------------------------------------------

[ -f "$META" ] || emit unknown none "no metadata for $ID"

meta_value() {  # <key>
  grep "^$1=" "$META" 2>/dev/null | tail -1 | cut -d= -f2- || true
}

WT=$(meta_value worktree)
KIND=$(meta_value kind)
HARNESS=$(meta_value harness)
[ -n "$KIND" ] || KIND=ship

# A torn-down (or never-created) worktree has no current state to read.
if [ -z "$WT" ] || [ ! -d "$WT" ]; then
  emit unknown none "worktree gone (torn down?)"
fi

# --- status log ------------------------------------------------------------

# Last non-empty status line, and its leading verb (the word before the colon).
log_last_line() {
  [ -f "$LOG" ] || return 1
  grep -v '^[[:space:]]*$' "$LOG" 2>/dev/null | tail -1
}
# Map a status-log verb onto a canonical state for the fallback path. `paused` is
# the deliberate-external-wait verb (fm-classify-lib.sh's FM_CLASSIFY_PAUSED_VERB):
# a crew with no active run and an idle pane that declared a known external wait
# reports `paused` distinctly, so a supervisor reading this sees a declared pause
# and its reason rather than a wedge-suspect idle.
map_log_state() {  # <line>
  if status_is_paused "$1"; then
    echo paused
    return
  fi
  case "$(status_line_verb "$1")" in
    working)        echo working ;;
    needs-decision) echo parked ;;
    blocked)        echo blocked ;;
    done)           echo "done" ;;
    failed)         echo failed ;;
    *)              echo unknown ;;
  esac
}

LOG_LINE=$(log_last_line || true)
LOG_VERB=$(status_line_verb "$LOG_LINE")

# pane_readable is consulted ONLY in the no-run fallback below. The run-step path
# stays authoritative regardless of pane liveness - judge by the run-step, not the
# shell - so a finished crew whose endpoint has closed still reports its run-step
# state (e.g. done) instead of being masked as unknown. Backend-aware
# (fm_backend_of_meta defaults absent backend= to tmux, the P1 contract): a
# herdr task is read through fm_backend_capture instead of a bare tmux probe.
TASK_BACKEND=$(fm_backend_of_meta "$META")
BACKEND_TARGET=$(fm_backend_target_of_meta "$META")
EXPECTED_LABEL="fm-$ID"
pane_readable() {  # <target>
  case "$TASK_BACKEND" in
    # Delegated to the one shared presence primitive (fm_backend_target_exists
    # in bin/fm-backend.sh) rather than re-derived here: the same probe lived
    # inline in both places once, and the same wrong probe had to be fixed
    # twice. Non-tmux backends keep the stronger capture-based read below.
    tmux) fm_backend_target_exists tmux "$1" ;;
    *) fm_backend_capture "$TASK_BACKEND" "$1" 1 "$EXPECTED_LABEL" >/dev/null 2>&1 ;;
  esac
}
# crew_busy_verdict: the crew's semantic busy state from the one contract
# owner (bin/fm-busy-lib.sh), as "<busy|idle|unknown> <source>". A converted
# adapter answers from its own lifecycle record; Grok answers from its
# isolated rendered-tail fallback; a herdr crew's native `busy` is accepted
# when no record exists, but its native `idle` is NOT, because agent.get
# reports generation state (idle while a crew blocks on its own long-running
# foreground tool call) rather than turn state.
crew_busy_verdict() {  # <target>
  local tail40=''
  case "$HARNESS" in
    grok*) tail40=$(fm_backend_capture "$TASK_BACKEND" "$1" 40 "$EXPECTED_LABEL" 2>/dev/null) || tail40='' ;;
  esac
  fm_busy_classify "$TASK_BACKEND" "$1" "$HARNESS" "$ID" "$STATE" "$tail40"
}

# --- no-mistakes run lookup (authoritative when a run matches this branch) --
# trim, strip_quotes, the bounded nm_run call, nm_field's TOON parse, and the
# branch+head attribution rule below are thin wrappers over the ONE owner in
# bin/fm-nm-run-lib.sh, shared with fm-teardown.sh's pre-teardown run abort.

trim() { fm_nm_trim "$@"; }
strip_quotes() { fm_nm_strip_quotes "$@"; }
nm_run() {  # <args...>
  fm_nm_run "$WT" "$NM_TIMEOUT" "$@"
}

# 0 when a bounded no-mistakes call NEVER COMPLETED, so nothing was learned: it
# timed out (124), was killed by a signal (>128), or there was no timeout
# mechanism to bound it at all (fm_nm_run_bounded returns 1 with no output).
# The discrimination is on COMPLETION, not on whether anything was printed: an
# exit-0 silence is a real answer ("no run"), while a silent timeout is not.
# ONE owner, so every run-source call feeds RUN_READ by the same rule instead of
# each call site inventing its own honesty test.
nm_read_incomplete() {  # <exit-code> <output>
  [ "$1" -eq 124 ] || [ "$1" -gt 128 ] || { [ "$1" -ne 0 ] && [ -z "$2" ]; }
}

# Scalar value of a TOON key in the captured run output ($RUN_OUT).
RUN_OUT=""
nm_field() {  # <key>
  fm_nm_field "$RUN_OUT" "$1"
}
# Finding count from a findings[N]{...} table header; empty when none.
nm_findings_count() {
  printf '%s\n' "$RUN_OUT" | grep -oE 'findings\[[0-9]+\]' | head -1 | grep -oE '[0-9]+'
}
nm_gate_step_row() {
  local row step rest status findings
  row=$(printf '%s\n' "$RUN_OUT" | grep -E '^[[:space:]]*[^,]+,[[:space:]]*"?(awaiting_approval|fix_review)"?[[:space:]]*,' | head -1)
  [ -n "$row" ] || return 0
  row=$(trim "$row")
  step=$(trim "${row%%,*}")
  rest=${row#*,}
  status=$(strip_quotes "$(trim "${rest%%,*}")")
  rest=${rest#*,}
  findings=$(trim "${rest%%,*}")
  printf '%s|%s|%s' "$step" "$status" "$findings"
}
nm_gate_status() {
  local s row
  s=$(printf '%s\n' "$RUN_OUT" | grep -E '^[[:space:]]*(status|state):[[:space:]]*"?(awaiting_approval|fix_review)"?[[:space:]]*$' | head -1)
  if [ -n "$s" ]; then
    s=$(strip_quotes "$(trim "${s#*:}")")
    printf '%s' "$s"
    return
  fi
  row=$(nm_gate_step_row)
  [ -n "$row" ] && { row=${row#*|}; printf '%s' "${row%%|*}"; }
}
nm_has_gate() {
  printf '%s\n' "$RUN_OUT" | grep -Eq '^[[:space:]]*gate:[[:space:]]*'
}
nm_gate_line_name() {
  local gate step
  gate=$(strip_quotes "$(nm_field gate)")
  [ -n "$gate" ] && { printf '%s' "$gate"; return; }
  step=$(printf '%s\n' "$RUN_OUT" | sed -n '/^[[:space:]]*gate:[[:space:]]*$/,/^[^[:space:]][^:]*:/s/^[[:space:]]*step:[[:space:]]*\(.*\)/\1/p' | head -1)
  step=$(strip_quotes "$step")
  [ -n "$step" ] && printf '%s' "$step"
}
nm_gate_name() {
  local gate row
  gate=$(nm_gate_line_name)
  [ -n "$gate" ] && { printf '%s' "$gate"; return; }
  row=$(nm_gate_step_row)
  [ -n "$row" ] && printf '%s' "${row%%|*}"
}
nm_gate_findings_count() {
  local f row rest
  f=$(nm_findings_count)
  [ -n "$f" ] && { printf '%s' "$f"; return; }
  row=$(nm_gate_step_row)
  [ -n "$row" ] || return 0
  rest=${row#*|}
  rest=${rest#*|}
  rest=${rest%%|*}
  case "$rest" in ''|*[!0-9]*) return 0 ;; esac
  printf '%s' "$rest"
}
log_reports_ci_ready() {
  [ "$LOG_VERB" = "done" ] || return 1
  case "$(status_line_note "$LOG_LINE")" in
    *PR*"checks green"*|*"checks green"*PR*) return 0 ;;
    *) return 1 ;;
  esac
}

nm_ci_step_status() {
  local row rest
  row=$(printf '%s\n' "$RUN_OUT" | grep -E '^[[:space:]]*ci,[[:space:]]*"?(running|fixing)"?[[:space:]]*,' | head -1)
  [ -n "$row" ] || return 0
  row=$(trim "$row")
  rest=${row#*,}
  strip_quotes "$(trim "${rest%%,*}")"
}

nm_effective_ci_step_status() {
  local step_status
  if [ "${RUN_STATUS:-}" = fixing ]; then
    printf 'fixing'
    return 0
  fi
  step_status=$(nm_ci_step_status)
  if [ -n "$step_status" ]; then
    printf '%s' "$step_status"
    return 0
  fi
  if [ "${RUN_STATUS:-}" = ci ]; then
    printf 'running'
  fi
}

# Root cause of the PR #252 incident (2026-07): for a repo where merge is left
# to the captain, no-mistakes' ci step (and therefore top-level status/outcome)
# stays "running" for the ENTIRE CI-monitor phase, including long after GitHub
# reports every check green - it only reaches outcome=passed once the PR is
# actually merged (or failed/cancelled if closed). `axi status`'s steps[] table
# never distinguishes "still waiting on checks" from "checks green, waiting on
# merge": both read as plain `ci,running,...`. The only place that transition is
# recorded is the ci step's own log text, e.g. "all CI checks passed - still
# monitoring until merged or closed" or "no CI checks reported - still
# monitoring until merged or closed" (verified against 360+ real run logs under
# ~/.no-mistakes/logs/*/ci.log on the installed v1.32.2 binary, including the
# actual PR #252 run). Reads the ci step's log tail via `axi logs` and scans it
# for the MOST RECENT recognized marker (the log is append-only/chronological,
# so the last match is current): green with nothing red after it means CI is
# green right now, still only waiting on merge/close.
nm_ci_checks_state() {
  local run_id log_tail marker
  run_id=$(strip_quotes "$(nm_field id)")
  [ -n "$run_id" ] || { printf 'unknown'; return; }
  log_tail=$(nm_run axi logs --step ci --run "$run_id") || true
  [ -n "$log_tail" ] || { printf 'unknown'; return; }
  marker=$(printf '%s\n' "$log_tail" \
    | grep -E 'CI checks passed|no CI checks reported - still monitoring|no CI checks reported yet|checks failed|issues detected|CI checks running|base branch advanced.*re-arming CI monitor timeout' \
    | tail -1)
  case "$marker" in
    *"checks passed"*|*"no CI checks reported - still monitoring"*) printf 'green' ;;
    *"no CI checks reported yet"*|*"checks failed"*|*"issues detected"*|*"CI checks running"*|*"base branch advanced"*"re-arming CI monitor timeout"*) printf 'not-ready' ;;
    *) printf 'unknown' ;;
  esac
}
# Coarse fallback for cross-branch attribution. `no-mistakes axi status` (bare)
# reports the active-or-most-recent run for the CURRENT branch when one
# exists, else falls back to some other branch's run purely as informational
# display (verified empirically: querying a worktree with its own active run
# reliably returns that run, even under concurrent load from several other
# validating crews on the same underlying repo). A crew whose branch genuinely
# has no run yet therefore sees another branch's answer here.
#
# This fallback used to shell out to `no-mistakes axi` (bare, no subcommand)
# expecting a `runs[N]{id,branch,status,...}:` TOON table and re-query the
# matched id via `axi status --run <id>`. Verified against the real installed
# CLI (v1.32.2): the `axi` surface exposes only abort/logs/respond/run/status -
# there is no runs-listing subcommand under `axi` at all, so that table never
# appears and the lookup was silently dead code; whenever the bare `axi
# status` answer was not this crew's own branch, attribution always failed and
# the caller fell straight through to the pane/log fallback below. (The
# PRIMARY cause of the 2026-07 herdr false-surface incidents turned out to be
# a separate bug in bin/fm-watch.sh's stale_is_terminal precedence - see that
# file's history - but this cross-branch path was independently confirmed
# dead code and is worth having actually work.)
#
# The real run-listing command is the top-level `no-mistakes runs` (verified:
# `no-mistakes --help` lists it separately from `axi`). It is plain, human-
# oriented text - no run id, no JSON/TOON, newest-first, columns
# "<status> <branch> <short-sha> <date> [<pr-url>]" separated by runs of
# spaces (verified: no quoting, so splitting on the first two whitespace runs
# is exact) - but branch + coarse status is exactly what this predicate needs:
# is a run for THIS branch active right now. Echoes the first (most recent)
# matching row's status word (running/completed/cancelled/failed), or empty
# when the branch has no run within FM_CREW_STATE_RUNS_LIMIT rows.
#
# Sets COARSE_STATUS rather than printing it, so a call that never completed can
# also set RUN_READ - a command substitution would trap that in a subshell and
# leave an unanswered listing byte-indistinguishable from "this branch has no
# rows", which is the same collapse RUN_READ exists to prevent on the primary
# call. RUN_READ stays the ONE owner of "did the run source answer".
nm_runs_status_for_branch() {  # <branch>
  local branch=$1 out rc row st rest br sha
  COARSE_STATUS=""
  out=$(fm_nm_run_checked "$WT" "$NM_TIMEOUT" runs --limit "$FM_CREW_STATE_RUNS_LIMIT")
  rc=$?
  if nm_read_incomplete "$rc" "$out"; then
    RUN_READ=unreadable
    return 0
  fi
  [ -n "$out" ] || return 0
  while IFS= read -r row; do
    row=$(trim "$row")
    [ -n "$row" ] || continue
    st=${row%% *}
    rest=${row#* }
    rest=$(trim "$rest")
    br=${rest%% *}
    rest=${rest#* }
    rest=$(trim "$rest")
    sha=${rest%% *}
    [ "$br" = "$branch" ] || continue
    # The branch's NEWEST row decides, and the walk stops here either way, so a
    # superseded older row can never revive as this crew's current state.
    if fm_nm_status_is_active "$st"; then
      # A run the pipeline is still running on this crew's branch IS this
      # crew's run. Demanding a code-identity match here is what made a
      # healthy validating lane invisible: the pipeline commits its fix
      # rounds into its own clone, so the run head is routinely unresolvable
      # in this worktree exactly while the run is healthiest
      # (fm_nm_head_matches_worktree's note owns the mechanism).
      COARSE_STATUS=$st
    elif nm_coarse_head_matches_worktree "$sha"; then
      # A FINISHED row must still prove code identity, so a historical run on
      # a reused or rewritten branch is never attributed to current code.
      COARSE_STATUS=$st
    fi
    return 0
  done <<< "$out"
  return 0
}

# CREW_BRANCH is empty at detached HEAD (a just-spawned crew, or a scout's
# scratch worktree); with no branch there is no run to attribute to this crew.
CREW_BRANCH=$(git -C "$WT" symbolic-ref --quiet --short HEAD 2>/dev/null || true)

# 0 if the active axi-status run's head field matches this worktree's code
# identity. Branch match is a precondition (caller). Rule owned by
# fm_nm_head_matches_worktree in bin/fm-nm-run-lib.sh.
nm_run_head_matches_worktree() {
  local run_head
  run_head=$(strip_quotes "$(nm_field head)")
  fm_nm_head_matches_worktree "$WT" "$run_head"
}

# Coarse runs-list rows are "<status> <branch> <short-sha> ...". 0 if the short
# sha for this branch row matches the worktree head under the same rules as
# nm_run_head_matches_worktree (equal, or local is ancestor of run tip).
nm_coarse_head_matches_worktree() {  # <short-sha>
  fm_nm_head_matches_worktree "$WT" "$1"
}

# no-mistakes' own structural statement about who owns the branch right now,
# from the branch_sync block of `axi status` (`state: pipeline_owned` while a
# run holds the branch). Scoped to that block so an unrelated `state:` key
# elsewhere in the record cannot answer for it.
nm_branch_sync_state() {
  local s
  s=$(printf '%s\n' "$RUN_OUT" \
    | sed -n '/^[[:space:]]*branch_sync:[[:space:]]*$/,/^[^[:space:]]/p' \
    | sed -n 's/^[[:space:]]*state:[[:space:]]*\(.*\)/\1/p' | head -1)
  strip_quotes "$s"
}

# 0 when this `axi status` record is a run the pipeline is holding RIGHT NOW for
# this worktree's branch. Two independent facts must both hold:
#   - the run is not finished (no outcome, non-terminal status), and
#   - the branch_sync block reports a live pipeline relationship to this branch.
# This outranks head identity, deliberately: the run head of a healthy run is
# routinely unresolvable in this worktree (see fm_nm_head_matches_worktree's
# note), so a sha comparison cannot answer "is this run live". Attributing the
# `axi status` record itself - rather than letting it fall through to the coarse
# runs list - is what preserves gate detail, so a live run PARKED at a gate with
# a diverged head still reports `parked`, not a flat `working`.
#
# Observed branch_sync.state values on live runs (no-mistakes v1.46.0):
# `pipeline_owned` while the pipeline holds the branch, and `behind` once its
# fix commits have advanced past the crew's worktree. Any other value, or an
# absent block, falls through to head binding, so a vocabulary this function
# does not recognize NEVER grants attribution on its own.
nm_pipeline_run_is_live() {
  local st
  [ -z "$(strip_quotes "$(nm_field outcome)")" ] || return 1
  st=$(strip_quotes "$(nm_field status)")
  ! fm_nm_status_is_terminal "$st" || return 1
  case "$(nm_branch_sync_state)" in
    pipeline_owned|behind) return 0 ;;
  esac
  return 1
}

HAVE_RUN=0
# RUN_SOURCE distinguishes the two ways HAVE_RUN=1 can happen: "full" means
# $RUN_OUT is real `axi status` TOON with step/gate detail; "coarse" means only
# a bare status word came back from the runs-list fallback above, so the
# run-step block below skips the TOON field parsing entirely for this crew.
RUN_SOURCE=full
COARSE_STATUS=""
# How the RUN SOURCE itself answered, which is NOT the same question as whether
# a run was attributed. Kept distinct because collapsing them is the reporting
# defect this variable exists to prevent: "the pipeline has no live run for this
# crew" is a measured fact, while "the pipeline did not answer" is an absence of
# measurement, and only the first may be spent as evidence about the crew.
#   skipped    - no run source applies (scout/secondmate, detached HEAD, no CLI)
#   answered   - the CLI ran to completion; whatever it said, including an error
#                such as `error: repo not initialized` (verified: written to
#                stdout, exit 1) or a silent "no runs", is a MEASUREMENT
#   unreadable - the bounded call never completed: it timed out (124), was killed
#                by a signal (>128), or there was no timeout mechanism to bound
#                it at all, in which case nothing ran and nothing was learned
RUN_READ=skipped
# Scouts and secondmates never drive a no-mistakes validation of their own
# worktree, so skip the lookup for them and read state from pane/log directly.
if [ "$KIND" = ship ] && [ -n "$CREW_BRANCH" ] && command -v no-mistakes >/dev/null 2>&1; then
  RUN_OUT=$(fm_nm_run_checked "$WT" "$NM_TIMEOUT" axi status)
  RUN_RC=$?
  if nm_read_incomplete "$RUN_RC" "$RUN_OUT"; then
    RUN_READ=unreadable
  else
    RUN_READ=answered
  fi
  if [ -n "$RUN_OUT" ] && [ "$RUN_READ" = answered ]; then
    run_branch=$(strip_quotes "$(nm_field branch)")
    if [ -n "$run_branch" ] && [ "$run_branch" = "$CREW_BRANCH" ] &&
       { nm_run_head_matches_worktree || nm_pipeline_run_is_live; }; then
      HAVE_RUN=1
    else
      # The active-or-most-recent run is for another branch, or same branch with
      # a rewritten/diverged head (the CLI is alive and answered; only the
      # attribution missed) - try the coarse fallback.
      # Deliberately nested inside `[ -n "$RUN_OUT" ]`: an empty/timed-out
      # primary call means the CLI itself did not respond, so retrying it
      # immediately with a second bounded call would just double the wait
      # for no better answer.
      nm_runs_status_for_branch "$CREW_BRANCH"
      if [ -n "$COARSE_STATUS" ]; then
        HAVE_RUN=1
        RUN_SOURCE=coarse
      fi
    fi
  fi
fi

# --- run-step authoritative path -------------------------------------------

if [ "$HAVE_RUN" = 1 ]; then
  RUN_STATE=working
  RUN_DETAIL=""
  CI_STEP_STATUS=""
  CI_LOG_STATE=""
  RUN_STATUS=""
  if [ "$RUN_SOURCE" = coarse ]; then
    # No step/gate detail is available from the plain runs list - only ever
    # true/working, done, or failed. A crew genuinely parked at a gate still
    # gets full detail once `axi status` reports its own branch again (e.g.
    # once its own step is the most-recently-touched one), and its own
    # needs-decision/blocked status-log append (a captain-relevant VERB) is
    # surfaced through signal_reason_is_actionable regardless of this
    # coarse-vs-full distinction, so a real gate is never silently missed.
    case "$COARSE_STATUS" in
      running)   RUN_STATE=working; RUN_DETAIL="validating (background run)" ;;
      # fm_nm_status_is_active owns which words mean "the pipeline is still
      # running this row", and it accepts `pending` too. Without an arm here a
      # queued run - now attributed on branch alone - would fall to the `*` arm
      # and report `unknown`, which downstream maps to the measured fact that
      # the crew stopped.
      pending)   RUN_STATE=working; RUN_DETAIL="validating (queued)" ;;
      completed) RUN_STATE="done";  RUN_DETAIL="run completed" ;;
      failed)    RUN_STATE=failed;  RUN_DETAIL="run failed" ;;
      cancelled) RUN_STATE=failed;  RUN_DETAIL="run cancelled" ;;
      *)         RUN_STATE=unknown; RUN_DETAIL="runs list status: $COARSE_STATUS" ;;
    esac
  else
    status=$(strip_quotes "$(nm_field status)")
    RUN_STATUS=$status
    outcome=$(strip_quotes "$(nm_field outcome)")
    awaiting=$(printf '%s\n' "$RUN_OUT" | grep -E '^[[:space:]]*awaiting_agent:' | head -1 || true)
    gate_status=$(nm_gate_status)
    has_gate=0
    nm_has_gate && has_gate=1

    if [ -n "$outcome" ]; then
      case "$outcome" in
        passed)        RUN_STATE="done"; RUN_DETAIL="run passed: PR merged/closed" ;;
        checks-passed) RUN_STATE="done"; RUN_DETAIL="checks green: PR ready for review" ;;
        failed)        RUN_STATE=failed; RUN_DETAIL="run failed" ;;
        cancelled)     RUN_STATE=failed; RUN_DETAIL="run cancelled" ;;
        *)             RUN_STATE=unknown; RUN_DETAIL="outcome: $outcome" ;;
      esac
    elif [ -n "$awaiting" ] || [ "$status" = awaiting_approval ] || [ "$status" = fix_review ] || [ -n "$gate_status" ] || [ "$has_gate" = 1 ]; then
      if [ "$has_gate" = 1 ]; then
        gate=$(nm_gate_line_name)
      else
        gate=$(nm_gate_name)
      fi
      [ -n "$gate" ] || gate=$status
      [ -n "$gate" ] || gate=gate
      RUN_STATE=parked
      RUN_DETAIL="parked at $gate"
      fcount=$(nm_gate_findings_count)
      [ -n "$fcount" ] && RUN_DETAIL="$RUN_DETAIL: $fcount finding(s)"
      if printf '%s\n' "$RUN_OUT" | grep -q 'ask-user'; then
        RUN_DETAIL="$RUN_DETAIL (ask-user: authority decision)"
      fi
    else
      case "$status" in
        ci)             RUN_STATE=working; RUN_DETAIL="ci running" ;;
        running|fixing) RUN_STATE=working; RUN_DETAIL="validating ($status)" ;;
        completed)      RUN_STATE="done"; RUN_DETAIL="run completed" ;;
        failed)         RUN_STATE=failed;  RUN_DETAIL="run failed" ;;
        cancelled)      RUN_STATE=failed;  RUN_DETAIL="run cancelled" ;;
        "")             RUN_STATE=working; RUN_DETAIL="run active" ;;
        *)              RUN_STATE=working; RUN_DETAIL="run active ($status)" ;;
      esac
      if [ "$RUN_STATE" = working ]; then
        CI_STEP_STATUS=$(nm_effective_ci_step_status)
        case "$CI_STEP_STATUS" in
          running)
            CI_LOG_STATE=$(nm_ci_checks_state)
            if [ "$CI_LOG_STATE" = green ]; then
              RUN_STATE="done"
              RUN_DETAIL="checks green: PR ready for review (still monitoring for merge/close)"
            fi
            ;;
          fixing)
            CI_LOG_STATE=not-ready
            ;;
        esac
      fi
    fi
  fi

  if [ "$RUN_STATE" = working ] && log_reports_ci_ready; then
    if [ "$RUN_SOURCE" = coarse ]; then
      emit "done" status-log "$(status_line_note "$LOG_LINE")${SEP}run still monitoring PR"
    fi
    [ -n "$CI_STEP_STATUS" ] || CI_STEP_STATUS=$(nm_effective_ci_step_status)
    if [ "$RUN_STATUS" = fixing ]; then
      CI_LOG_STATE=not-ready
    elif [ "$CI_STEP_STATUS" = running ] && [ -z "$CI_LOG_STATE" ]; then
      CI_LOG_STATE=$(nm_ci_checks_state)
    elif [ "$CI_STEP_STATUS" = fixing ]; then
      CI_LOG_STATE=not-ready
    fi
    if [ "$CI_LOG_STATE" != not-ready ]; then
      emit "done" status-log "$(status_line_note "$LOG_LINE")${SEP}run still monitoring PR"
    fi
  fi

  # Reconcile the status log. A needs-decision/blocked log line that the run-step
  # has moved past (anything but a genuinely parked run) is deterministically
  # stale: the gate resolved and the run resumed or finished.
  case "$LOG_VERB" in
    needs-decision|blocked)
      if [ "$RUN_STATE" != parked ]; then
        if [ "$RUN_STATE" = working ]; then
          RUN_DETAIL="$RUN_DETAIL${SEP}status-log superseded by active run"
        else
          RUN_DETAIL="$RUN_DETAIL${SEP}status-log superseded (run $RUN_STATE)"
        fi
      fi
      ;;
  esac

  emit "$RUN_STATE" run-step "$RUN_DETAIL"
fi

# --- fallback: no run attributed to this crew ------------------------------
# The run-step path above already handled any crew with a run, regardless of pane
# liveness, so a finished-but-pane-closed crew never reaches here. Down here there
# is no run to consult, so a dead/unreadable target means the crew is gone: report
# unknown rather than trusting a possibly-stale status log as the current state.
#
# The endpoint is probed FIRST, and its verdict gates the busy read below, in
# BOTH the measured and the unmeasured case. The gate itself is never skipped:
# crew_busy_verdict's primary source is the persisted state/<id>.busy-state
# record, which is validated by generation match with no time expiry, so a crew
# killed mid-turn leaves `state=busy` on disk indefinitely. Reading that record
# without first confirming the pane still exists would report a DEAD crew as a
# measured `working - source: pane` - inventing a measurement, which is worse
# than the collapse this whole distinction exists to prevent (measured live
# 2026-08-13: two crews whose agent process had exited, whose correct wedge
# alarms were then absorbed by hand as false ones).
ENDPOINT_GONE=""
if [ -z "$BACKEND_TARGET" ]; then
  ENDPOINT_GONE="no backend target recorded"
# A worker placed on another host has no locally observable endpoint, so the
# liveness gate would report every healthy one gone. Its state comes from the
# status log the remote worker keeps writing here.
elif ! fm_backend_is_remote_placement "$META" && ! pane_readable "$BACKEND_TARGET"; then
  ENDPOINT_GONE="backend target gone: $BACKEND_TARGET"
fi

# What a gone endpoint PROVES depends on whether the run question was answered:
#   - RUN_READ=answered/skipped: it is MEASURED that no run owns this crew, so a
#     dead endpoint does mean the crew is gone.
#   - RUN_READ=unreadable: nobody found out whether a run owns this crew, and
#     this script deliberately treats an attributed run as authoritative even
#     when the pane has closed, so a dead endpoint cannot establish a stop while
#     that question is unanswered. Route it to the `unreadable` emit below
#     instead, so it can never pre-empt it into `unknown - source: none -
#     backend target gone` - byte-identical to a measured stop, and exactly the
#     input stuck-crewmate-recovery would turn into a relaunch.
if [ -n "$ENDPOINT_GONE" ] && [ "$RUN_READ" != unreadable ]; then
  emit unknown none "$ENDPOINT_GONE"
fi

# Secondmates idle on their own watcher (idle pane = healthy), so the busy
# state is not meaningful for them; read their state from the status log only.
# Only an exact busy verdict reports working here, and only an exact idle
# verdict permits the status-log fallback below. Missing, malformed, stale, or
# unverified semantic state remains unknown.
if [ "$KIND" != secondmate ] && [ -z "$ENDPOINT_GONE" ]; then
  BUSY_VERDICT=$(crew_busy_verdict "$BACKEND_TARGET")
  case "${BUSY_VERDICT%% *}" in
    busy) emit working pane "harness busy (${BUSY_VERDICT#* })" ;;
    idle) ;;
    # An unavailable harness state is not a measurement either. With the run
    # source also unread there is nothing measured at all, so say so once, below,
    # instead of reporting a second absence as this crew's current state.
    *) [ "$RUN_READ" = unreadable ] || emit unknown pane "harness state unavailable ($BUSY_VERDICT)" ;;
  esac
fi

# The run source did not answer, and nothing above measured this crew directly.
# `unreadable` is deliberately its own state, not another `unknown`, because a
# supervisor must be able to tell "this crew has no live run" from "I could not
# find out" - the two justify opposite actions, and rendering them identically is
# what makes an alarm unspendable. Emitted before the status-log fallback for the
# same reason: the log is an append-only EVENT log, so promoting its last line to
# current state is worst exactly when the authoritative source is down.
if [ "$RUN_READ" = unreadable ]; then
  emit unreadable run-source "validation state could not be read (no-mistakes did not answer within ${NM_TIMEOUT}s)"
fi

# Fall back to the status log's last line, but ONLY when its verb maps to a real
# run-state. A decision-closing event - resolved: (fm-classify-lib.sh's
# FM_CLASSIFY_RESOLVE_VERB), and any future decision-only sibling - is NOT a state:
# it exists solely to CLOSE a keyed decision in the durable fold, so a trailing
# resolved: must never become the current state or leak its resolution prose as the
# detail. Skipping it lets a just-resolved idle crew (typically a secondmate, which
# has no busy check above) fall through to the idle default instead of rendering
# `unknown` with the resolution note as `doing`. map_log_state is the single owner of
# the verb->state mapping (including the configurable paused verb), so reusing its
# `unknown` verdict as the "not a state" test needs no second verb list here.
if [ -n "$LOG_VERB" ]; then
  LOG_STATE=$(map_log_state "$LOG_LINE")
  if [ "$LOG_STATE" != unknown ]; then
    emit "$LOG_STATE" status-log "$(status_line_note "$LOG_LINE")"
  fi
fi

# Distinct from the `unreadable` emit above: here the run source WAS consulted
# and reported no live run for this crew, so "nothing to report" is itself a
# measurement rather than a gap in one.
if [ "$RUN_READ" = answered ]; then
  emit unknown none "no live validation run for this branch, and no other current-state source available"
fi
emit unknown none "no current-state source available"
