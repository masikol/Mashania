#!/bin/bash
# Store the full command used to run the script
FULL_COMMAND=$(printf "%q " "$0" "$@")

# Determine absolute path to script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Enable strict error handling
set -euo pipefail

# ============================================
# Script metadata
# ============================================
SCRIPT_VERSION_DATE="2026-06-12"

# ============================================
# Paths to software and databases
# ============================================
Path_ncbi_datasets=""
# Example: Path_ncbi_datasets="/media/cager-lab/EVO/soft/ncbi-datasets-cli/"
# https://ftp.ncbi.nlm.nih.gov/pub/datasets/command-line/LATEST/linux-amd64/datasets
# https://ftp.ncbi.nlm.nih.gov/pub/datasets/command-line/LATEST/linux-amd64/dataformat

Path_mash=""
# Example: Path_mash="/media/cager-lab/EVO/soft/mash-Linux64-v2.3/"
# https://github.com/marbl/Mash/releases

# ============================================
# Check executable file and auto-fix permissions if needed
# ============================================
check_executable() {
    local full_path="$1"

    if [ -f "$full_path" ]; then
        if [ ! -x "$full_path" ]; then
            echo "WARNING: $(basename "$full_path") found but not executable, trying chmod +x..." >&2
            if chmod +x "$full_path" 2>/dev/null; then
                echo "Fixed: $(basename "$full_path") is now executable" >&2
            else
                echo "ERROR: cannot make $(basename "$full_path") executable (run manually: chmod +x $full_path)" >&2
                return 1
            fi
        fi
        return 0
    fi

    return 1
}

# ============================================
# Function to resolve a tool location
# ============================================
resolve_dir_or_empty() {
    local name="$1"
    local path="$2"
    local full_path

    # 1. Explicitly provided directory
    if [ -n "$path" ]; then
        full_path="${path%/}/$name"
        if check_executable "$full_path"; then
            echo "${path%/}/"
            return 0
        fi
    fi

    # 2. PATH
    if command -v "$name" >/dev/null 2>&1; then
        echo ""
        return 0
    fi

    # 3. Script directory
    full_path="$SCRIPT_DIR/$name"
    if check_executable "$full_path"; then
        echo "$SCRIPT_DIR/"
        return 0
    fi

    # Error
    if [ -n "$path" ]; then
        echo "ERROR: $name not found in PATH, script directory, or at ${path%/}/$name" >&2
    else
        echo "ERROR: $name not found in PATH or script directory" >&2
    fi

    case "$name" in
        mash)
            echo "Download Mash: https://github.com/marbl/Mash/releases" >&2
            echo "Extract the archive and either add 'mash' executable to PATH or set Path_mash in this script." >&2
            echo "Example: Path_mash=\"/opt/mash/\"" >&2
            echo "See line 19" >&2
            ;;
        datasets|dataformat)
            echo "Download NCBI Datasets CLI: https://www.ncbi.nlm.nih.gov/datasets/docs/v2/download-and-install/" >&2
            echo "Add 'datasets AND dataformat' executable to PATH or set Path_ncbi_datasets in this script." >&2
            echo "Example: Path_ncbi_datasets=\"/opt/ncbi-datasets/\"" >&2
            echo "See line 14" >&2
            ;;
    esac

    return 1
}

# ============================================
# Command-line argument parsing
# ============================================
show_help() {
cat << EOF
------------------------------------------------------------------------
Script for building a MASH database using NCBI RefSeq species-level reference assemblies.
Supports incremental updates and full rebuilds when taxonomy changes.
------------------------------------------------------------------------
Usage:
  $0 [options]

Options:
  -o, --workdir      Working directory (default: script directory)
  -d, --domain       Taxonomic domain to include: bacteria, archaea, both (default: bacteria)
  -h, --help         Show this help message and exit

Example:
  $0 -o results
  $0 -o results -t archaea
  $0 -o results -t bothh
EOF
}

# Quick help check
for arg in "$@"; do
    case "$arg" in
        -h|--help)
            show_help
            exit 0
            ;;
    esac
