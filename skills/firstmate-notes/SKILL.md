---
name: firstmate-notes
description: Keep per-task housekeeping writes out of parallel branches so two tasks in one repo stop colliding on prose. Load BEFORE writing a crewmate ship brief, BEFORE recording durable project knowledge in a project's AGENTS.md/README/docs, and BEFORE folding pending notes. Covers the per-task note path, the fold procedure, and `fm-notes.sh scan`, which finds notes nothing has folded.
---

# firstmate-notes

A shared document that every task edits in its own branch is a guaranteed same-repo collision, and it is the worst kind: two agents' contradictory prose merges **without failing**, so the file quietly ends up saying two things.

So: **a task records its durable project knowledge in its own note file and never edits the shared documents. One fold pass writes them.**

The script beside this file, `fm-notes.sh`, owns the mechanics. Run `fm-notes.sh --help` for exact commands; this file owns when and why.

The command blocks below spell out the user-level install location, `~/.claude/skills/firstmate-notes/`, which is where this skill expects to live. If your installer placed it somewhere else, such as a project-level `.claude/skills/`, run the same scripts from that directory instead.

## When to load this

- Before writing a crewmate ship brief, so the brief carries the note instruction instead of "update `AGENTS.md`".
- Before recording durable project knowledge as a crewmate.
- Before folding, and whenever `fm-notes.sh scan` reports unfolded notes.

## What a task does

If the task produced durable project-intrinsic knowledge:

```sh
~/.claude/skills/firstmate-notes/fm-notes.sh new <task-id>    # in the task worktree
```

Write the facts into that file. Same bar as any project memory: knowledge useful to almost every future session, and a pointer to the authoritative file or command rather than detail the code already shows. A task that produced no durable knowledge writes no note.

**Do not edit `AGENTS.md`, `CLAUDE.md`, `README.md`, or the project's other shared prose to record what this task learned, and do not run `fm-ensure-agents-md.sh`.** That prohibition is about *recording this task's learnings*. A task whose actual deliverable is a documentation change edits those files normally - that is the work, not housekeeping.

The path is `.agents/notes/<task-id>.md`: unique by construction, so no two tasks can hold it, and no coordination or lock is needed. It is committed and merged with the task like any other file.

## The fold

The fold is the only writer of the shared documents. Run it as an ordinary ship task on the project, dispatched like any other:

1. `fm-notes.sh list` - what is pending. Nothing pending means there is nothing to do; stop without a PR.
2. `fm-ensure-agents-md.sh .` so `AGENTS.md` exists, `CLAUDE.md` links to it, and it carries its `## Maintaining this file` section. That script lives in the firstmate repo's `bin/` and does not ship with this skill; run it if you have firstmate checked out. Without it, ensure `AGENTS.md` exists by whatever means your own project already uses, then continue. This belongs to the fold for the same reason the edits do: creating that file from N branches collides exactly the way editing it from N branches does.
3. Read every pending note and route each fact into the document its `## Destination` names, defaulting to `AGENTS.md`. Apply that document's own bar, and rewrite or prune an existing entry rather than appending a new one.
4. Drop a fact that is stale, already recorded, or already visible in the code - and say which in the PR body. A dropped fact is a decision you record, not an omission.
5. `fm-notes.sh retire <task-id>...` for exactly the notes you folded.
6. Commit the folded documents and the retired notes together, and ship through the project's normal delivery path.

Retiring is the **only** thing that marks a note folded; there is no separate fold-state record. That is deliberate, and it is what makes the design survive its own failure: a note you leave unfolded stays on the default branch, keeps being reported by `scan`, and folds correctly whenever the fold finally runs. A fold that is late, skipped, or failed loses nothing and nothing is order-dependent. Git history keeps a retired note recoverable.

## Finding notes nothing folded

An unfolded note is invisible in every diff, so this check is the only thing between a skipped fold and knowledge that silently stops shipping:

```sh
# With a firstmate home: scans that home's projects/* clones and the home itself.
FM_HOME=<home> ~/.claude/skills/firstmate-notes/fm-notes.sh scan
# With no firstmate home (a fresh machine, this skill installed on its own): name the repos to scan.
~/.claude/skills/firstmate-notes/fm-notes.sh scan <dir>...
```

Only the list of repos differs. Either way, `scan` counts the pending notes in each repo on that list, prints a line for every repo holding any, and exits `3` when the total is above zero and `0` when it is zero - so both forms work as a mechanical check rather than something to eyeball. A directory you name is resolved to its enclosing worktree root, and one that cannot be read is reported and exits `1`: three outcomes, three exit codes, because a path it could not look at must never be reported as nothing found. `FM_HOME`'s list is that home's `projects/*` clones **and `FM_HOME` itself**, because a firstmate home is a firstmate checkout and the firstmate repo is never under `projects/` - anything that iterates only `projects/` silently skips the repo its own crewmates work in most.

## Why this exists

Shared documents are where same-repo parallel work collides, and the collision is silent because contradictory prose merges cleanly.
No predictor can recover that; only the convention can.

## What this cannot do - read this before relying on it

**It cannot enforce anything at the moment of the mistake.** This is a convention plus a script, not a gate. Nothing stops a crewmate editing `AGENTS.md` in its own branch; the collision will simply happen as before. The mechanical parts are only these: `fm-notes.sh` refuses an unsafe or unknown id, `retire` validates every id before deleting any so a partial fold cannot silently drop a note, and `scan` finds what nothing folded. Everything else depends on the brief actually carrying the instruction.

**A skill is inert unless something loads it.** This one is user-level, so it survives ordinary updates to whatever installed it, but nothing triggers it automatically - the agent using it has to carry its own reminder to load it, in whatever durable memory it keeps across sessions, and act on that reminder at the start of its work.

**The fold is not mechanically serialized.** Two concurrent folds would conflict on `AGENTS.md` - loud at merge, not silent - and no note is lost, since each retires only what it folded. Dispatch one fold per project at a time.

**Ids are matched exactly, never by prefix.** An earlier design keyed on a `<name>-*` glob, so a live `web-api` fold blocked `web`. Nothing here globs.

## Tests

`test/run.sh`, beside this file. Offline, no firstmate repo and no fleet data - every fixture is a throwaway git repo in a temp dir.

```sh
~/.claude/skills/firstmate-notes/test/run.sh
```

The load-bearing one builds two real branches and proves the old convention **conflicts** while the note lane **merges clean** and the fold still lands both facts. The rest pin `scan`'s three outcomes across both invocation forms, the prefix-collision case, all-or-nothing `retire`, and unsafe-id refusal.
