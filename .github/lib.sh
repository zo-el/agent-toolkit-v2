# What the scripts a workflow runs share: the one line each run writes about what
# it did, and the arguments they are all called with. Sourced, never run.

# Where the run's own summary shows it, and on stdout for the step log.
say() {
  printf '%s\n' "$1"
  [ -z "${GITHUB_STEP_SUMMARY:-}" ] || printf '%s\n' "$1" >>"$GITHUB_STEP_SUMMARY"
}

# The repository comes from the workflow, so a script run anywhere else says so
# rather than guessing which repository it is about.
called_for_a_commit() { # the script's own arguments
  [ -n "${GITHUB_REPOSITORY:-}" ] && [ $# -eq 1 ] && [ -n "$1" ]
}