done

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --workdir|-o)
            [[ $# -lt 2 ]] && { echo "ERROR: missing argument for $1" >&2; exit 1; }
            WORKDIR="$2"
            shift 2
            ;;
        --domain|-d)
            [[ $# -lt 2 ]] && { echo "ERROR: missing argument for $1" >&2; exit 1; }
            DOMAIN="$2"
            shift 2
            ;;
        *)
            echo "Unknown parameter: $1" >&2
            echo "Usage: $0 --workdir <dir> --number <value>" >&2
            exit 1
            ;;
    esac
done

# ============================================
# Default values
# ============================================
DOMAIN=${DOMAIN:-bacteria}

case "$DOMAIN" in
    bacteria|archaea|both) ;;
    *)
        echo "ERROR: invalid --domain value '$DOMAIN'. Must be: bacteria, archaea, or both" >&2
        exit 1
        ;;
esac

if [[ -z "${WORKDIR:-}" ]]; then
    WORKDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/RefSeqSketches"
fi

# Timestamp for this run
RUN_TIMESTAMP=$(date '+%Y-%m-%d_%H-%M')

# Subdirectory for individual genome sketches
SKETCHES_DIR="$WORKDIR/sketches"

# Final database file — named with run timestamp
MSH_DB="$WORKDIR/RefSeqSketches_${RUN_TIMESTAMP}.msh"

# IDs file for this run
IDS_FILE="$WORKDIR/ids_${RUN_TIMESTAMP}.txt"

# Create working directories
mkdir -p "$WORKDIR"
mkdir -p "$SKETCHES_DIR"

# ============================================
# Validate required tools
# ============================================
command -v unzip >/dev/null || {
    echo "ERROR: unzip is required (install with: sudo apt install unzip)" >&2
    exit 1
}

Path_mash=$(resolve_dir_or_empty mash "$Path_mash") || exit 1
Path_ncbi_datasets=$(resolve_dir_or_empty datasets "$Path_ncbi_datasets") || exit 1
resolve_dir_or_empty dataformat "$Path_ncbi_datasets" >/dev/null || exit 1

# ============================================
# Logging
# ============================================
LOG_FILE="$WORKDIR/run.log"
ERROR_LOG="$WORKDIR/error.log"

# Archive existing logs with their modification dates
if [[ -f "$LOG_FILE" ]]; then
    log_mtime=$(date -r "$LOG_FILE" '+%Y-%m-%d_%H-%M')
    mv "$LOG_FILE" "$WORKDIR/run_${log_mtime}.log"
fi

if [[ -f "$ERROR_LOG" ]]; then
    err_mtime=$(date -r "$ERROR_LOG" '+%Y-%m-%d_%H-%M')
    mv "$ERROR_LOG" "$WORKDIR/error_${err_mtime}.log"
fi

echo "=========================================" > "$LOG_FILE"
{
echo "Command: $FULL_COMMAND"
echo "Start time: $(date '+%Y-%m-%d %H:%M:%S')"
echo "========================================="
} >> "$LOG_FILE"

exec > >(tee -a "$LOG_FILE") 2>&1

echo "========================================="
echo " RefSeq-to-MASH database builder"
echo " Script date: $SCRIPT_VERSION_DATE"
echo "-----------------------------------------"
echo " This script downloads species-level reference"
echo " genome assemblies from NCBI RefSeq and builds"
echo " a MASH sketch database for rapid species"
echo " identification."
echo ""
echo " Supported modes:"
echo "   new         — first run, build from scratch"
echo "   incremental — add newly appeared genomes"
echo "   rebuild     — full rebuild on taxonomy changes"
echo "========================================="
echo ""

# Resolve actual binary paths for logging
if command -v mash >/dev/null 2>&1; then
    MASH_BIN="$(command -v mash)"
else
    MASH_BIN="${Path_mash%/}/mash"
fi

if command -v datasets >/dev/null 2>&1; then
    DATASETS_BIN="$(command -v datasets)"
else
    DATASETS_BIN="${Path_ncbi_datasets%/}/datasets"
fi

if command -v dataformat >/dev/null 2>&1; then
    DATAFORMAT_BIN="$(command -v dataformat)"
else
    DATAFORMAT_BIN="${Path_ncbi_datasets%/}/dataformat"
fi

