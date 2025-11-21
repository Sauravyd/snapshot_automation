#!/usr/bin/env bash
# snapshot_automated.sh
# Reads retention from serverlist.txt, supports OS/Data/Both,
# supports incremental/full, detects SKU for incremental creation
# and falls back to full if SKU mismatch occurs.

set -euo pipefail

if [[ "${1:-}" == "" ]]; then
  echo "Usage: $0 <serverlist-file>"
  exit 1
fi

SERVERLIST="$1"

command -v az >/dev/null 2>&1 || { echo "ERROR: az CLI not found."; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "ERROR: python3 not found."; exit 3; }

DATE_TAG="$(date +%d-%m-%Y)"
TIME_TAG="$(date +%H:%M)"       # For display
TIME_SAFE="${TIME_TAG//:/-}"    # Safe for Azure resource names

LOGDIR="./snapshot_logs"
mkdir -p "$LOGDIR"
LOGFILE="$LOGDIR/create-${DATE_TAG}-${TIME_SAFE}.log"

echo "Starting snapshot creation: $(date -u)" | tee -a "$LOGFILE"

tolower() { printf "%s" "$1" | awk '{print tolower($0)}'; }

# Detect existing incremental SKU for this VM
get_existing_incremental_sku() {
    local vm="$1"
    az snapshot list \
        --query "[?tags.VM=='${vm}' && incremental==\`true\`].sku.name" \
        -o tsv 2>/dev/null | head -n1 || true
}

# Try snapshot creation safely
create_snapshot() {
    az snapshot create "$@" --output none
}

# ------------------------- MAIN LOOP -------------------------

while IFS= read -r LINE || [[ -n "$LINE" ]]; do

  [[ -z "${LINE//[[:space:]]/}" ]] && continue
  [[ "${LINE:0:1}" == "#" ]] && continue

  VM="$(echo "$LINE" | awk -F';' '{print $1}' | xargs)"
  RG="$(echo "$LINE" | awk -F';' '{print $2}' | xargs)"
  TYPE_RAW="$(echo "$LINE" | awk -F';' '{print $3}' | xargs)"
  RETENTION="$(echo "$LINE" | awk -F';' '{print $4}' | xargs)"
  SCOPE="$(echo "$LINE" | awk -F';' '{print $5}' | xargs)"
  REASON="$(echo "$LINE" | awk -F';' '{print $6}' | xargs)"

  TYPE="$(tolower "$TYPE_RAW")"
  [[ "$TYPE" == "incremental" ]] && TYPE="inc"
  [[ "$TYPE" == "full" ]] && TYPE="full"

  if [[ ! "$RETENTION" =~ ^[0-9]+$ ]]; then
    echo "Invalid retention for $VM, skipping." | tee -a "$LOGFILE"
    continue
  fi

  echo "------------------------------------------------------------" | tee -a "$LOGFILE"
  echo "VM: $VM  RG: $RG  Type: $TYPE  Retention: $RETENTION days  Scope: $SCOPE" | tee -a "$LOGFILE"

  # Fetch OS + data disks
  OS_DISK_ID="$(az vm show -g "$RG" -n "$VM" --query "storageProfile.osDisk.managedDisk.id" -o tsv)"
  DATA_DISK_IDS="$(az vm show -g "$RG" -n "$VM" --query "storageProfile.dataDisks[].managedDisk.id" -o tsv)"

  # Determine incremental flag
  INC_WANTED=false
  if [[ "$TYPE" == "inc" ]]; then INC_WANTED=true; fi

  # Detect existing SKU for incremental snapshots
  EXISTING_SKU="$(get_existing_incremental_sku "$VM")"
  if [[ -n "$EXISTING_SKU" ]]; then
    echo "Existing incremental SKU for $VM: $EXISTING_SKU" | tee -a "$LOGFILE"
  fi

  # ---- Common tags ----
  TAGS=(--tags VM="$VM" Reason="$REASON" BackupType="$TYPE" Date="$DATE_TAG" Time="$TIME_TAG" \
               AutomatedBackup="true" RetentionDays="$RETENTION")

  # ======================================================
  # ==============      OS SNAPSHOT        ===============
  # ======================================================
  if [[ "$SCOPE" == "OS" || "$SCOPE" == "Both" ]]; then
    SNAP_OS="${VM}-${DATE_TAG}-${TIME_SAFE}-automated-backup"
    echo "Creating OS snapshot: $SNAP_OS" | tee -a "$LOGFILE"

    set +e
    if $INC_WANTED; then
        if [[ -n "$EXISTING_SKU" ]]; then
            # Try incremental with SKU
            create_snapshot -g "$RG" -n "$SNAP_OS" --source "$OS_DISK_ID" \
                --incremental true --sku "$EXISTING_SKU" "${TAGS[@]}"
        else
            # Try incremental normally
            create_snapshot -g "$RG" -n "$SNAP_OS" --source "$OS_DISK_ID" \
                --incremental true "${TAGS[@]}"
        fi
        rc=$?
        if [[ $rc -ne 0 ]]; then
            echo "Incremental failed (SKU mismatch or other). Falling back to FULL." | tee -a "$LOGFILE"
            create_snapshot -g "$RG" -n "$SNAP_OS" --source "$OS_DISK_ID" "${TAGS[@]}"
        fi
    else
        create_snapshot -g "$RG" -n "$SNAP_OS" --source "$OS_DISK_ID" "${TAGS[@]}"
    fi
    set -e
  fi

  # ======================================================
  # ==============     DATA SNAPSHOTS      ===============
  # ======================================================
  if [[ "$SCOPE" == "Data" || "$SCOPE" == "Both" ]]; then
    idx=1
    while IFS= read -r DID; do
      [[ -z "${DID//[[:space:]]/}" ]] && continue

      SNAP_DATA="${VM}-${DATE_TAG}-${TIME_SAFE}-automated-backup-data-${idx}"
      echo "Creating DATA snapshot: $SNAP_DATA" | tee -a "$LOGFILE"

      set +e
      if $INC_WANTED; then
        if [[ -n "$EXISTING_SKU" ]]; then
          create_snapshot -g "$RG" -n "$SNAP_DATA" --source "$DID" \
              --incremental true --sku "$EXISTING_SKU" "${TAGS[@]}"
        else
          create_snapshot -g "$RG" -n "$SNAP_DATA" --source "$DID" \
              --incremental true "${TAGS[@]}"
        fi
        rc=$?
        if [[ $rc -ne 0 ]]; then
          echo "Incremental failed for data disk, falling back to FULL." | tee -a "$LOGFILE"
          create_snapshot -g "$RG" -n "$SNAP_DATA" --source "$DID" "${TAGS[@]}"
        fi
      else
        create_snapshot -g "$RG" -n "$SNAP_DATA" --source "$DID" "${TAGS[@]}"
      fi
      set -e

      idx=$((idx+1))
    done <<< "$DATA_DISK_IDS"
  fi

done < "$SERVERLIST"

echo "Snapshot creation completed." | tee -a "$LOGFILE"
