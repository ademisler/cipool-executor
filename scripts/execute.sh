#!/usr/bin/env bash
set -euo pipefail
set +x
umask 077
EXECUTOR_SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CIPOOL_ROOT=/tmp/cipool
CIPOOL_LEASE_DIR="$CIPOOL_ROOT/lease"
CIPOOL_CHECKOUT_DIR="$CIPOOL_ROOT/repo"
export CIPOOL_ARTIFACT_DIR="$CIPOOL_ROOT/artifacts"
export CIPOOL_INPUTS_FILE="$CIPOOL_ROOT/inputs.json"
CIPOOL_TEST_RESULTS_DIR="$CIPOOL_ROOT/test-results"

for name in repository sha branch base_sha job command job_spec_hash profile runtime timeout; do
  path="$CIPOOL_LEASE_DIR/$name"
  [[ -f "$path" && ! -L "$path" ]] || { echo "Prepared executor context is missing: $name" >&2; exit 66; }
done
[[ ! -e "$CIPOOL_LEASE_DIR/checkout_token" && ! -e "$CIPOOL_LEASE_DIR/lease.json" && ! -e "$CIPOOL_LEASE_DIR/git-askpass.sh" ]] || {
  echo "Checkout authority survived into workload phase" >&2
  exit 66
}

repository=$(<"$CIPOOL_LEASE_DIR/repository")
source_sha=$(<"$CIPOOL_LEASE_DIR/sha")
source_branch=$(<"$CIPOOL_LEASE_DIR/branch")
base_sha=$(<"$CIPOOL_LEASE_DIR/base_sha")
job_key=$(<"$CIPOOL_LEASE_DIR/job")
job_command=$(<"$CIPOOL_LEASE_DIR/command")
job_spec_hash=$(<"$CIPOOL_LEASE_DIR/job_spec_hash")
profile=$(<"$CIPOOL_LEASE_DIR/profile")
runtime=$(<"$CIPOOL_LEASE_DIR/runtime")
timeout_seconds=$(<"$CIPOOL_LEASE_DIR/timeout")

[[ "$source_sha" =~ ^[0-9a-f]{40}$ && "$timeout_seconds" =~ ^[0-9]+$ && "$timeout_seconds" -ge 60 && "$timeout_seconds" -le 3300 ]] || {
  echo "Prepared executor runtime identity is invalid" >&2
  exit 66
}
[[ "$(git -C "$CIPOOL_CHECKOUT_DIR" rev-parse HEAD)" == "$source_sha" ]] || { echo "Prepared exact checkout drifted" >&2; exit 67; }
[[ "$(git -C "$CIPOOL_CHECKOUT_DIR" remote get-url origin)" == "https://github.com/$repository.git" ]] || { echo "Prepared checkout remote drifted" >&2; exit 67; }

export CIPOOL_JOB="$job_key" CIPOOL_SHA="$source_sha" CIPOOL_BRANCH="$source_branch" CIPOOL_BASE_SHA="$base_sha" CIPOOL_RUNTIME="$runtime" CI=true CIRCLECI=true
cd "$CIPOOL_CHECKOUT_DIR"
started=$(python3 -c 'import time; print(time.monotonic_ns())')
set +e
python3 "$EXECUTOR_SCRIPT_DIR/run-workload.py" "$timeout_seconds" "$job_key" "$job_command"
exit_code=$?
set -e
finished=$(python3 -c 'import time; print(time.monotonic_ns())')
workload_ms=$(( (finished - started) / 1000000 ))

receipt="$CIPOOL_ARTIFACT_DIR/cipool-receipt.json"
python3 - "$receipt" "$CIPOOL_RUN_ID" "$source_sha" "$job_spec_hash" "$profile" "$runtime" "$exit_code" "$workload_ms" <<'PY'
import json, os, pathlib, sys
path = pathlib.Path(sys.argv[1])
path.write_text(json.dumps({
    "runId":sys.argv[2],"sha":sys.argv[3],"jobSpecHash":sys.argv[4],
    "profile":sys.argv[5],"runtime":sys.argv[6],"exitCode":int(sys.argv[7]),
    "workloadDurationMs":int(sys.argv[8]),"authority":"diagnostic-only"
},sort_keys=True)+"\n", encoding="utf-8")
os.chmod(path, 0o600)
PY
printf 'CIPOOL_WORKLOAD_TIMING job=%s runtime=%s duration_ms=%s\n' "$job_key" "$runtime" "$workload_ms"
exit "$exit_code"
