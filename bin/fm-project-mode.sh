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
# bin/fm-home-seed.sh (refuse local-only seeding, run no-mistakes init), and
# bin/fm-spawn.sh's advisory registry-deviation notice.
#
# Registry line format (data/projects.md):
#   - <name> - <desc> (added <date>)                  -> no-mistakes off  (legacy default)
#   - <name> [<mode>] - <desc> (added <date>)          -> <mode> off
#   - <name> [<mode> +yolo] - <desc> (added <date>)    -> <mode> on
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
# A malformed annotation - an unknown mode, or any token inside the brackets other
# than the mode and +yolo - falls back to "no-mistakes off" and warns to stderr as
# "warn: registry-invalid: <reason> for <name>; ...", so a typo never silently
# drops the gate. That "registry-invalid:" marker is the caller contract: a
# warning carrying it means the line is malformed and must be reported, and the
# two warnings without it ("no registry at <path>", "project X not in registry")
# mark documented-normal states every caller must stay quiet about. A new caller
# selects on the marker rather than re-deriving which warnings are faults.
#
# --lint validates every line in the registry instead of resolving one project,
# in a single process, and prints one tab-separated "<name>\t<reason>\t<raw line>"
# row per malformed line (nothing at all for a healthy or absent registry). Unlike
# a per-name lookup, which stops at the first line carrying that name, it reaches a
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

# awk emits one "<name>\037<mode>\037<yolo>\037<unrecognized token>\037<raw line>"
# row per registry line: the first line matching <name> for a lookup, every
# "- <name>" line under --lint. The parse itself is unchanged - the annotation's
# first token is the mode unless it is +yolo, and any +yolo turns yolo on - and
# the fourth field only reports the first token the grammar does not recognize,
# which an unterminated "[" also produces because the scan then runs past the
# annotation into the description.
registry_rows() {  # <lint 0|1> [<name>]
  awk -v lint="$1" -v n="${2:-}" '
    $1=="-" && NF>=2 && (lint==1 || $2==n) {
      mode="no-mistakes"; yolo="off"; bad="";
      if ($3 ~ /^\[/) {
        s="";
        for (i=3; i<=NF; i++) { s = s (s==""?"":" ") $i; if ($i ~ /\]$/) break }
        gsub(/^\[|\]$/, "", s);           # strip the surrounding brackets
        k = split(s, a, " ");
        if (a[1] != "" && a[1] != "+yolo") mode = a[1];
        for (j=1; j<=k; j++) if (a[j]=="+yolo") yolo="on";
        for (j=2; j<=k; j++) if (a[j] != "+yolo" && bad=="") bad=a[j];
      }
      printf "%s\037%s\037%s\037%s\037%s\n", $2, mode, yolo, bad, $0;
      if (lint!=1) exit;
    }
  ' "$REG"
}

# The single owner of "is this annotation well formed": FAULT holds the operator-
# facing reason, or is empty when the line parses cleanly. Both the per-project
# warning and --lint report through it, so the two never drift apart.
FAULT=
classify_annotation() {  # <mode> <unrecognized token>
  FAULT=
  if [ -n "$2" ]; then
    FAULT="unrecognized annotation token \"$2\""
    return 0
  fi
  case "$1" in
    no-mistakes|direct-PR|local-only|no-mistakes-prod-only) ;;
    *) FAULT="unknown mode \"$1\"" ;;
  esac
}

if [ "$LINT" -eq 1 ]; then
  [ -f "$REG" ] || exit 0
  while IFS=$'\037' read -r lname lmode _ lbad lraw; do
    [ -n "$lname" ] || continue
    classify_annotation "$lmode" "$lbad"
    [ -n "$FAULT" ] || continue
    printf '%s\t%s\t%s\n' "$lname" "$FAULT" "$lraw"
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

IFS=$'\037' read -r _ mode yolo bad _ <<EOF
$row
EOF
classify_annotation "$mode" "$bad"
if [ -n "$FAULT" ]; then
  echo "warn: registry-invalid: $FAULT for $NAME; defaulting to no-mistakes off" >&2
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
