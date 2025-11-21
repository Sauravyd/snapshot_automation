#!/usr/bin/env bash
# snapshot_automated.sh
# Robust parsing: tolerates missing spaces; accepts synonyms for snapshot type;
# accepts either VM name (creates OS/data snapshots) or disk name (creates snapshot of that disk).
# Preserves incremental SKU reuse and fallback-to-full behavior.

set -euo pipefail

if [[ "${1:-}" == "" ]]; then
  echo "Usage: $0 <serverlist-file>"
  exit 1
fi
SERVERLIST="$1"

command -v az >/dev/null 2>&1 || { echo "ERROR: az CLI not found."; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "ERROR: python3 not found."; exit 3; }

DATE_TAG="$(date +%d-%m-%Y)"
TIME_TAG="$(date +%H:%M)"
TIME_SAFE="${TIME_TAG//:/-}"

LOGDIR="./snapshot_logs"
mkdir -p "$LOGDIR"
LOGFILE="$LOGDIR/create-${DATE_TAG}-${TIME_SAFE}.log"

echo "Starting snapshot creation: $(date -u)" | tee -a "$LOGFILE"

# trim helper
trim() { printf "%s" "$1" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'; }

# normalize snapshot type synonyms -> "inc" or "full"
normalize_type() {
  local t="$(printf "%s" "$1" | tr '[:upper:]' '[:lower:]')"
  case "$t" in
    inc|incr|incremental|i) echo "inc" ;;
    full|f) echo "full" ;;
    *) echo "inc" ;;  # default incremental
  esac
}

# Detect existing incremental SKU for this VM (by VM tag)
get_existing_incremental_sku() {
    local vm="$1"
    az snapshot list --query "[?tags.VM=='${vm}' && incremental==\`true\`].sku.name" -o tsv 2>/dev/null | head -n1 || true
}

# wrapper to call az snapshot create
create_snapshot() {
    az snapshot create "$@" --output none
}

