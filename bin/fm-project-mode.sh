#!/usr/bin/env bash
# Resolve a project's REGISTERED delivery posture from the data/projects.md registry.
# Prints two words to stdout: "<mode> <yolo>" where mode is one of
# no-mistakes|direct-PR|local-only and yolo is on|off.
#
# MECHANICAL CONSUMERS ONLY. This answers "what posture did the captain register
# for this project", never "how does this task ship". A task's delivery mode and
# yolo are resolved by firstmate at intake and passed explicitly to
# bin/fm-brief.sh, bin/fm-spawn.sh, and bin/fm-promote.sh (AGENTS.md section 7).
# The consumers are bin/fm-fleet-sync.sh (skip local-only clones),
# bin/fm-home-seed.sh (refuse local-only seeding, run no-mistakes init),
# bin/fm-spawn.sh's advisory registry-deviation notice, and bin/fm-bootstrap.sh's
# project_registry_lint, which runs --lint in the session-start local phase.
#
# ENTRY GRAMMAR (data/projects.md). A registry entry line is exactly:
#
#   "- " <name> [ " " <annotation> ] " - " <desc> " (added " <date> ")"
#
#   field        allowed                                   validated
#   -----------  ----------------------------------------  ---------
#   "- " prefix  literal, column 0 (no leading indent)      yes
#   <name>       one whitespace-free token                  presence only
#   <annotation> absent, or "[" [<mode>] [ " +yolo" ] "]"   yes, end to end
#   " - "        literal separator token                    yes
#   <desc>       free text, at least one token              presence only
#   <date>       "(added " <date> ")", line-final           presence only
#
#   - <name> - <desc> (added <date>)                  -> no-mistakes off  (legacy default)
#   - <name> [<mode>] - <desc> (added <date>)          -> <mode> off
#   - <name> [<mode> +yolo] - <desc> (added <date>)    -> <mode> on
#   - <name> [+yolo] - <desc> (added <date>)           -> no-mistakes on   (mode omitted)
#
# A "- " line carrying all of name/separator/desc/added-date is an ENTRY and its
# annotation is validated as a whole - every token between the name and the
# separator must be accounted for by the grammar below. registry_rows' annotate()
# is the single owner of that grammar: one tokenization yields both the verdict
# and the posture the line resolves to, so the alarm and the resolution cannot
# drift apart. A faulted annotation keeps only the part that parsed: a mode token
# the grammar recognizes still resolves, and the faulted part falls back to its
# own default (yolo off). Every case, enumerated:
#   absent                          -> valid            -> no-mistakes off
#   [<known mode>]                  -> valid            -> <mode> off
#   [<known mode> +yolo]            -> valid            -> <mode> on
#   [+yolo]                         -> valid            -> no-mistakes on
#   [<unknown mode> ...]            -> unknown mode     -> no-mistakes off
#   [<known mode> <other token>]    -> unrecognized annotation token -> <mode> off
#   [+yolo <any other token>]       -> unrecognized annotation token -> no-mistakes off
#   [... +yolo +yolo]               -> duplicate annotation token    -> <mode> off
#   []                              -> empty annotation -> no-mistakes off
#   no "[" or no closing "]", or a
#   token outside the brackets      -> malformed annotation -> <mode> off
#
# The fallback is fail-safe on the rigor axis and would be fail-DANGEROUS on the
# exposure axis, which is why the two are treated differently. An unreadable mode
# falls back to no-mistakes, the most rigorous leg, so a typo can never buy less
# review than the captain registered. But local-only is about exposure, not
# rigor: bin/fm-home-seed.sh and bin/fm-remote-home-seed.sh refuse to seed or
# provision a local-only project, so silently promoting a recognized local-only
# to the standing default on an unrelated typo would push a project the captain
# walled off. A recognized mode therefore survives a fault elsewhere in the line.
#
# Anything else under "- " is prose, not an entry: a bullet without the separator,
# the description, or the line-final "(added <date>)" is not a registry entry, so
# it is never reported (a markdown-link or note bullet in projects.md stays quiet).
# That allowlist is deliberate - a bullet the grammar does not recognize is not
# assumed to be a broken entry - and it is the boundary to revisit first if a
# malformed line is ever found unreported. Trailing whitespace and a CRLF ending
# are not part of the grammar and never decide the verdict: both are trimmed
# before the line is judged. The accepted residual is narrower but real: a bullet
# that omits "(added <date>)" entirely is still RESOLVED from by a lookup (it
# falls back to no-mistakes off like any unrecognized annotation) while never
# being reported - the parser reads posture from a line it declines to judge.
#
# Registered modes:
#   no-mistakes            full pipeline -> PR -> configured merge authority (default)
#   direct-PR              push + PR via gh-axi, no pipeline
#   local-only             local branch, no remote/PR, guarded local merge
#   no-mistakes-prod-only  a conditional policy, not a task mode: firstmate
#                          classifies each task's surface at intake (the
#                          project-management skill owns that classification).
#                          Mechanical output maps it to its most rigorous leg,
#                          no-mistakes, so sync, seeding, and init treat such a
#                          project as the remote-backed pipeline project it is.
# yolo (orthogonal) = when on, firstmate may make routine approval decisions itself.
#   AGENTS.md section 7 is the single owner of authority exceptions, including
#   ask-user contract expansion and stronger captain boundaries.
#
# --raw prints the registered annotation unmapped, so a caller that must tell a
# conditional policy apart from a flat mode sees "no-mistakes-prod-only" itself.
#
# A malformed entry line - any of the fault cases enumerated above - resolves to
# the posture that table gives it and warns to stderr as
# "warn: registry-invalid: <reason> for <name>; ...", so a typo never silently
# drops the gate. The warning names the posture it actually resolved to: a fault
# that left a recognized mode standing says so ("keeping <mode>, defaulting yolo
# to off"), and only an unreadable or absent mode says "defaulting to
# no-mistakes off". That "registry-invalid:" marker is the caller contract: a
# warning carrying it means the line is malformed and must be reported, and the
# two warnings without it ("no registry at <path>", "project X not in registry")
# mark documented-normal states every caller must stay quiet about. A new caller
# selects on the marker rather than re-deriving which warnings are faults.
#
# --lint validates every entry line in the registry instead of resolving one
# project, in a single process, and prints one tab-separated
# "<name>\t<reason>; <posture>\t<raw line>" row per malformed entry (nothing at
# all for a healthy or absent registry, and nothing for a non-entry bullet). The
# <posture> half is the same clause the per-project warning carries, from the same
# owner, so a caller that only ever sees a lint row still learns which posture the
# line resolved to. Unlike a per-name lookup, which stops at the first line
# carrying that name, it reaches a malformed duplicate entry for an already-
# registered name.
# Usage: fm-project-mode.sh [--raw|--lint] <project-name>
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
REG="$DATA/projects.md"
RAW=0
LINT=0
case "${1:-}" in
  --raw) RAW=1; shift ;;
  --lint) LINT=1; shift ;;
