#!/usr/bin/env bash
# fm-test-env-lib.sh - ONE owner of the home-selection environment scrub.
#
# Every firstmate script resolves its home as "${FM_HOME:-${FM_ROOT_OVERRIDE:-...}}",
# so an ambient FM_HOME silently OUTRANKS the FM_ROOT_OVERRIDE a case uses to
# point at its fixture, and the case then asserts against whatever home the
# invoking shell happens to name. Every firstmate session exports FM_HOME and CI
# exports none of these, so a copy of this list that drifts stays green in CI
# and answers a different question locally - which is why the list has one owner
# rather than one copy per execution path.
#
# Consumers:
#   bin/fm-test-run.sh              serial path and each --jobs worker
#   bin/fm-test-isolation-proof.sh  each concurrent proof worker
#   tests/lib.sh                    at source time, so a suite invoked directly
#                                   is protected identically to a runner-driven
#                                   one
#
# A new home-affecting variable is added HERE and every path inherits it.

FM_TEST_HOME_SELECTION_VARS=(
  FM_HOME
  FM_STATE_OVERRIDE
  FM_DATA_OVERRIDE
  FM_ROOT_OVERRIDE
  FM_PROJECTS_OVERRIDE
  FM_CONFIG_OVERRIDE
  FM_BACKEND
)

# Drop the ambient home selection from the CURRENT shell. It clears only what
# was inherited at the moment of the call: a value the caller sets afterwards
# for itself - a suite's own default, a case's per-invocation override - still
# wins, which is the whole point of scrubbing before anything runs rather than
# pinning a home.
fm_test_scrub_home_selection_env() {
  unset "${FM_TEST_HOME_SELECTION_VARS[@]}" 2>/dev/null || true
}
