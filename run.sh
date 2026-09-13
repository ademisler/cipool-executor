#!/usr/bin/env bash
set -euo pipefail

printf 'CI Pool run: %s\n' "${CIPOOL_RUN_ID:-unknown}"
printf 'Job: %s\n' "${CIPOOL_JOB:-unknown}"
printf 'Repository: %s\n' "${CIPOOL_REPOSITORY:-none}"
printf 'Commit: %s\n' "${CIPOOL_SHA:-none}"
printf 'Branch: %s\n' "${CIPOOL_BRANCH:-none}"

case "${CIPOOL_JOB:-smoke-pass}" in
  smoke-pass)
    echo "CI Pool smoke pass"
    ;;
  smoke-fail)
    echo "CI Pool controlled smoke failure" >&2
    exit 42
    ;;
  *)
    echo "Target checkout is not enabled yet for job: ${CIPOOL_JOB}" >&2
    exit 64
    ;;
esac
