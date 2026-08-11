#!/usr/bin/env bash
# tests/fm-backend-tmux-smoke.test.sh - real tmux smoke test for the tmux
# session-provider adapter (bin/backends/tmux.sh), the P1 checklist item
# "run a real tmux smoke test (create session, send text + Enter, capture,
# list, kill)" from data/fm-backend-design-d7/report.md. Every other suite in
# this repo fakes tmux; this one is the one place that talks to a REAL tmux
# server, isolated on a private socket (`-L`) so it never touches the host's
# actual sessions.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() { printf 'not ok - %s\n' "$1" >&2; cleanup_all; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

wait_for_capture_text() {  # <target> <text> [samples]
  local target=$1 text=$2 samples=${3:-100} out i=0
  while [ "$i" -lt "$samples" ]; do
    out=$(fm_backend_tmux_capture "$target" 200 2>/dev/null || true)
    case "$out" in
      *"$text"*) return 0 ;;
    esac
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

command -v tmux >/dev/null 2>&1 || { echo "skip: tmux not found"; exit 0; }
REAL_TMUX=$(command -v tmux)
SOCKET="fm-backend-smoke-$$"
SHIM_DIR=
trap cleanup_all EXIT

cleanup_all() {
  "$REAL_TMUX" -L "$SOCKET" kill-server >/dev/null 2>&1 || true
  [ -n "${SHIM_DIR:-}" ] && rm -rf "$SHIM_DIR"
}

# A `tmux` shim on PATH that transparently redirects every call to the private
# socket, so bin/backends/tmux.sh's bare `tmux ...` invocations never touch the
# host's real sessions.
SHIM_DIR=$(mktemp -d "${TMPDIR:-/tmp}/fm-backend-smoke.XXXXXX")
cat > "$SHIM_DIR/tmux" <<SH
#!/usr/bin/env bash
exec "$REAL_TMUX" -L "$SOCKET" "\$@"
SH
chmod +x "$SHIM_DIR/tmux"
PATH="$SHIM_DIR:$PATH"
export PATH

# shellcheck source=/dev/null
. "$ROOT/bin/fm-backend.sh"
fm_backend_source tmux || fail "fm_backend_source tmux failed"

SESSION="smoke"
WINDOW="fm-smoke1"
TARGET="$SESSION:$WINDOW"

# --- create session ----------------------------------------------------------

tmux new-session -d -s "$SESSION" -x 200 -y 50 \
  || fail "real tmux: new-session failed"
fm_backend_tmux_create_task "$SESSION" "$WINDOW" "$HOME" \
  || fail "fm_backend_tmux_create_task failed to create the task window"
tmux list-windows -t "$SESSION" -F '#{window_name}' | grep -qx "$WINDOW" \
  || fail "created window is not visible in the real session"

# A second create for the SAME window name must refuse (mirrors fm-spawn.sh's
# duplicate-window guard).
if fm_backend_tmux_create_task "$SESSION" "$WINDOW" "$HOME" 2>/dev/null; then
  fail "fm_backend_tmux_create_task should refuse an existing window name"
fi
pass "real tmux: fm_backend_tmux_create_task creates a window and refuses a duplicate"

# --- send text + Enter -------------------------------------------------------

# A newly-created interactive shell can exist before its startup files and line
# editor are ready to accept Enter. Prove command execution with an output token
# that does not appear contiguously in the command, retrying the harmless probe
# until the shell acknowledges it.
SHELL_READY=false
for _ in $(seq 1 100); do
  tmux send-keys -t "$TARGET" C-c
  tmux send-keys -t "$TARGET" -l "printf 'shell-%s\\n' ready"
  tmux send-keys -t "$TARGET" Enter
  if wait_for_capture_text "$TARGET" "shell-ready" 10; then
    SHELL_READY=true
    break
  fi
done
[ "$SHELL_READY" = true ] || fail "the tmux task shell did not become ready"

tmux send-keys -t "$TARGET" "cd /tmp && PS1='smoke\$ ' && clear && printf 'setup-%s\\n' ready" Enter
wait_for_capture_text "$TARGET" "setup-ready" || fail "the tmux task shell did not complete setup"

fm_backend_tmux_send_text_line "$TARGET" "printf 'captain-on-deck-%s\\n' line" \
  || fail "fm_backend_tmux_send_text_line failed"
wait_for_capture_text "$TARGET" "captain-on-deck-line" \
  || fail "fm_backend_tmux_send_text_line did not execute"