echo "SYSTEM:"
echo "   Mash:       $MASH_BIN ($($MASH_BIN --version 2>/dev/null | head -n1 || echo 'version unknown'))"
echo "   datasets:   $DATASETS_BIN ($($DATASETS_BIN version 2>/dev/null | head -n1 || echo 'version unknown'))"
dataformat_version=$("$DATAFORMAT_BIN" version 2>/dev/null | head -n1)
if [[ -z "$dataformat_version" ]] || [[ "$dataformat_version" == "undefined" ]]; then
    dataformat_version="version unavailable (known dataformat bug)"
fi
echo "   dataformat: $DATAFORMAT_BIN ($dataformat_version)"
echo "   domain:     $DOMAIN"
echo "   workdir:    $WORKDIR"
echo "   sketches:   $SKETCHES_DIR"
echo "   database:   $MSH_DB"

# Store script start time for elapsed time logging
START_TIME=$(date +%s)

log_step() {
    local msg="$1"
    local now
    now=$(date +%s)
    local elapsed=$(( now - START_TIME ))
    printf "%02d:%02d:%02d - %s\n" \
        $(( elapsed/3600 )) $(( elapsed%3600/60 )) $(( elapsed%60 )) \
        "$msg"
}

# ============================================
# Download function with retries
# ============================================
download_dehydrated_with_retry() {
    local id="$1"
    local max_attempts=5
    local attempt=1

    local zip_file="$WORKDIR/ncbi_dataset_${id}.zip"
    local dataset_dir="$WORKDIR/ncbi_dataset_${id}"

    while (( attempt <= max_attempts )); do
        echo "Downloading (dehydrated) $id (attempt $attempt/$max_attempts)"

        rm -rf "$dataset_dir"
        rm -f "$zip_file"

        if "$DATASETS_BIN" download genome accession "$id" \
            --no-progressbar --dehydrated --filename "$zip_file"; then

            if [[ ! -s "$zip_file" ]]; then
                echo "ERROR: empty zip file for $id, retrying..." >> "$ERROR_LOG"
                attempt=$(( attempt + 1 ))
                sleep 5
                continue
            fi

            if ! unzip -t "$zip_file" >/dev/null 2>&1; then
                echo "ERROR: corrupted zip detected for $id, retrying..." >> "$ERROR_LOG"
                attempt=$(( attempt + 1 ))
                sleep 5
                continue
            fi

            # Success
            return 0

        else
            echo "ERROR: download failed for $id, retrying..." >> "$ERROR_LOG"
        fi

        attempt=$(( attempt + 1 ))
        sleep 5
    done

    echo "ERROR: failed to download valid zip for $id after $max_attempts attempts" >> "$ERROR_LOG"
    return 1
}

# ============================================
# Process a single genome: download, rehydrate, sketch
# Returns 0 on success, 1 on failure
# On success, creates: $SKETCHES_DIR/${organism}_${id}.msh
# ============================================
process_genome() {
    local id="$1"
    local organism="$2"

    local zip_file="$WORKDIR/ncbi_dataset_${id}.zip"
    local dataset_dir="$WORKDIR/ncbi_dataset_${id}"
    local sketch_out="$SKETCHES_DIR/${organism}_${id}"

    if ! download_dehydrated_with_retry "$id"; then
        echo "Skipping $id (download failed)" >> "$ERROR_LOG"
        return 1
    fi

    unzip -o -q -d "$dataset_dir" "$zip_file"

    if ! "$DATASETS_BIN" rehydrate \
        --no-progressbar --directory "$dataset_dir"; then
        echo "ERROR: rehydrate failed for $id" >> "$ERROR_LOG"
        rm -rf "$dataset_dir" "$zip_file"
        return 1
    fi

    local fasta_file
    fasta_file=$(find "$dataset_dir" -type f -name "*_genomic.fna" 2>/dev/null | head -n 1)

    if [[ -z "$fasta_file" ]]; then
        echo "ERROR: fasta not found for $id, skipping" >> "$ERROR_LOG"
        rm -rf "$dataset_dir" "$zip_file"
        return 1
    fi

    if [[ ! -s "$fasta_file" ]]; then
        echo "ERROR: empty fasta for $id, skipping" >> "$ERROR_LOG"
        rm -rf "$dataset_dir" "$zip_file"
        return 1
    fi

    "$MASH_BIN" sketch "$fasta_file" -o "$sketch_out" -I "${organism}_${id}"

    if [[ ! -f "${sketch_out}.msh" ]]; then
        echo "ERROR: mash sketch failed for $id" >> "$ERROR_LOG"
        rm -rf "$dataset_dir" "$zip_file"
        return 1
    fi

    rm -rf "$dataset_dir" "$zip_file"
    rm -f "$WORKDIR/README.md" "$WORKDIR/md5sum.txt"

    return 0
}