# Read file line-by-line, allow both forms, robust splitting
while IFS= read -r RAWLINE || [[ -n "$RAWLINE" ]]; do
  # skip empty/comment
  LINE="$(trim "$RAWLINE")"
  [[ -z "$LINE" ]] && continue
  [[ "${LINE:0:1}" == "#" ]] && continue

  # split on semicolon into up to 6 fields; allow extra semicolons in reason
  IFS=';' read -r F1 F2 F3 F4 F5 REST <<< "$LINE"

  VM_OR_DISK="$(trim "${F1:-}")"
  RG="$(trim "${F2:-}")"
  TYPE_RAW="$(trim "${F3:-}")"
  RETENTION="$(trim "${F4:-}")"
  SCOPE_RAW="$(trim "${F5:-}")"
  REASON="$(trim "${REST:-}")"

  # minimal validation
  if [[ -z "$VM_OR_DISK" || -z "$RG" || -z "$TYPE_RAW" || -z "$RETENTION" || -z "$SCOPE_RAW" ]]; then
    echo "Skipping invalid/partial line: $RAWLINE" | tee -a "$LOGFILE"
    continue
  fi

  # normalize fields
  TYPE="$(normalize_type "$TYPE_RAW")"
  SCOPE="$(printf "%s" "$SCOPE_RAW" | awk '{print toupper($0)}')"  # OS, DATA, BOTH expected
  if [[ "$SCOPE" != "OS" && "$SCOPE" != "DATA" && "$SCOPE" != "BOTH" ]]; then
    echo "Invalid SnapshotScope '$SCOPE_RAW' for $VM_OR_DISK. Use OS|Data|Both. Skipping." | tee -a "$LOGFILE"
    continue
  fi

  if ! [[ "$RETENTION" =~ ^[0-9]+$ ]]; then
    echo "Invalid RetentionDays '$RETENTION' for $VM_OR_DISK. Must be numeric. Skipping." | tee -a "$LOGFILE"
    continue
  fi

  echo "------------------------------------------------------------" | tee -a "$LOGFILE"
  echo "Entry -> Target: $VM_OR_DISK   RG: $RG   Type: $TYPE   Retention: $RETENTION   Scope: $SCOPE   Reason: $REASON" | tee -a "$LOGFILE"

  # Determine whether first field is a VM or a Disk
  IS_VM=false
  OS_DISK_ID=""
  DATA_DISK_IDS=""

  # try vm show (quiet), if found treat as VM
  if az vm show -g "$RG" -n "$VM_OR_DISK" >/dev/null 2>&1; then
    IS_VM=true
    # fetch disk ids (work even if VM deallocated by querying disk name then disk)
    OS_DISK_ID="$(az vm show -g "$RG" -n "$VM_OR_DISK" --query "storageProfile.osDisk.managedDisk.id" -o tsv 2>/dev/null || true)"
    # fallback: if empty, retrieve disk name then disk id
    if [[ -z "$OS_DISK_ID" ]]; then
      OS_DISK_NAME="$(az vm show -g "$RG" -n "$VM_OR_DISK" --query "storageProfile.osDisk.name" -o tsv 2>/dev/null || true)"
      if [[ -n "$OS_DISK_NAME" ]]; then
        OS_DISK_ID="$(az disk show -g "$RG" -n "$OS_DISK_NAME" --query "id" -o tsv 2>/dev/null || true)"
      fi
    fi
    DATA_DISK_IDS="$(az vm show -g "$RG" -n "$VM_OR_DISK" --query "storageProfile.dataDisks[].managedDisk.id" -o tsv 2>/dev/null || true)"
  else
    # Not a VM: try to interpret as a disk name in the RG
    DISK_ID="$(az disk show -g "$RG" -n "$VM_OR_DISK" --query "id" -o tsv 2>/dev/null || true)"
    if [[ -n "$DISK_ID" ]]; then
      IS_VM=false
      OS_DISK_ID="$DISK_ID"   # treat as single disk (snapshot the disk itself)
      DATA_DISK_IDS=""
      echo "Interpreting target as disk: $VM_OR_DISK (id: $OS_DISK_ID)" | tee -a "$LOGFILE"
    else
      echo "ERROR: Target '$VM_OR_DISK' not found as VM or Disk in RG $RG. Skipping." | tee -a "$LOGFILE"
      continue
    fi
  fi

  # For VM-case: if SCOPE=DATA and no data disks, skip
  if $IS_VM && [[ "$SCOPE" == "DATA" ]] && [[ -z "$DATA_DISK_IDS" ]]; then
    echo "No data disks for VM $VM_OR_DISK and scope=DATA. Skipping." | tee -a "$LOGFILE"
    continue
  fi

  # For disk-case: we always snapshot the disk (ignore SCOPE and TYPE mapping uses TYPE for incremental/full)
  # Decide incremental wanted
  INC_WANTED=false
  if [[ "$TYPE" == "inc" ]]; then INC_WANTED=true; fi

  # detect existing incremental SKU if VM target; if disk only, try find existing incremental snapshots by tag VM==disk name too
  EXISTING_SKU="$(get_existing_incremental_sku "$VM_OR_DISK")"
  if [[ -n "$EXISTING_SKU" ]]; then
    echo "Existing incremental SKU for target $VM_OR_DISK: $EXISTING_SKU" | tee -a "$LOGFILE"
  fi

  # common tags (VM tag if VM case else DiskName)
  TARGET_TAG_VALUE="$VM_OR_DISK"
  TAGS=(--tags Target="$TARGET_TAG_VALUE" Reason="$REASON" BackupType="$TYPE" Date="$DATE_TAG" Time="$TIME_TAG" AutomatedBackup="true" RetentionDays="$RETENTION")

  # Function to attempt snapshot of a single disk ID with incremental handling
  do_disk_snapshot() {
    local disk_id="$1"
    local snap_name="$2"

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

  # Create snapshots depending on whether target is VM or disk and the scope
  if $IS_VM; then
    # OS snapshot
    if [[ "$SCOPE" == "OS" || "$SCOPE" == "BOTH" ]]; then
      if [[ -z "$OS_DISK_ID" ]]; then
        echo "ERROR: OS disk id not found for VM $VM_OR_DISK. Skipping OS snapshot." | tee -a "$LOGFILE"
      else
        SNAP_OS="${VM_OR_DISK}-${DATE_TAG}-${TIME_SAFE}-automated-backup"
        echo "Creating OS snapshot: $SNAP_OS" | tee -a "$LOGFILE"
        do_disk_snapshot "$OS_DISK_ID" "$SNAP_OS"
      fi
    fi

    # Data snapshots
    if [[ "$SCOPE" == "DATA" || "$SCOPE" == "BOTH" ]]; then
      idx=1
      while IFS= read -r DID; do
        [[ -z "${DID//[[:space:]]/}" ]] && continue
        SNAP_DATA="${VM_OR_DISK}-${DATE_TAG}-${TIME_SAFE}-automated-backup-data-${idx}"
        echo "Creating DATA snapshot: $SNAP_DATA" | tee -a "$LOGFILE"
        do_disk_snapshot "$DID" "$SNAP_DATA"
        idx=$((idx+1))
      done <<< "$DATA_DISK_IDS"
    fi

  else
    # target was a disk name (single-disk snapshot). SCOPE is ignored.
    SNAP_DISK="${VM_OR_DISK}-${DATE_TAG}-${TIME_SAFE}-automated-backup"
    echo "Creating DISK snapshot: $SNAP_DISK" | tee -a "$LOGFILE"
    do_disk_snapshot "$OS_DISK_ID" "$SNAP_DISK"
  fi

done < "$SERVERLIST"

echo "Snapshot creation completed." | tee -a "$LOGFILE"
