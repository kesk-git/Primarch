# Task notes: fm-active-run-idle-pane-not-absorbed

Durable project-intrinsic knowledge this task produced.
The fold routes each fact below into the destination document and then retires this file.
Keep the bar high: knowledge useful to almost every future session, and a pointer to the authoritative file or command rather than detail the code already shows.

## Destination

docs/architecture.md

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