# ============================================
# Get a fresh genome list from NCBI
# ============================================
echo ""
log_step "Retrieving RefSeq reference genome list from NCBI"
echo "-----------------------------------------------------------"

fetch_success=false
for fetch_attempt in 1 2 3 4 5; do
    if [[ "$DOMAIN" == "both" ]]; then
        {
            "$DATASETS_BIN" summary genome taxon bacteria --reference --as-json-lines
            "$DATASETS_BIN" summary genome taxon archaea  --reference --as-json-lines
        } | \
            "$DATAFORMAT_BIN" tsv genome --fields accession,organism-name --elide-header | \
            sed 's/\[//g' | \
            sed 's/\]//g' | \
            sed 's/["'"'"']//g' > \
            "$IDS_FILE" && fetch_success=true && break
    else
        "$DATASETS_BIN" summary genome taxon "$DOMAIN" --reference --as-json-lines | \
            "$DATAFORMAT_BIN" tsv genome --fields accession,organism-name --elide-header | \
            sed 's/\[//g' | \
            sed 's/\]//g' | \
            sed 's/["'"'"']//g' > \
            "$IDS_FILE" && fetch_success=true && break
    fi

    log_step "NCBI fetch attempt $fetch_attempt failed, retrying in 3 seconds..."
    echo "WARNING: NCBI fetch attempt $fetch_attempt failed" >> "$ERROR_LOG"
    sleep 3
done

if [[ "$fetch_success" == false ]]; then
    log_step "ERROR: failed to fetch genome list from NCBI after 5 attempts"
    echo "ERROR: failed to fetch genome list from NCBI after 5 attempts" >> "$ERROR_LOG"
    exit 1
fi

if [[ ! -s "$IDS_FILE" ]]; then
    echo "ERROR: ids file is empty or not created: $IDS_FILE" >> "$ERROR_LOG"
    exit 1
fi

line_count=$(awk 'NF{c++}END{print c}' "$IDS_FILE")
log_step "Retrieved $line_count genomes from NCBI"
log_step "Analyzing changes vs previous run..."

# ============================================
# Determine run mode: new / incremental / full rebuild
# ============================================

# Find the most recent _processed.txt file in WORKDIR
PREV_PROCESSED=$(find "$WORKDIR" -maxdepth 1 -name "ids_*_processed.txt" | sort | tail -n 1 || true)

# New processed file for this run (written at the end)
NEW_PROCESSED="$WORKDIR/ids_${RUN_TIMESTAMP}_processed.txt"

PREV_MSH=$(find "$WORKDIR" -maxdepth 1 -name "RefSeqSketches_*.msh" | \
    grep -v '_tmp' | sort | tail -n 1 || true)

RUN_MODE=""

# Extract timestamps from previous processed and previous MSH to check they match
if [[ -n "$PREV_PROCESSED" ]] && [[ -n "$PREV_MSH" ]]; then
    ts_processed=$(basename "$PREV_PROCESSED" | sed 's/ids_\(.*\)_processed\.txt/\1/')
    ts_msh=$(basename "$PREV_MSH" | sed 's/RefSeqSketches_\(.*\)\.msh/\1/')
    if [[ "$ts_processed" != "$ts_msh" ]]; then
        log_step "WARNING: latest processed file ($ts_processed) and latest database ($ts_msh) have different timestamps"
        log_step "Mode: NEW — mismatched previous files, building from scratch"
        RUN_MODE="new"
    fi
fi

if [[ -z "$PREV_PROCESSED" ]] || [[ -z "$PREV_MSH" ]] || [[ "$RUN_MODE" == "new" ]]; then
    # ----------------------------------------
    # SCENARIO A: no previous run found or mismatched files
    # ----------------------------------------
    RUN_MODE="new"
    log_step "Mode: NEW — no previous database found, building from scratch"
    echo "-----------------------------------------------------------"

