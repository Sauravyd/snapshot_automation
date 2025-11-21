#!/usr/bin/env bash
# snapshot_automated_v3.sh
# Reads serverlist_v2.txt, supports:
# - VM target (OS/Data/Both)
# - Disk target (single disk snapshot)
# - Incremental / Full (with fallback)
# - Dry-run mode (--dry-run): prints table only, no snapshot created
# - Run mode (--run): actually creates snapshots

set -euo pipefail

########################################
# MODE HANDLING
########################################
if [[ $# -lt 2 ]]; then
  echo "Usage: $0 <serverlist-file> [--dry-run | --run]"
  exit 1
fi

SERVERLIST="$1"
MODE="$2"   # --dry-run or --run

if [[ "$MODE" != "--run" && "$MODE" != "--dry-run" ]]; then
  echo "ERROR: You must use --dry-run OR --run"
  exit 1
fi

command -v az >/dev/null 2>&1 || { echo "ERROR: az CLI not found."; exit 2; }

########################################
# BASICS & LOGGING
########################################
DATE_TAG="$(date +%d-%m-%Y)"
TIME_TAG="$(date +%H:%M:%S)"       # For tags
TIME_SAFE="$(date +%H-%M-%S)"      # For resource names

LOGDIR="./snapshot_logs"
mkdir -p "$LOGDIR"
LOGFILE="$LOGDIR/create-${DATE_TAG}-${TIME_SAFE}.log"

echo "Starting snapshot script: $(date -u)" | tee -a "$LOGFILE"
echo "Mode: $MODE" | tee -a "$LOGFILE"

trim() { printf "%s" "$1" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'; }

normalize_type() {
  local t="$(echo "$1" | tr '[:upper:]' '[:lower:]')"
  case "$t" in
    inc|incr|incremental|i) echo "inc" ;;
    full|f) echo "full" ;;
    *) echo "inc" ;;  # default incremental
  esac
}

# Detect existing incremental SKU by Target tag
get_existing_incremental_sku() {
  local target="$1"
  az snapshot list \
    --query "[?tags.Target=='${target}' && incremental==\`true\`].sku.name" \
    -o tsv 2>/dev/null | head -n1 || true
}

# Wrapper to actually create snapshot
create_snapshot() {
  az snapshot create "$@" --output none
}

########################################
# DRY-RUN TABLE HEADER
########################################
if [[ "$MODE" == "--dry-run" ]]; then
  echo
  echo "📌 DRY-RUN PREVIEW (NO SNAPSHOTS WILL BE CREATED):"
  printf "\n%-15s %-20s %-6s %-8s %-10s %-8s %-40s %-30s\n" \
        "TARGET" "RESOURCE GROUP" "SCOPE" "TYPE" "RETENTION" "KIND" "SNAPSHOT NAME" "REASON"
  printf "%s\n" "-----------------------------------------------------------------------------------------------------------------------------------------------"
fi

