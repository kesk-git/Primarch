# Task notes: fm-dead-endpoint-reads-alive

Durable project-intrinsic knowledge this task produced.
The fold routes each fact below into the destination document and then retires this file.
Keep the bar high: knowledge useful to almost every future session, and a pointer to the authoritative file or command rather than detail the code already shows.

## Destination

AGENTS.md

## Notes

- `tmux display-message -p -t <target> '#{pane_id}'` is not a valid tmux liveness check.
It returns rc=0, and can print the current pane's own id and name, even when the target window or session does not exist.
`tmux has-session -t <target>` is the correct read-only presence check; see `docs/verification/runtime-backends.md` "Endpoint-presence check (fm_backend_target_exists)" for the empirical evidence and exact commands.
- The tmux presence-check contract had two independent call sites implementing the same logic: `fm_backend_target_exists` in `bin/fm-backend.sh` and `pane_readable` in `bin/fm-crew-state.sh`.
A fix to only one leaves the other reading a dead pane as readable; grep both before touching this contract again.
- Exit status alone is an unreliable existence signal across more than just tmux.
The Zellij guarantee table in `docs/verification/runtime-backends.md` already records that zellij actions against missing targets return exit 0, which is why every zellij `target-exists` code path lists actual pane, session, or tab state and filters by exact id or name match instead of trusting a raw action's exit code.
