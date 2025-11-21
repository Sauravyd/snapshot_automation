#!/usr/bin/env bash
# snapshot_aws_cleanup.sh
# Deletes EBS snapshots with tag AutomatedBackup=true once they pass RetentionDays.

set -euo pipefail

MODE="dry-run"
REGION=""
PROFILE="default"
LOGFILE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --run) MODE="run"; shift ;;
    --region) REGION="$2"; shift 2 ;;
    --profile) PROFILE="$2"; shift 2 ;;
    --log) LOGFILE="$2"; shift 2 ;;
    *)
      echo "Usage: $0 [--run] [--region REGION] [--profile PROFILE] [--log logfile]"
      exit 1 ;;
  esac
done

mkdir -p snapshot_logs
if [[ -z "${LOGFILE:-}" ]]; then
  LOGFILE="snapshot_logs/aws-cleanup-$(date +%Y%m%d-%H%M%S).log"
fi

echo "Starting AWS snapshot cleanup: $(date -u)" | tee -a "$LOGFILE"
echo "Mode: $MODE" | tee -a "$LOGFILE"

if [[ -z "$REGION" ]]; then
  echo "No region provided; using default AWS region from configuration." | tee -a "$LOGFILE"
fi

# Fetch snapshots owned by us with AutomatedBackup=true
if [[ -n "$REGION" ]]; then
  aws ec2 describe-snapshots \
    --owner-ids self \
    --region "$REGION" \
    --profile "$PROFILE" \
    --filters "Name=tag:AutomatedBackup,Values=true" \
    --output json > /tmp/aws_snaps.json
else
  aws ec2 describe-snapshots \
    --owner-ids self \
    --profile "$PROFILE" \
    --filters "Name=tag:AutomatedBackup,Values=true" \
    --output json > /tmp/aws_snaps.json
fi

python3 - "$LOGFILE" "$MODE" "${REGION:-}" "${PROFILE}" << 'EOF'
import json, datetime, sys, subprocess, os

logfile = sys.argv[1]
mode    = sys.argv[2]
region  = sys.argv[3] if len(sys.argv) > 3 else ""
profile = sys.argv[4] if len(sys.argv) > 4 else ""

def log(msg):
    print(msg)
    with open(logfile, "a") as f:
        f.write(msg + "\n")

try:
    with open("/tmp/aws_snaps.json") as f:
        data = json.load(f)
except Exception as e:
    log(f"ERROR loading JSON: {e}")
    sys.exit(1)

snaps = data.get("Snapshots", [])
now = datetime.datetime.now(datetime.timezone.utc)
to_del = []

if mode == "dry-run":
    log("\n📌 DRY-RUN — SNAPSHOT RETENTION CHECK")
    log("%-20s %-12s %-10s %-6s %-6s" % ("SNAPSHOT_ID", "RETENTION", "START", "AGE", "DEL?"))
    log("-" * 70)

for s in snaps:
    snap_id = s.get("SnapshotId")
    start   = s.get("StartTime")
    tags    = {t["Key"]: t["Value"] for t in s.get("Tags", [])}

    auto = str(tags.get("AutomatedBackup", "")).lower() in ("true","1","yes")
    if not auto:
        continue

    try:
        retention = int(tags.get("RetentionDays", "14"))
    except:
        retention = 14

    if not start:
        continue

    if isinstance(start, str):
        created = datetime.datetime.fromisoformat(start.replace("Z","+00:00"))
    else:
        created = start

    age = (now - created).days
    eligible = age >= retention

    if mode == "dry-run":
        mark = "YES" if eligible else "NO"
        log("%-20s %-12s %-10s %-6s %-6s" % (snap_id, retention, created.date(), age, mark))

    if eligible and mode == "run":
        to_del.append((snap_id, retention, age, created))

if mode == "run":
    deleted = 0
    for snap_id, ret, age, created in to_del:
        log(f"DELETE: {snap_id} (age {age} >= {ret})")
        cmd = ["aws", "ec2", "delete-snapshot", "--snapshot-id", snap_id]
        if region:
            cmd += ["--region", region]
        if profile:
            cmd += ["--profile", profile]
        subprocess.run(cmd, check=False)
        deleted += 1
    log(f"\n✔ Deleted {deleted} snapshots.")
else:
    log("\n✔ DRY RUN ONLY — NO DELETIONS PERFORMED")

log("Cleanup complete.")
EOF

echo "Logfile: $LOGFILE"