out=$(fm_backend_tmux_capture "$TARGET" 20) || fail "fm_backend_tmux_capture failed after send_text_line"
case "$out" in
  *captain-on-deck-line*) : ;;
  *) fail "real tmux: fm_backend_tmux_send_text_line did not submit and echo the line"$'\n'"$out" ;;
esac
pass "real tmux: fm_backend_tmux_send_text_line sends literal text and submits with Enter"

# --- send_literal + send_key(Enter), the two-step form fm-spawn.sh uses for the
# harness launch command (literal send, settle, then a separate Enter) --------

fm_backend_tmux_send_literal "$TARGET" "printf 'literal-then-key-%s\\n' captain" \
  || fail "fm_backend_tmux_send_literal failed"
fm_backend_tmux_send_key "$TARGET" Enter || fail "fm_backend_tmux_send_key Enter failed"
wait_for_capture_text "$TARGET" "literal-then-key-captain" \
  || fail "fm_backend_tmux_send_literal + fm_backend_tmux_send_key Enter did not execute"
out=$(fm_backend_tmux_capture "$TARGET" 20) || fail "fm_backend_tmux_capture failed after send_literal+send_key"
case "$out" in
  *literal-then-key-captain*) : ;;
  *) fail "real tmux: send_literal + send_key(Enter) did not submit and echo the line"$'\n'"$out" ;;
esac
pass "real tmux: fm_backend_tmux_send_literal + fm_backend_tmux_send_key Enter submit as two separate steps"

# --- capture bounds -----------------------------------------------------------
# Print enough numbered lines to overflow the pane's visible height, then
# confirm a small capture window (-S -N) surfaces only the RECENT tail (the
# earliest lines scroll out of a small window) while a large one reaches back
# far enough to still see the earliest line - the same -S -N bounding fm-peek.sh
# and fm-watch.sh rely on for a bounded, cheap pane read.
fm_backend_tmux_send_text_line "$TARGET" "for i in \$(seq 1 80); do echo tag-line-\$i; done"
wait_for_capture_text "$TARGET" "tag-line-80" \
  || fail "the numbered output did not complete before capture"
small=$(fm_backend_tmux_capture "$TARGET" 3) || fail "fm_backend_tmux_capture (small window) failed"
case "$small" in
  *tag-line-1$'\n'*) fail "a 3-line capture should not still see the very first numbered line"$'\n'"$small" ;;
esac
case "$small" in
  *tag-line-80*) : ;;
  *) fail "a 3-line capture should still contain the most recent output"$'\n'"$small" ;;
esac
large=$(fm_backend_tmux_capture "$TARGET" 200) || fail "fm_backend_tmux_capture (large window) failed"
case "$large" in
  *tag-line-1$'\n'*) : ;;
  *) fail "a 200-line capture should reach back far enough to see the first numbered line"$'\n'"$large" ;;
esac
pass "real tmux: fm_backend_tmux_capture's -S -N bound trims old history for a small window and reaches it for a large one"

# --- resolve_bare_selector (live-window-listing) -----------------------------

resolved=$(fm_backend_tmux_resolve_bare_selector "$WINDOW") \
  || fail "fm_backend_tmux_resolve_bare_selector failed to find the live window"
[ "$resolved" = "$TARGET" ] || fail "fm_backend_tmux_resolve_bare_selector resolved to '$resolved', expected '$TARGET'"
pass "real tmux: fm_backend_tmux_resolve_bare_selector (list-live) finds the created window by name"

if fm_backend_tmux_resolve_bare_selector "no-such-window-xyz" 2>/dev/null; then
  fail "fm_backend_tmux_resolve_bare_selector should fail for a nonexistent window"
fi
pass "real tmux: fm_backend_tmux_resolve_bare_selector fails for a window that does not exist"

# --- fm_backend_target_exists: alive before kill, dead after ----------------
# The window under test is presence-checked while it is still live, then again
# after it is killed but the session itself remains live (window 0 survives) -
# the exact "missing window inside a live session" shape that a naive
# tmux display-message read gets wrong (verified empirically, tmux 3.7b:
# docs/verification/runtime-backends.md).

fm_backend_target_exists tmux "$TARGET" \
  || fail "fm_backend_target_exists should report the live window alive"
pass "real tmux: fm_backend_target_exists reports a live window alive"

