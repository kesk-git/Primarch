# Task notes: fm-dead-endpoint-reads-alive

Durable project-intrinsic knowledge this task produced.
The fold routes each fact below into the destination document and then retires this file.
Keep the bar high: knowledge useful to almost every future session, and a pointer to the authoritative file or command rather than detail the code already shows.

## Destination

AGENTS.md

## Notes

- `tmux display-message -p -t <target> '#{pane_id}'` is not a valid tmux liveness check.
It returns rc=0, and can print the current pane's own id and name, even when the target window or session does not exist.
`tmux has-session -t "=<session>:=<window>"` is the correct read-only presence check; the `=` exact-match prefix is required on both parts, because tmux otherwise resolves each part as exact name, then start-of-name, then glob, so a dead `fm-auth` reads alive off a live `fm-auth-fix`.
See `docs/verification/runtime-backends.md` "Endpoint-presence check (fm_backend_target_exists)" for the empirical evidence and exact commands.
- The tmux presence-check contract had two independent call sites implementing the same logic, which is why the same wrong probe had to be fixed twice: `fm_backend_target_exists` in `bin/fm-backend.sh` and `pane_readable` in `bin/fm-crew-state.sh`.
`fm_backend_target_exists` is now the owner for the meta-driven readers and `pane_readable` delegates to it for tmux; change the probe there and both follow.
Two tmux presence readers deliberately stay outside it: `fm_afk_launch_terminal_alive` and `fm_afk_launch_terminal_absent` in `bin/fm-afk-launch.sh`, which probe the away-daemon's own unique bare session name.
Neither ever had the `display-message` defect, but a future change to the presence contract has to be applied to them by hand.
`fm_backend_tmux_anchor_target` in `bin/fm-backend.sh` is the single owner of tmux exact-target resolution, shared by that probe, `fm_backend_tmux_kill`, and the two session-existence checks that decide where a task is written (`fm_backend_tmux_container_ensure` and `muse_worker_meta_api_key_present`).
Anchoring has to cover the write side as well as the read side, or the two disagree about which session a name means: an unanchored `has-session -t firstmate` succeeds against a live `firstmate-old`, so the task is created there while its meta records `firstmate:fm-<id>`, and the anchored read then reports a live worker dead.
Whether a worker is remote is decided by the meta's `remote_host` (`fm_backend_is_remote_placement`), never by its `window=remote:<id>` string: a local task in a tmux session named `remote` records that same string, so keying on it would report every crashed window in that session alive.
- Exit status alone is an unreliable existence signal across more than just tmux.
The Zellij guarantee table in `docs/verification/runtime-backends.md` already records that zellij actions against missing targets return exit 0, which is why every zellij `target-exists` code path lists actual pane, session, or tab state and filters by exact id or name match instead of trusting a raw action's exit code.