else
    # Compare new ids with previous processed list
    # Look for:
    #   - GCF present in both but organism name changed  → rebuild
    #   - GCF present in both but accession version changed (e.g. .1 → .2) → rebuild
    #   - GCF only in new list → add
    #   - GCF only in old list → remove sketch

    # Build associative arrays
    declare -A prev_map   # id -> organism  (from previous processed)
    declare -A new_map    # id -> organism  (from new ids file)

    while IFS=$'\t' read -r id organism; do
        [[ -z "$id" ]] && continue
        prev_map["$id"]="$organism"
    done < "$PREV_PROCESSED"

    while IFS=$'\t' read -r local_id local_org_raw; do
        [[ -z "$local_id" ]] && continue
        local_org="${local_org_raw// /_}"
        local_org="${local_org//[^[:alnum:]_.-]/}"
        local_org=${local_org:-unknown}
        new_map["$local_id"]="$local_org"
    done < "$IDS_FILE"

    REBUILD_NEEDED=false

    # Check: any existing GCF changed its organism name?
    for id in "${!prev_map[@]}"; do
        if [[ -v new_map["$id"] ]]; then
            if [[ "${prev_map[$id]}" != "${new_map[$id]}" ]]; then
                log_step "At least one change detected — $id: '${prev_map[$id]}' → '${new_map[$id]}' (further changes may exist)"
                REBUILD_NEEDED=true
                break
            fi
        fi
    done

    # Check: any accession version changed?
    if [[ "$REBUILD_NEEDED" == false ]]; then
        declare -A prev_versions  # base_id -> full_id
        declare -A new_versions

        for id in "${!prev_map[@]}"; do
            base_id="${id%.*}"
            prev_versions["$base_id"]="$id"
        done

        for id in "${!new_map[@]}"; do
            base_id="${id%.*}"
            new_versions["$base_id"]="$id"
        done

        for base_id in "${!prev_versions[@]}"; do
            if [[ -v new_versions["$base_id"] ]]; then
                if [[ "${prev_versions[$base_id]}" != "${new_versions[$base_id]}" ]]; then
                    log_step "At least one change detected — $base_id: '${prev_versions[$base_id]}' → '${new_versions[$base_id]}' (further changes may exist)"
                    REBUILD_NEEDED=true
                    break
                fi
            fi
        done

        unset prev_versions new_versions
    fi

    if [[ "$REBUILD_NEEDED" == true ]]; then
        # ----------------------------------------
        # SCENARIO C: taxonomy or version changed
        # ----------------------------------------
        RUN_MODE="rebuild"
        log_step "Mode:  REBUILD — taxonomy or accession version changes detected"
    else
        # ----------------------------------------
        # SCENARIO B: only new genomes added
        # ----------------------------------------
        RUN_MODE="incremental"
        log_step "Mode: INCREMENTAL — only new genomes to add"
    fi

    unset prev_map new_map
fi

