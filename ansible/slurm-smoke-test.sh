#!/usr/bin/env bash
set -euo pipefail

PARTITION="${PARTITION:-${1:-compute}}"
TIMEOUT_SECONDS="${TIMEOUT_SECONDS:-180}"
POLL_SECONDS="${POLL_SECONDS:-2}"

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1" >&2
    exit 1
  fi
}

for cmd in sinfo srun sbatch squeue scontrol; do
  require_cmd "$cmd"
done

echo "[1/5] Checking Slurm controller reachability"
scontrol ping

echo "[2/5] Checking nodes in partition '${PARTITION}'"
sinfo -p "$PARTITION" -N -o "%14N %8T %6c %10m"

echo "[3/5] Running interactive test with srun"
srun -p "$PARTITION" -N1 -n1 bash -lc 'echo "SRUN_OK host=$(hostname) time=$(date -Iseconds)"'

job_script="$(mktemp /tmp/slurm-smoke-XXXXXX.sbatch)"
trap 'rm -f "$job_script"' EXIT

cat >"$job_script" <<EOF
#!/usr/bin/env bash
#SBATCH --job-name=slurm-smoke
#SBATCH --partition=$PARTITION
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --time=00:02:00
#SBATCH --output=slurm-smoke-%j.out

echo "SBATCH_START job=\$SLURM_JOB_ID host=\$(hostname) time=\$(date -Iseconds)"
sleep 5
echo "SBATCH_DONE job=\$SLURM_JOB_ID host=\$(hostname) time=\$(date -Iseconds)"
EOF

job_id="$(sbatch --parsable "$job_script")"
output_file="slurm-smoke-${job_id}.out"
echo "[4/5] Submitted batch smoke job ${job_id}; waiting for completion"

deadline=$(( $(date +%s) + TIMEOUT_SECONDS ))
while true; do
  state="$(squeue -h -j "$job_id" -o "%T")"
  if [[ -z "$state" ]]; then
    break
  fi

  echo "  job ${job_id} state: ${state}"
  if (( $(date +%s) > deadline )); then
    echo "Timed out waiting for job ${job_id} after ${TIMEOUT_SECONDS}s." >&2
    scontrol show job "$job_id" || true
    exit 1
  fi
  sleep "$POLL_SECONDS"
done

job_state="$(
  scontrol show job "$job_id" 2>/dev/null \
    | grep -o 'JobState=[A-Z_]*' \
    | head -n1 \
    | cut -d= -f2
)"

if [[ -n "$job_state" && "$job_state" != "COMPLETED" ]]; then
  echo "Smoke job ${job_id} finished in state ${job_state} (expected COMPLETED)." >&2
  scontrol show job "$job_id" || true
  exit 1
fi

echo "[5/5] Inspecting output file ${output_file}"
if [[ -f "$output_file" ]]; then
  cat "$output_file"
else
  echo "Warning: expected output file '${output_file}' was not found." >&2
fi

echo "Slurm smoke test passed for partition '${PARTITION}'."
