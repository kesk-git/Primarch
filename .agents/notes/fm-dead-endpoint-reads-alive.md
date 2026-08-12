# Task notes: fm-dead-endpoint-reads-alive

Durable project-intrinsic knowledge this task produced.
The fold routes each fact below into the destination document and then retires this file.
Keep the bar high: knowledge useful to almost every future session, and a pointer to the authoritative file or command rather than detail the code already shows.

## Destination

AGENTS.md

## Notes

- `tmux display-message -p -t <target> '#{pane_id}'` is not a valid tmux liveness check.
It returns rc=0, and can print the current pane's own id and name, even when the target window or session does not exist.
The correct read-only presence check resolves the session and window parts separately against real state (`list-windows` inventory), rather than handing tmux a composed `session:window` name string in any form.
`=` anchoring is necessary but not sufficient: it only closes the prefix-resolution hazard, where a dead `fm-auth` reads alive off a live `fm-auth-fix`.
It does not close the `.` hazard, which is why the composed form was abandoned entirely - for the destructive `kill-window` path as well as for reads.
See `docs/verification/runtime-backends.md` "Endpoint-presence check (fm_backend_target_exists)" for the empirical evidence and exact commands.
- The tmux presence-check contract had two independent call sites implementing the same logic, which is why the same wrong probe had to be fixed twice: `fm_backend_target_exists` in `bin/fm-backend.sh` and `pane_readable` in `bin/fm-crew-state.sh`.
`fm_backend_target_exists` is now the owner for the meta-driven readers and `pane_readable` delegates to it for tmux; change the probe there and both follow.
Two tmux presence readers deliberately stay outside it: `fm_afk_launch_terminal_alive` and `fm_afk_launch_terminal_absent` in `bin/fm-afk-launch.sh`, which probe the away-daemon's own unique bare session name.
Neither ever had the `display-message` defect, but a future change to the presence contract has to be applied to them by hand.
`fm_backend_tmux_anchor_target` in `bin/fm-backend.sh` is the single owner of tmux exact-target resolution, shared by that probe, `fm_backend_tmux_kill`, and the two session-existence checks that decide where a task is written (`fm_backend_tmux_container_ensure` and `muse_worker_meta_api_key_present`).
Anchoring has to cover the write side as well as the read side, or the two disagree about which session a name means: an unanchored `has-session -t firstmate` succeeds against a live `firstmate-old`, so the task is created there while its meta records `firstmate:fm-<id>`, and the anchored read then reports a live worker dead.
A composed `session:window` name string is never safe to hand tmux, because its parser reads a literal `.` as the pane separator and that is ambiguous in both directions: `=sess:=fm-v1.2-fix` fails against a LIVE window of exactly that name, and `=sess:=fm-v1.0` succeeds with no window of that name by resolving to a live `fm-v1` pane 0.
The session part has the same hazard: `=my.sess` fails with "can't find pane", while `=my.sess:` (trailing colon, so tmux parses a session) is correct and still exact.
Task ids may contain `.` and session names are the captain's own, so presence resolves the parts separately against real state - `list-windows -t "=<session>:"` filtered with `grep -Fqx` over name, index, and window id - and `session:window.pane` is deliberately not a resolvable shape, since a window may legitimately be named `window.pane`.
Bare pane ids (`%N`) and window ids (`@N`) stay on a plain `has-session`; anchoring them makes them fail.
Whether a worker is remote is decided by the meta's `remote_host` (`fm_backend_is_remote_placement`), never by its `window=remote:<id>` string: a local task in a tmux session named `remote` records that same string, so keying on it would report every crashed window in that session alive.
- Exit status alone is an unreliable existence signal across more than just tmux.
The Zellij guarantee table in `docs/verification/runtime-backends.md` already records that zellij actions against missing targets return exit 0, which is why every zellij `target-exists` code path lists actual pane, session, or tab state and filters by exact id or name match instead of trusting a raw action's exit code.