# ============================================
# SCENARIO A — build from scratch
# ============================================
if [[ "$RUN_MODE" == "new" ]]; then

    line_current=1

    while IFS=$'\t' read -r id organism_raw; do
        [[ -z "$id" ]] && continue
        organism="${organism_raw// /_}"
        organism="${organism//[^[:alnum:]_.-]/}"
        organism=${organism:-unknown}

        echo ""
        echo "---------------------------------------"
        echo "[$line_current/$line_count] Processing: $id ($organism)"
        line_current=$(( line_current + 1 ))

        if [[ -f "$SKETCHES_DIR/${organism}_${id}.msh" ]]; then
            echo "Sketch already exists, skipping download"
            printf "%s\t%s\n" "$id" "$organism" >> "$NEW_PROCESSED"
            continue
        fi

        if ! process_genome "$id" "$organism"; then
            continue
        fi

        # Add to processed list
        printf "%s\t%s\n" "$id" "$organism" >> "$NEW_PROCESSED"

    done < "$IDS_FILE"

    # Build final database from all sketches iteratively
    sketch_count=$(find "$SKETCHES_DIR" -name "*.msh" | wc -l)

    if [[ "$sketch_count" -eq 0 ]]; then
        echo "ERROR: no sketches found in $SKETCHES_DIR" >> "$ERROR_LOG"
        exit 1
    fi

    log_step "Pasting $sketch_count sketches into final database"

    first_sketch=true
    paste_current=0
    while IFS= read -r sketch; do
        paste_current=$(( paste_current + 1 ))
        sketch_base=$(basename "$sketch" .msh)
        sketch_id=$(echo "$sketch_base" | grep -oP 'GC[FA]_[0-9]+\.[0-9]+$')
        sketch_org=$(echo "$sketch_base" | sed "s/_${sketch_id}$//")
        echo "[$paste_current/$sketch_count] Adding to database: $sketch_id ($sketch_org)"

        if [[ "$first_sketch" == true ]]; then
            cp "$sketch" "$MSH_DB"
            first_sketch=false
        else
            "$MASH_BIN" paste "${MSH_DB%.msh}_tmp" "$MSH_DB" "$sketch" 2>/dev/null
            tmp_msh="${MSH_DB%.msh}_tmp.msh"
            [[ ! -f "$tmp_msh" ]] && tmp_msh="${MSH_DB%.msh}_tmp"
            mv "$tmp_msh" "$MSH_DB"
        fi
    done < <(find "$SKETCHES_DIR" -name "*.msh" | sort)

fi

# ============================================
# SCENARIO B — incremental update
# ============================================
if [[ "$RUN_MODE" == "incremental" ]]; then

    # Rebuild associative array from previous processed file
    declare -A prev_map_b
    while IFS=$'\t' read -r id organism; do
        [[ -z "$id" ]] && continue
        prev_map_b["$id"]="$organism"
    done < "$PREV_PROCESSED"

    # Load new IDS_FILE into set: base_id -> full_id
    declare -A new_ids_b
    while IFS=$'\t' read -r new_id new_org_raw; do
        [[ -z "$new_id" ]] && continue
        base_id="${new_id%.*}"
        new_ids_b["$base_id"]="$new_id"
    done < "$IDS_FILE"

    # Find the most recent existing database
    PREV_MSH_DB=$(find "$WORKDIR" -maxdepth 1 -name "RefSeqSketches_*.msh" | \
        grep -v '_tmp\|_backup' | sort | tail -n 1 || true)

    if [[ -z "$PREV_MSH_DB" ]]; then
        log_step "WARNING: no previous database found, will build from all sketches"
    else
        log_step "Previous database: $(basename "$PREV_MSH_DB")"
    fi

    # Copy previous processed to new processed
    cp "$PREV_PROCESSED" "$NEW_PROCESSED"

    NEW_COUNT=0
    REMOVED_COUNT=0
    line_current=1

    # Remove sketches for genomes no longer in reference
    log_step "Checking for removed genomes"
    for id in "${!prev_map_b[@]}"; do
        base_id="${id%.*}"
        if [[ ! -v new_ids_b["$base_id"] ]]; then
            organism="${prev_map_b[$id]}"
            sketch="$SKETCHES_DIR/${organism}_${id}.msh"
            if [[ -f "$sketch" ]]; then
                log_step "Removing sketch for $id (no longer in RefSeq reference)"
                rm -f "$sketch"
                REMOVED_COUNT=$(( REMOVED_COUNT + 1 ))
            fi
            grep -vP "^${id}\t" "$NEW_PROCESSED" > "${NEW_PROCESSED}.tmp" && \
                mv "${NEW_PROCESSED}.tmp" "$NEW_PROCESSED"
        fi
    done
    unset new_ids_b

    [[ $REMOVED_COUNT -gt 0 ]] && log_step "Removed $REMOVED_COUNT obsolete sketches"

    # Add new genomes
    log_step "Adding new genomes"

    # Start new DB as copy of previous (or empty if none)
    if [[ -n "$PREV_MSH_DB" ]]; then
        cp "$PREV_MSH_DB" "$MSH_DB"
    fi

    while IFS=$'\t' read -r id organism_raw; do
        [[ -z "$id" ]] && continue
        organism="${organism_raw// /_}"
        organism="${organism//[^[:alnum:]_.-]/}"
        organism=${organism:-unknown}

        # Skip already processed
        if [[ -v prev_map_b["$id"] ]]; then
            line_current=$(( line_current + 1 ))
            continue
        fi

        echo ""
        echo "---------------------------------------"
        echo "[$line_current/$line_count] NEW: $id ($organism)"
        line_current=$(( line_current + 1 ))

        if ! process_genome "$id" "$organism"; then
            continue
        fi

        local_sketch="$SKETCHES_DIR/${organism}_${id}.msh"

        if [[ ! -f "$MSH_DB" ]]; then
            cp "$local_sketch" "$MSH_DB"
        else
            "$MASH_BIN" paste "${MSH_DB%.msh}_tmp" "$MSH_DB" "$local_sketch" 2>/dev/null
            tmp_msh="${MSH_DB%.msh}_tmp.msh"
            [[ ! -f "$tmp_msh" ]] && tmp_msh="${MSH_DB%.msh}_tmp"
            mv "$tmp_msh" "$MSH_DB"
        fi

        printf "%s\t%s\n" "$id" "$organism" >> "$NEW_PROCESSED"
        NEW_COUNT=$(( NEW_COUNT + 1 ))

    done < "$IDS_FILE"

    log_step "Incremental update complete: +$NEW_COUNT new, -$REMOVED_COUNT removed"
    unset prev_map_b