# A sibling window whose name strictly EXTENDS the window under test, so the
# post-kill checks below cover tmux's start-of-name target resolution: an
# unanchored `smoke:fm-smoke1` lookup resolves to the live `fm-smoke1-sibling`
# and reads a dead endpoint as alive. Task windows are `fm-<task-id>` over
# free-form slugs, so this collision is reachable in a real fleet (a crashed
# `auth` next to a live `auth-fix`).
SIBLING="$WINDOW-sibling"
fm_backend_tmux_create_task "$SESSION" "$SIBLING" "$HOME" \
  || fail "could not create the name-extending sibling window"

# --- kill and recovery-grade missing-window classification ------------------

fm_backend_tmux_kill "$TARGET"
if tmux list-windows -t "$SESSION" -F '#{window_name}' 2>/dev/null | grep -qx "$WINDOW"; then
  fail "fm_backend_tmux_kill did not remove the window"
fi

tmux has-session -t "$SESSION" >/dev/null 2>&1 \
  || fail "the session itself must still be live after killing only its second window"

if fm_backend_target_exists tmux "$TARGET" 2>/dev/null; then
  fail "fm_backend_target_exists should report a killed window dead even though its session is still live and a window whose name extends it ($SIBLING) is live"
fi
pass "real tmux: fm_backend_target_exists reports a killed window dead while its session and a name-extending sibling stay live"

fm_backend_target_exists tmux "$SESSION:$SIBLING" \
  || fail "the live name-extending sibling window must still read alive"
pass "real tmux: fm_backend_target_exists still reports the live name-extending sibling alive"

if fm_backend_target_exists tmux "$SESSION:${WINDOW%1}" 2>/dev/null; then
  fail "fm_backend_target_exists should report a window name that is only a PREFIX of live windows dead"
fi
pass "real tmux: fm_backend_target_exists reports a bare name prefix of live windows dead"

# The session part prefix-resolves the same way, both inside a session:window
# target and for a bare session-name-only target.
fm_backend_target_exists tmux "$SESSION" \
  || fail "the live session itself must read alive as a bare session-name target"
if fm_backend_target_exists tmux "${SESSION%e}" 2>/dev/null; then
  fail "a bare session name that is only a PREFIX of the live session must read dead"
fi
if fm_backend_target_exists tmux "${SESSION%e}:$SIBLING" 2>/dev/null; then
  fail "a session name that is only a PREFIX of the live session must read dead"
fi
pass "real tmux: fm_backend_target_exists anchors the session part too, bare and qualified"

# A pane id is already exact and must stay unanchored - `=%N` resolves nothing.
live_pane=$(tmux display-message -p -t "$SESSION:$SIBLING" '#{pane_id}')
[ -n "$live_pane" ] || fail "could not read a live pane id to check pane-id targeting"
fm_backend_target_exists tmux "$live_pane" \
  || fail "a live pane id target must read alive (the supervisor daemon's \$TMUX_PANE default)"
if fm_backend_target_exists tmux '%999' 2>/dev/null; then
  fail "an absent pane id must read dead"
fi
pass "real tmux: fm_backend_target_exists reads bare pane-id targets alive and dead correctly"

# A window name containing a literal `.` - reachable through the ordinary spawn
# path, since task ids may contain dots and the window is named `fm-<task-id>`.
# tmux splits a target's window part on `.` as the pane separator, so no target
# syntax can name this window: both `smoke:fm-v1.2-fix` and the anchored
# `=smoke:=fm-v1.2-fix` fail against it while it is LIVE.
DOTTED="fm-v1.2-fix"
fm_backend_tmux_create_task "$SESSION" "$DOTTED" "$HOME" \
  || fail "could not create the dotted-name window"

fm_backend_target_exists tmux "$SESSION:$DOTTED" \
  || fail "a LIVE window whose name contains a dot must read alive"
pass "real tmux: fm_backend_target_exists reports a live dotted window name alive"

# Exactness must survive the dot-safe path: a strict prefix of the dotted name
# (the part tmux itself would truncate at the dot) must still read dead.
if fm_backend_target_exists tmux "$SESSION:fm-v1" 2>/dev/null; then
  fail "a name that is only a PREFIX of the live dotted window must read dead"
fi
if fm_backend_target_exists tmux "$SESSION:fm-v1.2" 2>/dev/null; then
  fail "a dotted name that is only a PREFIX of the live dotted window must read dead"
fi
pass "real tmux: a prefix of a live dotted window name still reads dead"

