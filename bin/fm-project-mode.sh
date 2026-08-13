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
#   <annotation> absent, or "[" <mode> [ " +yolo" ] "]"     yes, end to end
#   " - "        literal separator token                    yes
#   <desc>       free text, at least one token              presence only
#   <date>       "(added " <date> ")", line-final           presence only
#
#   - <name> - <desc> (added <date>)                  -> no-mistakes off  (legacy default)
#   - <name> [<mode>] - <desc> (added <date>)          -> <mode> off
#   - <name> [<mode> +yolo] - <desc> (added <date>)    -> <mode> on
#
# A "- " line carrying all of name/separator/desc/added-date is an ENTRY and its
# annotation is validated as a whole - every token between the name and the
# separator must be accounted for by the grammar above. The annotation cases,
# enumerated (registry_rows' entry_fault owns them):
#   absent                          -> valid, legacy default
#   [<known mode>]                  -> valid
#   [<known mode> +yolo]            -> valid
#   [<unknown mode> ...]            -> unknown mode
#   [<known mode> <other token>]    -> unrecognized annotation token
#   [<known mode> +yolo +yolo]      -> duplicate annotation token
#   []                              -> empty annotation
#   no "[" or no closing "]", or a
#   token outside the brackets      -> malformed annotation
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
# A malformed entry line - any of the fault cases enumerated above - falls back to
# "no-mistakes off" and warns to stderr as
# "warn: registry-invalid: <reason> for <name>; ...", so a typo never silently
# drops the gate. That "registry-invalid:" marker is the caller contract: a
# warning carrying it means the line is malformed and must be reported, and the
# two warnings without it ("no registry at <path>", "project X not in registry")
# mark documented-normal states every caller must stay quiet about. A new caller
# selects on the marker rather than re-deriving which warnings are faults.
#
# --lint validates every entry line in the registry instead of resolving one
# project, in a single process, and prints one tab-separated
# "<name>\t<reason>\t<raw line>" row per malformed entry (nothing at all for a
# healthy or absent registry, and nothing for a non-entry bullet). Unlike a
# per-name lookup, which stops at the first line carrying that name, it reaches a
# malformed duplicate entry for an already-registered name.
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
# Resolution (mode, yolo) is unchanged and stays deliberately forgiving. The two
# new fields are the whole-line verdict: <entry> says the line matches the entry
# grammar in the header, and <fault> is the one reason it violates that grammar.
# entry_fault() consumes the line end to end - the region between the name and the
# " - " separator is the entire annotation, so a token before, inside, or after
# the brackets is examined by the same rule rather than by a scan per position.
registry_rows() {  # <lint 0|1> [<name>]
  awk -v lint="$1" -v n="${2:-}" -v modes="$KNOWN_MODES" '
    function is_mode(m,   i, k, a) {
      k = split(modes, a, " ");
      for (i = 1; i <= k; i++) if (a[i] == m) return 1;
      return 0;
    }
    # The full grammar, one branch per case. Returns "" for a well-formed entry.
    function entry_fault(region,   inner, k, a, j) {
      if (region == "") return "";                             # legacy, no annotation
      if (region !~ /^\[/ || region !~ /\]$/)
        return "malformed annotation \"" region "\"";          # unterminated, or a token outside the brackets
      inner = substr(region, 2, length(region) - 2);
      k = split(inner, a, " ");
      if (k == 0) return "empty annotation \"" region "\"";
      if (!is_mode(a[1])) return "unknown mode \"" a[1] "\"";
      for (j = 2; j <= k; j++)
        if (a[j] != "+yolo") return "unrecognized annotation token \"" a[j] "\"";
      if (k > 2) return "duplicate annotation token \"+yolo\"";
      return "";
    }
    # Trailing whitespace and a CRLF ending are markdown noise, not grammar, so
    # they are trimmed once here - before recognition, field splitting, and the
    # raw line a diagnostic quotes - rather than tolerated per anchor.
    { sub(/\r$/, ""); sub(/[[:space:]]+$/, "") }
    $1=="-" && NF>=2 && (lint==1 || $2==n) {
      mode="no-mistakes"; yolo="off";
      if ($3 ~ /^\[/) {
        s="";
        for (i=3; i<=NF; i++) { s = s (s==""?"":" ") $i; if ($i ~ /\]$/) break }
        gsub(/^\[|\]$/, "", s);           # strip the surrounding brackets
        k = split(s, a, " ");
        if (a[1] != "" && a[1] != "+yolo") mode = a[1];
        for (j=1; j<=k; j++) if (a[j]=="+yolo") yolo="on";
      }
      entry=0; fault=""; sep=0;
      for (i=3; i<=NF; i++) if ($i == "-") { sep=i; break }
      if ($0 ~ /^- / && sep >= 3 && NF > sep && $0 ~ /\(added [^)]+\)$/) {
        entry=1;
        region="";
        for (i=3; i<sep; i++) region = region (region==""?"":" ") $i;
        fault=entry_fault(region);
      } else if (!is_mode(mode)) {
        fault="unknown mode \"" mode "\"";                     # not an entry: fall back, but never report
      }
      printf "%s\037%s\037%s\037%s\037%s\037%s\n", $2, mode, yolo, entry, fault, $0;
      if (lint!=1) exit;
    }
  ' "$REG"
}

if [ "$LINT" -eq 1 ]; then
  [ -f "$REG" ] || exit 0
  while IFS=$'\037' read -r lname _ _ lentry lfault lraw; do
    [ -n "$lname" ] || continue
    [ "$lentry" = 1 ] || continue
    [ -n "$lfault" ] || continue
    printf '%s\t%s\t%s\n' "$lname" "$lfault" "$lraw"
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

IFS=$'\037' read -r _ mode yolo entry fault _ <<EOF
$row
EOF
if [ -n "$fault" ]; then
  case "$entry" in
    1) echo "warn: registry-invalid: $fault for $NAME; defaulting to no-mistakes off" >&2 ;;
  esac
  mode=no-mistakes
  yolo=off
fi
case "$yolo" in on|off) ;; *) yolo=off ;; esac
# A conditional policy is not a task mode. Mechanical callers get its most
# rigorous leg; --raw callers get the annotation itself (see the header).
if [ "$RAW" -eq 0 ] && [ "$mode" = no-mistakes-prod-only ]; then
  mode=no-mistakes
fi
echo "$mode $yolo"
