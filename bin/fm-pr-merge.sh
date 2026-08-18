#!/usr/bin/env bash
# Merge a task's PR after recording pr= and any available pr_head= through
# bin/fm-pr-check.sh, so teardown can verify landed work after squash merges.
# The full canonical GitHub PR URL is parsed by bin/fm-pr-lib.sh and the derived
# owner/repository and PR number are passed to gh-axi as separate arguments.
#
# Merge method defaults to --squash when the caller passes none of --squash,
# --merge, --rebase, or --method after the optional -- separator. Extra args
# must not include --repo or -R because the repository comes only from the URL.
#
# Before merging, scans the PR's commit trailers for a Co-Authored-By line
# naming a known AI coding agent (AGENTS.md section 1 forbids this). A match
# refuses the merge unless FM_PR_MERGE_ALLOW_AGENT_COAUTHOR=1 confirms it is a
# genuine human co-author whose name collides, so a legitimate external PR can
# never be permanently blocked. Missing `gh` or a failed forge lookup only
# warns and proceeds, so an infrastructure hiccup never blocks a merge either.
# Usage: fm-pr-merge.sh <task-id> <pr-url> [-- <extra gh-axi pr merge args>]
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"

if [ "$#" -lt 2 ]; then
  echo "error: invalid PR merge request" >&2
  exit 2
fi
ID=$1
RAW_URL=$2
# bin/fm-pr-lib.sh parses GitLab merge request URLs so the watcher can follow
# them, but this path still addresses only GitHub by owner/repository. The
# provider check holds that refusal exactly as it was until merge parity lands.
if ! fm_pr_task_id_valid "$ID" || ! fm_pr_url_parse "$RAW_URL" \
  || [ "$FM_PR_PROVIDER" != github ]; then
  echo "error: invalid PR merge request" >&2
  exit 2
fi
URL=$FM_PR_URL
PR_OWNER=$FM_PR_OWNER
PR_REPO=$FM_PR_REPO
PR_NUMBER=$FM_PR_NUMBER
shift 2
[ "${1:-}" = "--" ] && shift

caller_has_merge_method() {
  local arg
  for arg in "$@"; do
    case "$arg" in
      --squash|--merge|--rebase|--method|--method=*) return 0 ;;
    esac
  done
  return 1
}

reject_repo_overrides() {
  local arg
  for arg in "$@"; do
    case "$arg" in
      --repo|--repo=*|-R|-R?*)
        echo "error: extra merge arguments must not override the repository" >&2
        return 1
        ;;
    esac
  done
}

# Scoped to the literal Co-Authored-By trailer line, case-insensitively, so
# ordinary prose mentioning a vendor name elsewhere in a commit message never
# matches. Names come from AGENTS.md's verified harness list plus the vendor
# defaults it implies (AGENTS.md section 4).
AGENT_COAUTHOR_PATTERN='^Co-Authored-By:.*(Claude|Anthropic|Opus|Sonnet|Haiku|Fable|noreply@anthropic\.com|ChatGPT|OpenAI|Codex|Copilot|Cursor Agent|xAI|Grok|Kimi|Moonshot|Gemini)'

refuse_agent_coauthor_commits() {
  local owner=$1 repo=$2 number=$3 url=$4 commit_text agent_hits
  if ! command -v gh >/dev/null 2>&1; then
    echo "warning: gh not found on PATH; skipping the agent-co-author commit check for $url" >&2
    return 0
  fi
  if ! commit_text=$(gh pr view "$number" --repo "$owner/$repo" --json commits \
      --jq '.commits[] | .messageHeadline + "\n" + .messageBody' 2>/dev/null); then
    echo "warning: could not fetch commit messages for $url to check for an agent co-author trailer; proceeding" >&2
    return 0
  fi
  agent_hits=$(printf '%s\n' "$commit_text" | grep -Ei "$AGENT_COAUTHOR_PATTERN" || true)
  [ -n "$agent_hits" ] || return 0
  if [ "${FM_PR_MERGE_ALLOW_AGENT_COAUTHOR:-}" != 1 ]; then
    echo "error: PR $url has a commit trailer naming what looks like an AI coding agent as a co-author:" >&2
    printf '%s\n' "$agent_hits" | sed 's/^/  /' >&2
    echo "error: AGENTS.md section 1 forbids this. If this is a genuine human co-author whose name collides, re-run with FM_PR_MERGE_ALLOW_AGENT_COAUTHOR=1 to confirm and merge anyway." >&2
    return 1
  fi
  echo "warning: merging PR $url despite an agent-like co-author trailer (FM_PR_MERGE_ALLOW_AGENT_COAUTHOR=1 confirmed)" >&2
}

reject_repo_overrides "$@" || exit 1

# Task-derived paths are constructed only after the canonical ID validation.
META="$STATE/$ID.meta"
if [ ! -f "$META" ] || [ -L "$META" ]; then
  echo "error: task metadata is unavailable" >&2
  exit 1
fi

"$SCRIPT_DIR/fm-pr-check.sh" "$ID" "$URL"
grep -qxF "pr=$URL" "$META" || {
  echo "error: PR metadata recording failed" >&2
  exit 1
}

refuse_agent_coauthor_commits "$PR_OWNER" "$PR_REPO" "$PR_NUMBER" "$URL" || exit 1

merge_args=()
if ! caller_has_merge_method "$@"; then
  merge_args=(--squash)
fi

gh-axi pr merge "$PR_NUMBER" --repo "$PR_OWNER/$PR_REPO" "${merge_args[@]+"${merge_args[@]}"}" "$@"