# The other direction of the same ambiguity: a target whose window part is
# `<live-window-name>.<valid-pane-index>` names a window that does NOT exist,
# but tmux resolves that string to the live base window's pane and reports it
# present. Reachable from an ordinary spawn: tasks `v1` and `v1.0` produce
# windows `fm-v1` and `fm-v1.0`, so when `v1.0` dies and `v1` is still live the
# gone worker would read alive.
COLLIDER="fm-v1"
fm_backend_tmux_create_task "$SESSION" "$COLLIDER" "$HOME" \
  || fail "could not create the pane-suffix collider window"
tmux list-panes -t "=$SESSION:=$COLLIDER" -F '#{pane_index}' | grep -Fqx 0 \
  || fail "the collider window must have a pane 0 for this case to be meaningful"
if tmux list-windows -t "=$SESSION:" -F '#{window_name}' | grep -Fqx "$COLLIDER.0"; then
  fail "the fixture must NOT contain a window actually named $COLLIDER.0"
fi

if fm_backend_target_exists tmux "$SESSION:$COLLIDER.0" 2>/dev/null; then
  fail "a target naming a window that does not exist must read dead, even when tmux would resolve it as <live window>.<pane index>"
fi
pass "real tmux: <live-window>.<pane-index> reads dead when no window has that name"

fm_backend_target_exists tmux "$SESSION:$COLLIDER" \
  || fail "the live base window of the pane-suffix collision must still read alive"
pass "real tmux: the live base window of a pane-suffix collision still reads alive"

# `session:window.pane` IS a supported target shape (a documented
# FM_SUPERVISOR_TARGET form, and one fm-send can deliver to), so a live pane
# must read alive. It is distinguished from the collision above by the fleet's
# own reserved `fm-` task-window prefix: `fm-<task-id>` is always a window
# identity, so `fm-v1.0` stays dead while `<other>.<pane>` resolves.
PANEWIN="split-check"
fm_backend_tmux_create_task "$SESSION" "$PANEWIN" "$HOME" \
  || fail "could not create the pane-suffix window"
tmux split-window -t "=$SESSION:=$PANEWIN" \
  || fail "could not split the pane-suffix window"
tmux list-panes -t "=$SESSION:=$PANEWIN" -F '#{pane_index}' | grep -Fqx 1 \
  || fail "the pane-suffix window must have a pane 1 for this case to be meaningful"

fm_backend_target_exists tmux "$SESSION:$PANEWIN.1" \
  || fail "a LIVE, deliverable pane target must read alive"
fm_backend_target_exists tmux "$SESSION:$PANEWIN.0" \
  || fail "pane 0 of a live window must read alive"
if fm_backend_target_exists tmux "$SESSION:$PANEWIN.9" 2>/dev/null; then
  fail "an absent pane index must read dead"
fi
if fm_backend_target_exists tmux "$SESSION:no-such-window.0" 2>/dev/null; then
  fail "a pane suffix on an absent window must read dead"
fi
pass "real tmux: a live session:window.pane target reads alive, absent pane and window read dead"

# The kill path must resolve the same way the read path does. Handing tmux a
# composed `=<session>:=<window>` name is destructive here, not merely wrong:
# tmux reads the `.` as a pane separator, so killing a target that names NO
# window resolved to a different live window and destroyed it.
if fm_backend_target_exists tmux "$SESSION:$COLLIDER"; then
  fm_backend_tmux_kill "$SESSION:$COLLIDER.0" \
    || fail "fm_backend_tmux_kill must stay best-effort on a target that names no window"
  fm_backend_target_exists tmux "$SESSION:$COLLIDER" \
    || fail "killing '$SESSION:$COLLIDER.0' (which names NO window) destroyed the live window $COLLIDER"
  pass "real tmux: fm_backend_tmux_kill does not destroy a different live window on a pane-suffix collision"
fi

# The dotted window is killed through the public interface: no `-t` name syntax
# can address it, so this also pins that kill resolves by inventory.
fm_backend_tmux_kill "$SESSION:$DOTTED" \
  || fail "fm_backend_tmux_kill failed on the dotted-name window"
if tmux list-windows -t "=$SESSION:" -F '#{window_name}' | grep -Fqx "$DOTTED"; then
  fail "fm_backend_tmux_kill did not remove the dotted-name window"
fi
pass "real tmux: fm_backend_tmux_kill removes a window whose name contains a dot"
if fm_backend_target_exists tmux "$SESSION:$DOTTED" 2>/dev/null; then
  fail "a REMOVED window whose name contains a dot must read dead"