fi

# ============================================
# SCENARIO C — full rebuild
# ============================================
if [[ "$RUN_MODE" == "rebuild" ]]; then

    # Find and report previous database (it stays untouched)
    PREV_MSH_DB=$(find "$WORKDIR" -maxdepth 1 -name "RefSeqSketches_*.msh" | \
        grep -v '_tmp' | sort | tail -n 1 || true)
    if [[ -n "$PREV_MSH_DB" ]]; then
        log_step "Previous database retained: $(basename "$PREV_MSH_DB")"
    fi

    # Load previous processed into map: id -> organism
    declare -A prev_map_c
    log_step "Loading previous processed list..."
    while IFS=$'\t' read -r id organism; do
        [[ -z "$id" ]] && continue
        prev_map_c["$id"]="$organism"
    done < "$PREV_PROCESSED"

    # Load new IDS_FILE into map: base_id -> "full_id\torganism"
    declare -A new_map_c
    log_step "Loading new genome list..."
    while IFS=$'\t' read -r new_id new_org_raw; do
        [[ -z "$new_id" ]] && continue
        base_id="${new_id%.*}"
        new_org="${new_org_raw// /_}"
        new_org="${new_org//[^[:alnum:]_.-]/}"
        new_map_c["$base_id"]="${new_id}"$'\t'"${new_org}"
    done < "$IDS_FILE"
    log_step "Genome lists loaded"

    # Remove sketches for changed or deleted genomes only
    log_step "Removing outdated sketches"
    removed_c=0
    for id in "${!prev_map_c[@]}"; do
        organism="${prev_map_c[$id]}"
        base_id="${id%.*}"

        # Check if GCF disappeared entirely
        if [[ ! -v new_map_c["$base_id"] ]]; then
            sketch="$SKETCHES_DIR/${organism}_${id}.msh"
            [[ -f "$sketch" ]] && rm -f "$sketch" && removed_c=$(( removed_c + 1 ))
            log_step "Removed outdated sketch: $id ($organism) — no longer in RefSeq"
            continue
        fi

        # Check if organism name or version changed
        new_id=$(cut -f1 <<< "${new_map_c[$base_id]}")
        new_org=$(cut -f2 <<< "${new_map_c[$base_id]}")

        if [[ "$organism" != "$new_org" ]] || [[ "$id" != "$new_id" ]]; then
            sketch="$SKETCHES_DIR/${organism}_${id}.msh"
            [[ -f "$sketch" ]] && rm -f "$sketch" && removed_c=$(( removed_c + 1 ))
            log_step "Removed outdated sketch: $id ($organism)"
        fi
    done
    log_step "Removed $removed_c outdated sketches"
    unset prev_map_c new_map_c

    # Re-initialize processed file
    : > "$NEW_PROCESSED"

    line_current=1
    log_step "Downloading updated/new genomes"

    while IFS=$'\t' read -r id organism_raw; do
        [[ -z "$id" ]] && continue
        organism="${organism_raw// /_}"
        organism="${organism//[^[:alnum:]_.-]/}"
        organism=${organism:-unknown}

        # Skip if sketch already exists (unchanged genomes)
        if [[ -f "$SKETCHES_DIR/${organism}_${id}.msh" ]]; then
            printf "%s\t%s\n" "$id" "$organism" >> "$NEW_PROCESSED"
            line_current=$(( line_current + 1 ))
            continue
        fi

        echo ""
        echo "---------------------------------------"
        echo "[$line_current/$line_count] Processing: $id ($organism)"
        line_current=$(( line_current + 1 ))

        if ! process_genome "$id" "$organism"; then
            continue
        fi

        printf "%s\t%s\n" "$id" "$organism" >> "$NEW_PROCESSED"

    done < "$IDS_FILE"

    echo ""
    echo "-----------------------------------------------------------"
    log_step "NOTE: rebuilding full database from all sketches — this may take over 2 hours"
    echo "-----------------------------------------------------------"

    # Build final database from all sketches iteratively
    sketch_count=$(find "$SKETCHES_DIR" -name "*.msh" | wc -l)

    if [[ "$sketch_count" -eq 0 ]]; then
        echo "ERROR: no sketches found after rebuild" >> "$ERROR_LOG"
        exit 1
    fi

    log_step "Pasting $sketch_count sketches into final database"

    first_sketch=true
    paste_current=0
    while IFS= read -r sketch; do
        paste_current=$(( paste_current + 1 ))
        sketch_base=$(basename "$sketch" .msh)
        sketch_id=$(echo "$sketch_base" | grep -oP 'GC[FA]_[0-9]+\.[0-9]+$')
        sketch_org=$(echo "$sketch_base" | sed "s/_${sketch_id}$//")
        echo "[$paste_current/$sketch_count] Adding to database: $sketch_id ($sketch_org)"

        if [[ "$first_sketch" == true ]]; then
            cp "$sketch" "$MSH_DB"
            first_sketch=false
        else
            "$MASH_BIN" paste "${MSH_DB%.msh}_tmp" "$MSH_DB" "$sketch" 2>/dev/null
            tmp_msh="${MSH_DB%.msh}_tmp.msh"
            [[ ! -f "$tmp_msh" ]] && tmp_msh="${MSH_DB%.msh}_tmp"
            mv "$tmp_msh" "$MSH_DB"
        fi
    done < <(find "$SKETCHES_DIR" -name "*.msh" | sort)

