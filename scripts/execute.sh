#!/usr/bin/env bash
set -euo pipefail

RUN_ID="${1:-}"
TICKET="${2:-}"
BROKER="${3:-}"

if [[ -z "$RUN_ID" || -z "$TICKET" || -z "$BROKER" ]]; then
  echo "CI Pool lease parameters are missing" >&2
  exit 64
fi

umask 077
LEASE_FILE="$(mktemp)"
cleanup() {
  rm -f "$LEASE_FILE"
  if [[ -d target ]]; then
    git -C target remote set-url origin redacted://cipool >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

HTTP_CODE="$(curl --silent --show-error --output "$LEASE_FILE" --write-out '%{http_code}' \
  --request POST "$BROKER/v1/runner/lease" \
  --header 'content-type: application/json' \
  --data "{\"runId\":\"$RUN_ID\",\"ticket\":\"$TICKET\"}")"
if [[ "$HTTP_CODE" != "200" ]]; then
  echo "CI Pool lease failed with HTTP $HTTP_CODE" >&2
  cat "$LEASE_FILE" >&2
  exit 65
fi

json_field() {
  node -e 'const fs=require("fs"); const data=JSON.parse(fs.readFileSync(process.argv[1],"utf8")); const value=data[process.argv[2]]; if(value===undefined||value===null) process.exit(2); process.stdout.write(String(value));' "$LEASE_FILE" "$1"
}

REPOSITORY="$(json_field repository)"
SHA="$(json_field sha)"
COMMAND="$(json_field command)"
JOB="$(json_field job)"
GITHUB_TOKEN="$(json_field githubToken)"

if [[ ! "$REPOSITORY" =~ ^ademisler/[A-Za-z0-9_.-]+$ ]]; then
  echo "CI Pool rejected repository scope" >&2
  exit 66
fi
if [[ ! "$SHA" =~ ^[0-9a-fA-F]{40}$ ]]; then
  echo "CI Pool rejected commit SHA" >&2
  exit 67
fi
if [[ -z "$COMMAND" || "$COMMAND" == "null" || -z "$JOB" || "$JOB" == "null" || -z "$GITHUB_TOKEN" || "$GITHUB_TOKEN" == "null" ]]; then
  echo "CI Pool lease is incomplete" >&2
  exit 68
fi

export GIT_TERMINAL_PROMPT=0
git init target >/dev/null
git -C target remote add origin "https://x-access-token:${GITHUB_TOKEN}@github.com/${REPOSITORY}.git"
git -C target fetch --depth=1 origin "$SHA" >/dev/null
git -C target checkout --detach FETCH_HEAD >/dev/null
git -C target remote set-url origin redacted://cipool
unset GITHUB_TOKEN

cd target
export CIPOOL_RUN_ID="$RUN_ID"
export CIPOOL_JOB="$JOB"
export CIPOOL_REPOSITORY="$REPOSITORY"
export CIPOOL_SHA="$SHA"
printf 'CIPOOL_EVENT {"type":"checkout_finished","repository":"%s","sha":"%s"}\n' "$REPOSITORY" "$SHA"
printf 'CIPOOL_EVENT {"type":"job_started","run_id":"%s"}\n' "$RUN_ID"
set +e
bash -lc "$COMMAND"
EXIT_CODE=$?
set -e
printf 'CIPOOL_EVENT {"type":"job_finished","run_id":"%s","exit_code":%d}\n' "$RUN_ID" "$EXIT_CODE"
exit "$EXIT_CODE"
