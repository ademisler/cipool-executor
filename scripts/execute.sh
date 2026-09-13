#!/usr/bin/env bash
set -euo pipefail
set +x
umask 077
EXECUTOR_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

: "${CIPOOL_RUN_ID:?missing CIPOOL_RUN_ID}"
: "${CIPOOL_BROKER_URL:?missing CIPOOL_BROKER_URL}"
: "${CIPOOL_EXECUTOR_REVISION:?missing CIPOOL_EXECUTOR_REVISION}"
: "${CIRCLE_OIDC_TOKEN_V2:?CircleCI OIDC token V2 is required}"

case "$CIPOOL_BROKER_URL" in
  https://ci.ademisler.com) ;;
  *) echo "Refusing non-canonical CI Pool broker" >&2; exit 65 ;;
esac
[[ "$CIPOOL_EXECUTOR_REVISION" =~ ^[0-9a-f]{40}$ ]] || { echo "Executor revision must be an immutable Git SHA" >&2; exit 65; }
[[ "$(git rev-parse HEAD)" == "$CIPOOL_EXECUTOR_REVISION" ]] || { echo "Executor checkout does not match the admitted revision" >&2; exit 65; }

# Remove any executor checkout credential helpers before target code can run.
git remote set-url origin "https://github.com/${CIRCLE_PROJECT_USERNAME}/${CIRCLE_PROJECT_REPONAME}.git" 2>/dev/null || true
while IFS= read -r key; do git config --local --unset-all "$key" || true; done < <(git config --local --name-only --get-regexp '^(http\..*\.extraheader|credential\..*|credential\.helper)$' 2>/dev/null || true)
rm -f "$HOME/.git-credentials" "$HOME/.config/git/credentials" 2>/dev/null || true

CIPOOL_ROOT=/tmp/cipool
CIPOOL_LEASE_DIR="$CIPOOL_ROOT/lease"
CIPOOL_CHECKOUT_DIR="$CIPOOL_ROOT/repo"
export CIPOOL_ARTIFACT_DIR="$CIPOOL_ROOT/artifacts"
export CIPOOL_INPUTS_FILE="$CIPOOL_ROOT/inputs.json"
CIPOOL_TEST_RESULTS_DIR="$CIPOOL_ROOT/test-results"
rm -rf -- "$CIPOOL_ROOT"
mkdir -p "$CIPOOL_LEASE_DIR" "$CIPOOL_CHECKOUT_DIR" "$CIPOOL_ARTIFACT_DIR" "$CIPOOL_TEST_RESULTS_DIR"
chmod 700 "$CIPOOL_ROOT" "$CIPOOL_LEASE_DIR" "$CIPOOL_CHECKOUT_DIR" "$CIPOOL_ARTIFACT_DIR" "$CIPOOL_TEST_RESULTS_DIR"

lease_file="$CIPOOL_LEASE_DIR/lease.json"
curl --fail-with-body --silent --show-error --max-time 30 \
  -H "Authorization: Bearer ${CIRCLE_OIDC_TOKEN_V2}" \
  -H 'Content-Type: application/json' \
  --data "{\"runId\":\"${CIPOOL_RUN_ID}\"}" \
  "$CIPOOL_BROKER_URL/v1/runner/lease" >"$lease_file"
chmod 600 "$lease_file"

python3 - "$lease_file" "$CIPOOL_LEASE_DIR" "$CIPOOL_INPUTS_FILE" <<'PY'
import json, os, pathlib, sys
lease_path, output_dir, inputs_path = sys.argv[1:]
with open(lease_path, encoding="utf-8") as handle:
    data = json.load(handle)
if data.get("version") != 2:
    raise SystemExit("Enhanced executor requires a v2 OIDC lease")
required = {
    "repository": data["repository"], "sha": data["source"]["sha"],
    "branch": data["source"]["branch"], "base_sha": data["source"].get("baseSha") or "",
    "job": data["job"]["key"], "command": data["job"]["command"],
    "job_spec_hash": data["job"]["specHash"], "profile": data["job"]["profile"],
    "runtime": data["job"].get("runtime") or ("machine" if data["job"]["profile"] in {"heavy","machine-heavy"} else "node22"),
    "timeout": str(data["job"]["timeoutSeconds"]), "checkout_token": data["checkout"]["token"],
}
for name, value in required.items():
    path = pathlib.Path(output_dir, name)
    path.write_text(str(value), encoding="utf-8")
    os.chmod(path, 0o600)
pathlib.Path(inputs_path).write_text(json.dumps(data.get("inputs", {}), sort_keys=True, separators=(",", ":")), encoding="utf-8")
os.chmod(inputs_path, 0o600)
PY

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
export CIPOOL_GITHUB_TOKEN=$(<"$CIPOOL_LEASE_DIR/checkout_token")