esac

KNOWN_MODES='no-mistakes direct-PR local-only no-mistakes-prod-only'

# awk emits one "<name>\037<mode>\037<yolo>\037<entry 0|1>\037<fault>\037<raw line>"
# row per registry line: the first line matching <name> for a lookup, every
# "- <name>" line under --lint.
#
# <entry> says the line matches the entry grammar in the header, <fault> is the
# one reason it violates that grammar, and <mode>/<yolo> are what it resolves to -
# all four derived from annotate()'s single tokenization, so the verdict and the
# posture cannot disagree. A fault does not discard what parsed: a recognized mode
# stands and only the faulted part falls back to its default (see the header's
# rigor-vs-exposure note). The region between the name and the " - " separator is
# the entire annotation, so a token before, inside, or after the brackets is
# examined by the same rule rather than per position.
registry_rows() {  # <lint 0|1> [<name>]
  awk -v lint="$1" -v n="${2:-}" -v modes="$KNOWN_MODES" '
    function is_mode(m,   i, k, a) {
      k = split(modes, a, " ");
      for (i = 1; i <= k; i++) if (a[i] == m) return 1;
      return 0;
    }
    # A fault elsewhere in the annotation never discards a mode that parsed: the
    # leading annotation token still names the registered mode whenever it is
    # one, so a typo in the yolo flag cannot quietly promote a local-only project
    # to the standing default. An unreadable or absent mode still falls back.
    function leading_mode(region,   lead) {
      lead = region;
      sub(/[[:space:]].*$/, "", lead);
      gsub(/^\[|\]$/, "", lead);
      if (is_mode(lead)) { A_KEPT = 1; return lead }
      A_KEPT = 0;
      return "no-mistakes";
    }
    # THE annotation grammar, and the only place it is defined. One tokenization
    # decides both the verdict (A_FAULT, empty when well formed) and the posture
    # it resolves to (A_MODE, A_YOLO), so the alarm and the resolution can never
    # disagree about the same annotation. Every case in the header table is a
    # branch here; a faulted annotation keeps only the part that parsed.
    function annotate(region,   inner, k, a, j, seen_yolo) {
      A_MODE = "no-mistakes"; A_YOLO = "off"; A_FAULT = ""; A_KEPT = 0;
      if (region == "") return;                                # legacy, no annotation
      if (region !~ /^\[/ || region !~ /\]$/) {
        A_FAULT = "malformed annotation \"" region "\"";       # unterminated, or a token outside the brackets
      } else {
        inner = substr(region, 2, length(region) - 2);
        k = split(inner, a, " ");
        j = 1;
        if (k == 0) {
          A_FAULT = "empty annotation \"" region "\"";
        } else if (a[1] == "+yolo") {
          A_MODE = "no-mistakes";                              # mode omitted: the standing default, yolo on
        } else if (!is_mode(a[1])) {
          A_FAULT = "unknown mode \"" a[1] "\"";
        } else {
          A_MODE = a[1];
          j = 2;
        }
        seen_yolo = 0;
        for (; A_FAULT == "" && j <= k; j++) {
          if (a[j] != "+yolo") A_FAULT = "unrecognized annotation token \"" a[j] "\"";
          else if (seen_yolo) A_FAULT = "duplicate annotation token \"+yolo\"";
          else { seen_yolo = 1; A_YOLO = "on" }
        }
      }
      if (A_FAULT != "") { A_MODE = leading_mode(region); A_YOLO = "off" }
    }
    # Trailing whitespace and a CRLF ending are markdown noise, not grammar, so
    # they are trimmed once here - before recognition, field splitting, and the
    # raw line a diagnostic quotes - rather than tolerated per anchor.
    { sub(/\r$/, ""); sub(/[[:space:]]+$/, "") }
    $1=="-" && NF>=2 && (lint==1 || $2==n) {
      entry=0; sep=0; region="";
      for (i=3; i<=NF; i++) if ($i == "-") { sep=i; break }
      if ($0 ~ /^- / && sep >= 3 && NF > sep && $0 ~ /\(added [^)]+\)$/) entry=1;
      if (entry) {
        for (i=3; i<sep; i++) region = region (region==""?"":" ") $i;
      } else if ($3 ~ /^\[/) {
        # Not an entry, so its verdict is never reported, but a lookup still has
        # to resolve it: the bracket span is the closest thing to an annotation.
        for (i=3; i<=NF; i++) { region = region (region==""?"":" ") $i; if ($i ~ /\]$/) break }
      }
      annotate(region);
      printf "%s\037%s\037%s\037%s\037%s\037%s\037%s\n", $2, A_MODE, A_YOLO, entry, A_FAULT, A_KEPT, $0;
      if (lint!=1) exit;
    }
  ' "$REG"
}

