#!/usr/bin/env bash
# snapshot_aws_create.sh
# Creates EBS snapshots for EC2 instances or volumes based on serverlist_aws.txt.
# Modes:
#   --dry-run : only preview
#   --run     : actually create snapshots

set -euo pipefail

if [[ $# -lt 2 ]]; then
  echo "Usage: $0 <serverlist-file> [--dry-run | --run]"
  exit 1
fi

SERVERLIST="$1"
MODE="$2"   # --dry-run or --run

if [[ "$MODE" != "--run" && "$MODE" != "--dry-run" ]]; then
  echo "ERROR: MODE must be --dry-run or --run"
  exit 1
fi

command -v aws >/dev/null 2>&1 || { echo "ERROR: aws CLI not found."; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "ERROR: python3 not found."; exit 3; }

DATE_TAG="$(date +%d-%m-%Y)"
TIME_TAG="$(date +%H:%M:%S)"
TIME_SAFE="$(date +%H-%M-%S)"

LOGDIR="./snapshot_logs"
mkdir -p "$LOGDIR"
LOGFILE="$LOGDIR/aws-create-${DATE_TAG}-${TIME_SAFE}.log"

echo "Starting AWS snapshot script: $(date -u)" | tee -a "$LOGFILE"
echo "Mode: $MODE" | tee -a "$LOGFILE"

trim() { printf "%s" "$1" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'; }

# -------- DRY-RUN TABLE HEADER --------
if [[ "$MODE" == "--dry-run" ]]; then
  echo
  echo "📌 DRY-RUN PREVIEW (NO SNAPSHOTS WILL BE CREATED):"
  printf "\n%-18s %-12s %-8s %-10s %-10s %-16s %-40s\n" \
        "TARGET" "REGION" "SCOPE" "RET(D)" "KIND" "VOLUME" "SNAPSHOT NAME"
  printf "%s\n" "------------------------------------------------------------------------------------------------------------------------"
fi

# -------- MAIN LOOP --------
while IFS= read -r RAWLINE || [[ -n "$RAWLINE" ]]; do
  LINE="$(trim "$RAWLINE")"
  [[ -z "$LINE" || "${LINE:0:1}" == "#" ]] && continue

  IFS=';' read -r F1 F2 F3 F4 REST <<< "$LINE"

  TARGET_RAW="$(trim "${F1:-}")"
  REGION="$(trim "${F2:-}")"
  RETENTION="$(trim "${F3:-}")"
  SCOPE_RAW="$(trim "${F4:-}")"
  REASON="$(trim "${REST:-}")"

  TARGET="$TARGET_RAW"
  SCOPE_UPPER="$(echo "$SCOPE_RAW" | tr '[:lower:]' '[:upper:]')"

  if [[ -z "$TARGET" || -z "$REGION" || -z "$RETENTION" || -z "$SCOPE_RAW" ]]; then
    echo "Skipping invalid line (missing required fields): $RAWLINE" | tee -a "$LOGFILE"
    continue
  fi

  if ! [[ "$RETENTION" =~ ^[0-9]+$ ]]; then
    echo "Invalid RetentionDays '$RETENTION' for $TARGET. Skipping." | tee -a "$LOGFILE"
    continue
  fi

  echo "------------------------------------------------------------" | tee -a "$LOGFILE"
  echo "Target: $TARGET   Region: $REGION   Scope: $SCOPE_UPPER   Retention: $RETENTION   Reason: $REASON" | tee -a "$LOGFILE"

  # Determine if target is instance or volume
  IS_INSTANCE=false
  if [[ "$TARGET" == i-* ]]; then
    IS_INSTANCE=true
  elif [[ "$TARGET" == vol-* ]]; then
    IS_INSTANCE=false
  else
    echo "ERROR: TARGET '$TARGET' is neither instance-id (i-*) nor volume-id (vol-*). Skipping." | tee -a "$LOGFILE"
    continue
  fi

  # Helper to create / preview a snapshot for a single volume
  do_snapshot() {
    local vol_id="$1"
    local kind="$2"
    local snap_name="$3"

    if [[ "$MODE" == "--dry-run" ]]; then
      printf "%-18s %-12s %-8s %-10s %-10s %-16s %-40s\n" \
        "$TARGET" "$REGION" "$SCOPE_UPPER" "$RETENTION" "$kind" "$vol_id" "$snap_name"
      return 0
    fi

    echo "Creating snapshot: $snap_name for volume $vol_id ($kind)" | tee -a "$LOGFILE"

    aws ec2 create-snapshot \
      --volume-id "$vol_id" \
      --region "$REGION" \
      --description "$REASON" \
      --tag-specifications "ResourceType=snapshot,Tags=[\
{Key=Name,Value=$snap_name},\
{Key=Target,Value=$TARGET},\
{Key=Scope,Value=$kind},\
{Key=Reason,Value=$REASON},\
{Key=AutomatedBackup,Value=true},\
{Key=RetentionDays,Value=$RETENTION},\
{Key=Date,Value=$DATE_TAG},\
{Key=Time,Value=$TIME_TAG}\
]" >/dev/null
  }

  if $IS_INSTANCE; then
    # -------- INSTANCE PATH: describe instance -> get root + data volumes --------
    INFO_JSON="$(aws ec2 describe-instances \
      --instance-ids "$TARGET" \
      --region "$REGION" \
      --output json 2>/dev/null || true)"

    if [[ -z "$INFO_JSON" || "$INFO_JSON" == "null" ]]; then
      echo "ERROR: instance $TARGET not found in $REGION. Skipping." | tee -a "$LOGFILE"
      continue
    fi

    ROOT_DEV="$(echo "$INFO_JSON" | python3 - << 'PY'
import sys, json
d=json.load(sys.stdin)
inst=d["Reservations"][0]["Instances"][0]
print(inst.get("RootDeviceName",""))
PY
)"
    if [[ -z "$ROOT_DEV" ]]; then
      echo "ERROR: Could not determine root device for $TARGET. Skipping." | tee -a "$LOGFILE"
      continue
    fi

    MAP_JSON="$(echo "$INFO_JSON" | python3 - << 'PY'
import sys, json
d=json.load(sys.stdin)
inst=d["Reservations"][0]["Instances"][0]
for b in inst.get("BlockDeviceMappings", []):
    dev=b.get("DeviceName")
    vol=b.get("Ebs",{}).get("VolumeId")
    if dev and vol:
        print(dev, vol)
PY
)"

    ROOT_VOL=""
    DATA_VOLS=()
    while read -r DEV VID; do
      [[ -z "$DEV" || -z "$VID" ]] && continue
      if [[ "$DEV" == "$ROOT_DEV" ]]; then
        ROOT_VOL="$VID"
      else
        DATA_VOLS+=("$VID")
      fi
    done <<< "$MAP_JSON"

    VOLS_TO_SNAP=()
    KINDS=()

    case "$SCOPE_UPPER" in
      ROOT|BOTH)
        [[ -n "$ROOT_VOL" ]] && { VOLS_TO_SNAP+=("$ROOT_VOL"); KINDS+=("ROOT"); }
        ;;
    esac

    case "$SCOPE_UPPER" in
      DATA|BOTH)
        if ((${#DATA_VOLS[@]} > 0)); then
          for v in "${DATA_VOLS[@]}"; do
            VOLS_TO_SNAP+=("$v")
            KINDS+=("DATA")
          done
        fi
        ;;
    esac

    if ((${#VOLS_TO_SNAP[@]} == 0)); then
      echo "No volumes selected for $TARGET with scope=$SCOPE_UPPER. Skipping." | tee -a "$LOGFILE"
      continue
    fi

    for idx in "${!VOLS_TO_SNAP[@]}"; do
      VOL_ID="${VOLS_TO_SNAP[$idx]}"
      KIND="${KINDS[$idx]}"
      SNAP_NAME="${TARGET}-${DATE_TAG}-${TIME_SAFE}-automated-backup-${KIND,,}-${idx}"
      do_snapshot "$VOL_ID" "$KIND" "$SNAP_NAME"
    done

  else
    # -------- VOLUME PATH: direct volume snapshot --------
    VOL_ID="$TARGET"
    KIND="VOLUME"
    SNAP_NAME="${VOL_ID}-${DATE_TAG}-${TIME_SAFE}-automated-backup"
    do_snapshot "$VOL_ID" "$KIND" "$SNAP_NAME"
  fi

done < "$SERVERLIST"

echo "AWS snapshot creation completed. Mode: $MODE" | tee -a "$LOGFILE"