########################################
# MAIN LOOP
########################################
while IFS= read -r RAWLINE || [[ -n "$RAWLINE" ]]; do
  LINE="$(trim "$RAWLINE")"
  [[ -z "$LINE" || "${LINE:0:1}" == "#" ]] && continue

  IFS=';' read -r F1 F2 F3 F4 F5 REST <<< "$LINE"

  TARGET="$(trim "${F1:-}")"
  RG="$(trim "${F2:-}")"
  TYPE_RAW="$(trim "${F3:-}")"
  RETENTION="$(trim "${F4:-}")"
  SCOPE_RAW="$(trim "${F5:-}")"
  REASON="$(trim "${REST:-}")"

  # Basic validation
  if [[ -z "$TARGET" || -z "$RG" || -z "$TYPE_RAW" || -z "$RETENTION" || -z "$SCOPE_RAW" ]]; then
    echo "Skipping invalid/partial line: $RAWLINE" | tee -a "$LOGFILE"
    continue
  fi

  TYPE="$(normalize_type "$TYPE_RAW")"       # inc/full
  SCOPE="$(echo "$SCOPE_RAW" | tr '[:lower:]' '[:upper:]')"   # OS/DATA/BOTH

  if ! [[ "$RETENTION" =~ ^[0-9]+$ ]]; then
    echo "Invalid RetentionDays '$RETENTION' for $TARGET. Skipping." | tee -a "$LOGFILE"
    continue
  fi

  if [[ "$SCOPE" != "OS" && "$SCOPE" != "DATA" && "$SCOPE" != "BOTH" ]]; then
    echo "Invalid SnapshotScope '$SCOPE_RAW' for $TARGET. Use OS|Data|Both. Skipping." | tee -a "$LOGFILE"
    continue
  fi

  echo "------------------------------------------------------------" | tee -a "$LOGFILE"
  echo "Entry -> Target: $TARGET  RG: $RG  Type: $TYPE  Retention: $RETENTION  Scope: $SCOPE  Reason: $REASON" | tee -a "$LOGFILE"

  ########################################
  # Resolve TARGET as VM or Disk
  ########################################
  IS_VM=false
  OS_DISK_ID=""
  DATA_DISK_IDS=""

  if az vm show -g "$RG" -n "$TARGET" >/dev/null 2>&1; then
    IS_VM=true
    OS_DISK_ID="$(az vm show -g "$RG" -n "$TARGET" --query "storageProfile.osDisk.managedDisk.id" -o tsv 2>/dev/null || true)"
    if [[ -z "$OS_DISK_ID" ]]; then
      OS_DISK_NAME="$(az vm show -g "$RG" -n "$TARGET" --query "storageProfile.osDisk.name" -o tsv 2>/dev/null || true)"
      if [[ -n "$OS_DISK_NAME" ]]; then
        OS_DISK_ID="$(az disk show -g "$RG" -n "$OS_DISK_NAME" --query "id" -o tsv 2>/dev/null || true)"
      fi
    fi
    DATA_DISK_IDS="$(az vm show -g "$RG" -n "$TARGET" --query "storageProfile.dataDisks[].managedDisk.id" -o tsv 2>/dev/null || true)"
  else
    DISK_ID="$(az disk show -g "$RG" -n "$TARGET" --query "id" -o tsv 2>/dev/null || true)"
    if [[ -n "$DISK_ID" ]]; then
      IS_VM=false
      OS_DISK_ID="$DISK_ID"
      DATA_DISK_IDS=""
      echo "Interpreting target as DISK: $TARGET (id: $OS_DISK_ID)" | tee -a "$LOGFILE"
    else
      echo "ERROR: Target '$TARGET' not found as VM or Disk in RG $RG. Skipping." | tee -a "$LOGFILE"
      continue
    fi
  fi

  if $IS_VM && [[ "$SCOPE" == "DATA" ]] && [[ -z "$DATA_DISK_IDS" ]]; then
    echo "No data disks for VM $TARGET and scope=DATA. Skipping." | tee -a "$LOGFILE"
    continue
  fi

  INC_WANTED=false
  [[ "$TYPE" == "inc" ]] && INC_WANTED=true

  EXISTING_SKU="$(get_existing_incremental_sku "$TARGET")"
  if [[ -n "$EXISTING_SKU" ]]; then
    echo "Existing incremental SKU for $TARGET: $EXISTING_SKU" | tee -a "$LOGFILE"
  fi

  TAGS=(--tags Target="$TARGET" Reason="$REASON" BackupType="$TYPE" Date="$DATE_TAG" Time="$TIME_TAG" AutomatedBackup="true" RetentionDays="$RETENTION")

  ########################################
  # Helper to do snapshot (or print only)
  ########################################
  do_disk_snapshot() {
    local disk_id="$1"
    local snap_name="$2"
    local kind="$3"   # OS/DATA/DISK

    if [[ "$MODE" == "--dry-run" ]]; then
      printf "%-15s %-20s %-6s %-8s %-10s %-8s %-40s %-30s\n" \
        "$TARGET" "$RG" "$SCOPE" "$TYPE" "$RETENTION" "$kind" "$snap_name" "$REASON"
      return
    fi

    echo "Creating $kind snapshot: $snap_name from disk: $disk_id" | tee -a "$LOGFILE"

    set +e
    if $INC_WANTED; then
      if [[ -n "$EXISTING_SKU" ]]; then
        create_snapshot -g "$RG" -n "$snap_name" --source "$disk_id" --incremental true --sku "$EXISTING_SKU" "${TAGS[@]}"
      else
        create_snapshot -g "$RG" -n "$snap_name" --source "$disk_id" --incremental true "${TAGS[@]}"
      fi
      rc=$?
      if [[ $rc -ne 0 ]]; then
        echo "Incremental failed for $snap_name; creating FULL instead." | tee -a "$LOGFILE"
        create_snapshot -g "$RG" -n "$snap_name" --source "$disk_id" "${TAGS[@]}"
      fi
    else
      create_snapshot -g "$RG" -n "$snap_name" --source "$disk_id" "${TAGS[@]}"
    fi
    set -e
  }

  ########################################
  # Create snapshots per SCOPE / target type
  ########################################
  if $IS_VM; then
    # OS snapshot
    if [[ "$SCOPE" == "OS" || "$SCOPE" == "BOTH" ]]; then
      if [[ -z "$OS_DISK_ID" ]]; then
        echo "ERROR: OS disk id not found for VM $TARGET. Skipping OS snapshot." | tee -a "$LOGFILE"
      else
        SNAP_OS="${TARGET}-${DATE_TAG}-${TIME_SAFE}-automated-backup"
        do_disk_snapshot "$OS_DISK_ID" "$SNAP_OS" "OS"
      fi
    fi

    # Data snapshots
    if [[ "$SCOPE" == "DATA" || "$SCOPE" == "BOTH" ]]; then
      idx=1
      while IFS= read -r DID; do
        [[ -z "${DID//[[:space:]]/}" ]] && continue
        SNAP_DATA="${TARGET}-${DATE_TAG}-${TIME_SAFE}-automated-backup-data-${idx}"
        do_disk_snapshot "$DID" "$SNAP_DATA" "DATA"
        idx=$((idx+1))
      done <<< "$DATA_DISK_IDS"
    fi
  else
    # Target was a disk
    SNAP_DISK="${TARGET}-${DATE_TAG}-${TIME_SAFE}-automated-backup"
    do_disk_snapshot "$OS_DISK_ID" "$SNAP_DISK" "DISK"
  fi

done < "$SERVERLIST"

echo -e "\n✔ DONE — Mode: $MODE" | tee -a "$LOGFILE"