fi
pass "real tmux: fm_backend_target_exists reports a removed dotted window name dead"

if fm_backend_target_exists tmux "no-such-session-xyz:no-such-window-xyz" 2>/dev/null; then
  fail "fm_backend_target_exists should report a wholly nonexistent session dead"
fi
pass "real tmux: fm_backend_target_exists reports a wholly nonexistent session dead"

# A SESSION name containing a literal `.`, which the fleet gets verbatim from
# `#S` whenever firstmate runs inside tmux. The session part has the same
# pane-separator ambiguity as the window part, so it must be resolved as a
# session rather than handed to tmux as a bare target name.
DOTTED_SESSION="smoke.v2"
DOTTED_SESSION_WINDOW="fm-v2.1-fix"
tmux new-session -d -s "$DOTTED_SESSION" -n "$DOTTED_SESSION_WINDOW" -x 200 -y 50 \
  || fail "could not create the dotted-name session"

fm_backend_target_exists tmux "$DOTTED_SESSION:$DOTTED_SESSION_WINDOW" \
  || fail "a LIVE window in a session whose NAME contains a dot must read alive"
fm_backend_target_exists tmux "$DOTTED_SESSION" \
  || fail "a live session whose name contains a dot must read alive as a bare target"
pass "real tmux: a dotted session name resolves, bare and qualified"

if fm_backend_target_exists tmux "$DOTTED_SESSION:fm-gone" 2>/dev/null; then
  fail "an absent window in a dotted-name session must read dead"
fi
if fm_backend_target_exists tmux "smoke.v9:$DOTTED_SESSION_WINDOW" 2>/dev/null; then
  fail "a window in an absent dotted-name session must read dead"
fi
if fm_backend_target_exists tmux "$DOTTED_SESSION:${DOTTED_SESSION_WINDOW%-fix}" 2>/dev/null; then
  fail "a window name that is only a PREFIX inside a dotted-name session must read dead"
fi
if fm_backend_target_exists tmux "${DOTTED_SESSION%2}" 2>/dev/null; then
  fail "a bare session name that is only a PREFIX of the dotted session must read dead"
fi
pass "real tmux: a dotted session name stays exact for absent sessions, windows, and prefixes"
state=$(fm_backend_agent_state tmux "$TARGET")
[ "$state" = missing ] \
  || fail "a real missing window in a readable session should classify as missing, got '$state'"
# Best-effort contract: killing an already-gone window must not error.
fm_backend_tmux_kill "$TARGET" || fail "fm_backend_tmux_kill on an already-dead target must stay best-effort (never fail)"
pass "real tmux: kill removes the window and the readable session inventory authoritatively classifies it missing"

# --- container_ensure agrees with the presence read -------------------------
# The session-existence check that decides WHERE a task is written must resolve
# names the same way the presence probe that READS it back does. A live
# `firstmate-old` with no `firstmate` is the reachable disagreement: unanchored,
# the probe succeeds by prefix, nothing is created, the window lands in
# `firstmate-old`, and the recorded `firstmate:fm-<id>` then reads dead.

tmux new-session -d -s firstmate-old -x 200 -y 50 \
  || fail "could not create the prefix-colliding session"
if tmux has-session -t "=firstmate" 2>/dev/null; then
  fail "the fixture requires that no session is named exactly firstmate"
fi

ensured=$(unset TMUX; fm_backend_tmux_container_ensure) \
  || fail "fm_backend_tmux_container_ensure failed"
[ "$ensured" = firstmate ] || fail "container_ensure resolved to '$ensured', expected firstmate"
tmux list-sessions -F '#{session_name}' | grep -qx firstmate \
  || fail "container_ensure returned 'firstmate' without a session of exactly that name existing"

ensured_window="fm-container-check"
fm_backend_tmux_create_task "$ensured" "$ensured_window" "$HOME" \
  || fail "could not create a task window in the ensured session"
fm_backend_target_exists tmux "$ensured:$ensured_window" \
  || fail "a task written to the ensured session must read alive through the presence probe"
tmux list-windows -t "=firstmate" -F '#{window_name}' | grep -qx "$ensured_window" \
  || fail "the task window was created in a prefix-matched session, not the ensured one"
pass "real tmux: container_ensure and the presence probe agree on a prefix-colliding session name"

cleanup_all
trap - EXIT