[[ "$repository" == "$CIPOOL_EXPECTED_REPOSITORY" && "$source_sha" == "$CIPOOL_EXPECTED_SHA" && "$source_branch" == "$CIPOOL_EXPECTED_BRANCH" ]] || { echo "Lease source mismatch" >&2; exit 66; }
[[ "$job_key" == "$CIPOOL_EXPECTED_JOB" && "$job_spec_hash" == "$CIPOOL_EXPECTED_JOB_SPEC_HASH" && "$profile" == "$CIPOOL_EXPECTED_PROFILE" && "$runtime" == "$CIPOOL_EXPECTED_RUNTIME" ]] || { echo "Lease job snapshot mismatch" >&2; exit 66; }
[[ -z "$CIPOOL_EXPECTED_BASE_SHA" || "$base_sha" == "$CIPOOL_EXPECTED_BASE_SHA" ]] || { echo "Lease base SHA mismatch" >&2; exit 66; }
[[ "$source_sha" =~ ^[0-9a-f]{40}$ && "$timeout_seconds" =~ ^[0-9]+$ && "$timeout_seconds" -ge 60 && "$timeout_seconds" -le 3300 ]] || { echo "Lease runtime identity is invalid" >&2; exit 66; }

askpass="$CIPOOL_LEASE_DIR/git-askpass.sh"
cat >"$askpass" <<'ASKPASS'
#!/usr/bin/env bash
case "$1" in
  *Username*) printf '%s\n' 'x-access-token' ;;
  *) printf '%s\n' "$CIPOOL_GITHUB_TOKEN" ;;
esac
ASKPASS
chmod 700 "$askpass"
export GIT_ASKPASS="$askpass" GIT_TERMINAL_PROMPT=0

git -C "$CIPOOL_CHECKOUT_DIR" init --quiet
git -C "$CIPOOL_CHECKOUT_DIR" remote add origin "https://github.com/${repository}.git"
# Fetch the named branch history for diff/policy tools, then force the exact authorized SHA.
git -C "$CIPOOL_CHECKOUT_DIR" fetch --quiet --no-tags origin "+refs/heads/${source_branch}:refs/remotes/origin/${source_branch}"
git -C "$CIPOOL_CHECKOUT_DIR" fetch --quiet --no-tags origin "$source_sha"
if [[ -n "$base_sha" ]]; then git -C "$CIPOOL_CHECKOUT_DIR" fetch --quiet --no-tags origin "$base_sha"; fi

# All checkout/broker authority is gone before any target repository command.
unset CIPOOL_GITHUB_TOKEN GIT_ASKPASS CIRCLE_OIDC_TOKEN CIRCLE_OIDC_TOKEN_V2
rm -f "$askpass" "$lease_file" "$CIPOOL_LEASE_DIR/checkout_token"
git -C "$CIPOOL_CHECKOUT_DIR" checkout --quiet --detach "$source_sha"
git -C "$CIPOOL_CHECKOUT_DIR" remote set-url origin "https://github.com/${repository}.git"
while IFS= read -r key; do git -C "$CIPOOL_CHECKOUT_DIR" config --local --unset-all "$key" || true; done < <(git -C "$CIPOOL_CHECKOUT_DIR" config --local --name-only --get-regexp '^(http\..*\.extraheader|credential\..*|credential\.helper)$' 2>/dev/null || true)
[[ "$(git -C "$CIPOOL_CHECKOUT_DIR" rev-parse HEAD)" == "$source_sha" ]] || { echo "Exact checkout verification failed" >&2; exit 67; }
rm -rf "$CIPOOL_LEASE_DIR"

export CIPOOL_JOB="$job_key" CIPOOL_SHA="$source_sha" CIPOOL_BRANCH="$source_branch" CIPOOL_BASE_SHA="$base_sha" CIPOOL_RUNTIME="$runtime" CI=true CIRCLECI=true
cd "$CIPOOL_CHECKOUT_DIR"
set +e
# The trusted executor, not target repository background jobs, owns liveness.
# The supervisor preserves exact target exit status, emits bounded heartbeats and
# terminates the whole workload process group at the immutable CI Pool timeout.
python3 "$EXECUTOR_SCRIPT_DIR/run-workload.py" "$timeout_seconds" "$job_key" "$job_command"
exit_code=$?
set -e

# This artifact is diagnostic only. Provider terminal state remains authoritative.
receipt="$CIPOOL_ARTIFACT_DIR/cipool-receipt.json"
python3 - "$receipt" "$CIPOOL_RUN_ID" "$source_sha" "$job_spec_hash" "$profile" "$exit_code" <<'PY'
import json, os, pathlib, sys
path = pathlib.Path(sys.argv[1])
path.write_text(json.dumps({"runId":sys.argv[2],"sha":sys.argv[3],"jobSpecHash":sys.argv[4],"profile":sys.argv[5],"exitCode":int(sys.argv[6]),"authority":"diagnostic-only"},sort_keys=True)+"\n", encoding="utf-8")
os.chmod(path, 0o600)
PY
exit "$exit_code"
