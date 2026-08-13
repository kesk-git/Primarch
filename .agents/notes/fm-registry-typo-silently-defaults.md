# Task notes: fm-registry-typo-silently-defaults

Durable project-intrinsic knowledge this task produced.
The fold routes each fact below into the destination document and then retires this file.
Keep the bar high: knowledge useful to almost every future session, and a pointer to the authoritative file or command rather than detail the code already shows.

## Destination

AGENTS.md

## Notes

- Every mechanical caller of `bin/fm-project-mode.sh` must not discard its stderr warning (that warning is the only alarm for a malformed or unknown `data/projects.md` registry line - AGENTS.md section 2's registry format). As of this task the callers are: `bin/fm-fleet-sync.sh` (own line, now converted to a `<repo>: registry-invalid: ...` stdout line so it survives being invoked from a captured/backgrounded context), `bin/fm-spawn.sh` (own `2>/dev/null` removed so the warning reaches spawn's own output), `bin/fm-home-seed.sh` and `bin/fm-remote-home-seed.sh` (already correct - no redirect). Re-grep `fm-project-mode\.sh` under `bin/` before trusting this list on a future change; a new caller must follow the same rule.
- The actionable session-start diagnostic for a malformed registry line has two independent sources, by design, not duplication: `bin/fm-bootstrap.sh`'s `fleet_sync_relay_filtered_output` relays a `FLEET_SYNC: <repo>: registry-invalid: ...` line only for a project that is actually cloned and synced that session; `bin/fm-bootstrap.sh`'s `project_registry_lint` (called from `detect_local_config`) is the comprehensive check - it walks every line in `data/projects.md` directly and fires a `PROJECT_REGISTRY: <name>: ... - line: "..." - expected: ...` diagnostic regardless of clone state, so an uncloned or not-yet-synced project's malformed line is still caught. Both reuse `bin/fm-project-mode.sh` as the single owner of the registry format and its warning text (one-owner rule) rather than re-parsing the format themselves.
- Investigated whether `no-mistakes axi respond --action fix --findings <ids>` can itself refuse or warn when a gate response omits some of the gate's findings (the stronger, upstream fix suggested for the "omission is refusal" defect). As of `no-mistakes` v1.46.0, `no-mistakes axi respond --help` and `no-mistakes axi run --help` document no such validation, warning, or refusal for a partial `--findings` list - there is no `--all` flag and no mention of declined/closed semantics for unnamed findings. `no-mistakes` is a separate installed binary (not part of this repo), so this was established from its CLI help text only, not from source or a live multi-finding gate test (which would need a real GitHub-backed scratch repo to trigger, out of this task's scope). This is not proof the tool silently declines unnamed findings, only that its documented interface gives no assurance either way; a future task that wants the upstream fix should verify against a live gate first.