# The one owner of "what did this line actually resolve to", so the per-project
# warning and --lint's rows cannot describe the same fault differently.
posture_clause() {  # <kept 0|1> <mode>
  if [ "$1" = 1 ]; then
    printf 'keeping %s, defaulting yolo to off' "$2"
  else
    printf 'defaulting to no-mistakes off'
  fi
}

if [ "$LINT" -eq 1 ]; then
  [ -f "$REG" ] || exit 0
  while IFS=$'\037' read -r lname lmode _ lentry lfault lkept lraw; do
    [ -n "$lname" ] || continue
    [ "$lentry" = 1 ] || continue
    [ -n "$lfault" ] || continue
    printf '%s\t%s; %s\t%s\n' "$lname" "$lfault" "$(posture_clause "$lkept" "$lmode")" "$lraw"
  done < <(registry_rows 1)
  exit 0
fi

NAME=${1:?usage: fm-project-mode.sh [--raw|--lint] <project-name>}

if [ ! -f "$REG" ]; then
  echo "warn: no registry at $REG; defaulting $NAME to no-mistakes off" >&2
  echo "no-mistakes off"
  exit 0
fi

row=$(registry_rows 0 "$NAME")

if [ -z "$row" ]; then
  echo "warn: project \"$NAME\" not in registry; defaulting to no-mistakes off" >&2
  echo "no-mistakes off"
  exit 0
fi

IFS=$'\037' read -r _ mode yolo entry fault kept _ <<EOF
$row
EOF
case "$entry$fault" in
  1?*) echo "warn: registry-invalid: $fault for $NAME; $(posture_clause "$kept" "$mode")" >&2 ;;
esac
case "$yolo" in on|off) ;; *) yolo=off ;; esac
# A conditional policy is not a task mode. Mechanical callers get its most
# rigorous leg; --raw callers get the annotation itself (see the header).
if [ "$RAW" -eq 0 ] && [ "$mode" = no-mistakes-prod-only ]; then
  mode=no-mistakes
fi
echo "$mode $yolo"
