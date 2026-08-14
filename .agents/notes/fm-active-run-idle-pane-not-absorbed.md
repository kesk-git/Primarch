# Task notes: fm-active-run-idle-pane-not-absorbed

Durable project-intrinsic knowledge this task produced.
The fold routes each fact below into the destination document and then retires this file.
Keep the bar high: knowledge useful to almost every future session, and a pointer to the authoritative file or command rather than detail the code already shows.

## Destination

docs/architecture.md, AGENTS.md

## Notes

Both facts below are already written into their authoritative owners by this task's own diff.
They are recorded here because the fold should check they survived, not because AGENTS.md needs them: neither is needed on every session or turn, so section 13's trigger-pointer discipline applies rather than an inline addition.

- The no-mistakes pipeline runs each step in its OWN clone under `~/.no-mistakes/repos/<id>.git`, which is a SEPARATE git object store from the crew worktree's.
  Any check that binds a run to a worktree by commit identity is therefore unable to bind a healthy run for the whole time the pipeline is committing fix rounds, because the run head does not exist locally yet.
  It self-heals once the branch is pushed back, so post-hoc forensics finds the same sha perfectly resolvable and the defect looks intermittent when it is systematic.
  Owner: `bin/fm-nm-run-lib.sh`'s `fm_nm_head_matches_worktree` note, cross-referenced from `docs/architecture.md`.
  Verify with `git -C <no-mistakes worktree> rev-parse --git-common-dir` against the crew worktree's.

- `no-mistakes axi status` exposes a `branch_sync` block whose `state` reports the pipeline's current relationship to the queried branch.
  Observed values on live runs (v1.46.0): `pipeline_owned` while the pipeline holds the branch, and `behind` once its fix commits have advanced past the crew's worktree.
  This is a structural liveness fact and is the right signal for "is this run live", where a sha comparison structurally cannot answer.
  The vocabulary is not exhaustively documented upstream, so consumers must treat unrecognized values as "no positive evidence" rather than inferring a meaning.
  Owner: `bin/fm-crew-state.sh`'s `nm_pipeline_run_is_live`.

- Reporting caution worth keeping if `docs/architecture.md`'s wording is ever condensed: an absence of measurement must not render like a measurement.
  `fm-crew-state.sh` emits a distinct `unreadable` state for "the run source did not answer", separate from `unknown` for "there is no live run", and `fm-classify-lib.sh`'s `crew_absorb_class` is the single place either becomes an absorb decision.
  The `unreadable` verdict is emitted BEFORE the endpoint and status-log fallbacks, because emit ORDER, not just the token, is what keeps it distinguishable: after those gates it would have surfaced as `unknown - source: none - backend target gone`, byte-identical to a measured stop.

- Adding a state token to `bin/fm-crew-state.sh`'s emitted line does NOT reach its consumers, because each one ENUMERATES the tokens it cares about at its own site rather than asking a shared owner.
  Three separate consumers silently mishandled the new `unreadable` token in this task: `bin/fm-supervise-daemon.sh` (matched the wedge reason's PROSE, so the AFK path self-handled the one wake meaning "nobody could measure this crew"), `bin/fm-fleet-snapshot.sh` (counted only `unknown` as an unavailable child, so a home with an unmeasured child published as a valid `no_active_work`), and `bin/fm-bearings-snapshot.sh` (passed it through into Underway unlabelled).
  Each was reachable, and each turned an absence of measurement back into a measured answer.
  The enumerate-at-each-site pattern will produce a fourth: the durable fix is an owner that makes an unhandled token unconstructible rather than a list to remember at every site.
  Deliberately not attempted in this round; the evidence above is what it should be scoped from.

- A crew's persisted busy record (`state/<id>.busy-state`) is validated by GENERATION match only, with no time expiry, so it keeps reading `busy` indefinitely after the agent process exits.
  Any consumer that reads it must confirm the endpoint still exists first, or it reports a dead crew as a measured `working`.
  `fm_busy_classify_live` is the form that carries the dead-endpoint precedence; plain `fm_busy_classify` does not.
  Measured 2026-08-13 on two crews whose agent had exited while the pipeline run stayed alive (pane showed `pane_current_command=zsh` and the harness's own "Resume this session with: claude --resume <id>" tail); their correct wedge alarms were absorbed by hand as false ones.
  That 2026-08-13 case is NOT closed by this task, and the reason is worth keeping because it is counter-intuitive: a claude agent that shuts down fires SessionEnd, which `bin/fm-spawn.sh` wires to write an `idle` record, so an EXITED claude agent classifies `idle claude-hook` rather than unknown or dead (reproduced directly against `fm_busy_classify`).
  It therefore reads as a measured idle pane and is absorbed by the wedge guard exactly as a healthy quiet one is.
  The guard this task added refuses only an UNPROVEN pane; detecting an exited agent is the separately filed `fm-exited-agent-reads-working`.

- AGENTS.md's validation-judgement sentence now matches the attribution rule this task established: liveness is decided FIRST, and code identity only disambiguates FINISHED runs.
  This task could not make that edit itself because a second firstmate lane held AGENTS.md exclusively while it ran, so only `docs/architecture.md`'s equivalent sentence was corrected in its own diff; AGENTS.md caught up afterwards.
  Nothing remains pending on that fact, and the fold only has to confirm both owners still agree.