fi

# ============================================
# Validate final database
# ============================================
echo ""
echo "========================================="
log_step "Validating final database"

if [[ ! -f "$MSH_DB" ]]; then
    echo "ERROR: database file not found: $MSH_DB" >> "$ERROR_LOG"
    echo "ERROR: database file not found after completion"
else
    db_count=$("$MASH_BIN" info -t "$MSH_DB" 2>/dev/null | grep -vc '^#' || echo 0)
    sketch_count=$(find "$SKETCHES_DIR" -name "*.msh" | wc -l)
    processed_count=$(grep -c '.' "$NEW_PROCESSED" 2>/dev/null || echo 0)

    echo "   Sketches in sketches/:    $sketch_count"
    echo "   Entries in processed.txt: $processed_count"
    echo "   Sketches in database:     $db_count"

    if [[ "$db_count" -eq "$sketch_count" ]]; then
        log_step "Validation OK: database count matches sketches ($db_count)"
    else
        echo "WARNING: database count ($db_count) does not match sketches ($sketch_count)" >> "$ERROR_LOG"
        log_step "WARNING: database count ($db_count) does not match sketches ($sketch_count)"
    fi
fi

# ============================================
# Completion
# ============================================
echo ""
echo "========================================="
log_step "Mash database creation completed!"
echo "   Mode:     $RUN_MODE"
echo "   Database: $MSH_DB"
echo "   Sketches: $SKETCHES_DIR"
echo "   Results:  $WORKDIR"
echo "========================================="
echo "End time: $(date '+%Y-%m-%d %H:%M:%S')" >> "$LOG_FILE"