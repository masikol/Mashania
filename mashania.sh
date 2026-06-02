#!/bin/bash
# ============================================
# Set locale for reproducibility
# ============================================
# Use C.UTF-8 if available, otherwise fallback to C
if locale -a 2>/dev/null | grep -qi '^C\.UTF-8$'; then
    export LC_ALL=C.UTF-8
else
    export LC_ALL=C
fi

# Save full command line (for logging/debugging)
FULL_COMMAND=$(printf "%q " "$0" "$@")
# Determine the absolute path to the script's directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Enable strict error handling:
# -e  : exit on any command failure
# -u  : error on undefined variables
# -o pipefail : fail if any command in pipeline fails
set -euo pipefail

# ============================================
# Paths to software and databases
# ============================================
Path_mash=""
# Example: Path_mash="/media/cager-lab/EVO/soft/mash-Linux64-v2.3/"
# Mash: fast genome distance estimation
# https://github.com/marbl/Mash/releases

Path_ncbi_datasets=""
# Example: Path_ncbi_datasets="/media/cager-lab/EVO/soft/ncbi-datasets-cli/"
# NCBI datasets CLI for downloading genomes
# https://ftp.ncbi.nlm.nih.gov/pub/datasets/command-line/LATEST/linux-amd64/datasets

Path_fastani=""
# Example: Path_fastani="/media/cager-lab/EVO/soft/fastANI-linux64-v1.34/"
# FastANI: accurate ANI calculation
# https://github.com/ParBLiSS/FastANI/releases

RefSeq_msh=""
# Precomputed Mash sketch database for RefSeq genomes
# https://doi.org/10.5281/zenodo.20293962

# ============================================
# Functions
# ============================================
print_banner() {
cat << "EOF"

  █───█─████─███─█──█─████─█──█─███─████
  ██─██─█──█─█───█──█─█──█─██─█──█──█──█
  █─█─█─████─███─████─████─█─██──█──████
  █───█─█──█───█─█──█─█──█─█──█──█──█──█
  █───█─█──█─███─█──█─█──█─█──█─███─█──█ -v1.0-(2026-06-01)

Tool for identifying the closest matching genome in the GenBank database.

EOF
}
# Function to log a message with elapsed time since script start
# Prints time in HH:MM:SS format followed by the provided message
log_step() {
    local msg="$1"
    local now=$(date +%s)
    local elapsed=$((now - START_TIME))

    printf "%02d:%02d:%02d - %s\n" \
        $((elapsed/3600)) $((elapsed%3600/60)) $((elapsed%60)) \
        "$msg"
}

# Check executable file and auto-fix permissions if needed
check_executable() {
    local full_path="$1"

    if [ -f "$full_path" ]; then

        # AUTO-FIX MODE: try to make executable
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

# Function to resolve a tool location
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

    # Error if not found
    if [ -n "$path" ]; then
        echo "ERROR: $name not found in PATH, script directory, or at ${path%/}/$name" >&2
    else
        echo "ERROR: $name not found in PATH or script directory" >&2
    fi

    case "$name" in
        mash)
            echo "Download Mash: https://github.com/marbl/Mash/releases" >&2
            echo "Extract the archive and either add 'mash' executable to PATH or set Path_mash in this script (path to mash binary)." >&2
            echo "Example: Path_mash=\"/opt/mash/\"" >&2
            echo "See line 24" >&2
            ;;
        datasets)
            echo "Download NCBI Datasets CLI: https://www.ncbi.nlm.nih.gov/datasets/docs/v2/download-and-install/" >&2
            echo "Add 'datasets' executable to PATH or set Path_ncbi_datasets in this script (path to datasets binary)." >&2
            echo "Example: Path_ncbi_datasets=\"/opt/ncbi-datasets/\"" >&2
            echo "See line 29" >&2
            ;;
        fastANI)
            echo "Download FastANI: https://github.com/ParBLiSS/FastANI/releases" >&2
            echo "Extract the archive and either add 'fastANI' executable to PATH or set Path_fastani in this script (path to fastANI binary)." >&2
            echo "Example: Path_fastani=\"/opt/fastani/\"" >&2
            echo "See line 34" >&2
            ;;
    esac

    return 1
}

# Extract GCA/GCF accession from filename or path
# Example: GCF_000001405.1_genomic.fna -> GCF_000001405.1
extract_accession() {
    basename "$1" | grep -oE 'GC[AF]_[0-9]+(\.[0-9]+)?' | head -1
}

# Extract species name from RefSeq/GenBank filename
# Example: Escherichia_coli_GCF_000005845.2 -> Escherichia coli
extract_species_from_filename() {
    basename "$1" | sed -E 's/_(GCF|GCA)_.*//' | tr '_' ' '
}

# Wrapper around 'datasets summary' with timeout and retry logic
#   Usage: datasets_query <timeout_sec> <max_attempts> [datasets args...]
datasets_query() {
    local timeout_sec="$1"
    local max_attempts="$2"
    shift 2
    local attempt=1
    local output
    while [[ $attempt -le $max_attempts ]]; do
        if output=$(timeout "$timeout_sec" "${Path_ncbi_datasets}datasets" "$@" 2>/dev/null); then
            echo "$output"
            return 0
        fi
        local exit_code=$?
        if [[ $exit_code -eq 124 ]]; then
            echo "  [NCBI] WARNING: request timed out (attempt $attempt/$max_attempts): datasets $*" >> "$LOG_FILE"
        else
            echo "  [NCBI] WARNING: request failed with code $exit_code (attempt $attempt/$max_attempts): datasets $*" >> "$LOG_FILE"
        fi
        attempt=$((attempt + 1))
        [[ $attempt -le $max_attempts ]] && sleep 5
    done
    echo "  [NCBI] ERROR: all $max_attempts attempts failed: datasets $*" >> "$LOG_FILE"
    return 1
}

# Function to check ZIP file integrity
is_valid_zip() {
    local zip_file="$1"
    if [ -f "$zip_file" ] && [ -s "$zip_file" ]; then
        unzip -t "$zip_file" > /dev/null 2>&1
        return $?
    fi
    return 1
}

# Return organism name (taxon) for a given genome accession (GCF/GCA)
# Uses NCBI Datasets CLI and jq
get_taxon_name() {
    local accession="$1"

    # basic validation
    if [[ -z "$accession" ]]; then
        echo "ERROR: empty accession" >&2
        return 1
    fi

    # query NCBI datasets
    local result
    if ! result=$(datasets_query 60 3 summary genome accession "$accession"); then
        echo "ERROR: datasets query failed for $accession" >&2
        return 1
    fi

    # extract organism name
    local taxon
    taxon=$(echo "$result" | jq -r '.reports[0].organism.organism_name // empty')

    if [[ -z "$taxon" || "$taxon" == "null" ]]; then
        echo "ERROR: taxon not found for $accession" >&2
        return 1
    fi

    echo "$taxon"
}


# Function to download and rehydrate a single species
download_and_rehydrate() {
    local species="$1"
    local from_type="$2"                 # datasets parameter (--from-type OR --reference)
    local out_dir="$3"                   # working directory
    local progressbar="${4:-}"           # - optional: "--no-progressbar" → add --no-progressbar
    local display_name="${5:-$species}"  # Name shown in progress/messages (fallback: species)

    local safe_name
    safe_name=$(echo "$species" | tr ' ' '_')

    local dehydrated_zip="$out_dir/${safe_name}_dehydrated.zip"
    local unzip_dir="$out_dir/${safe_name}_unzipped${from_type:+$from_type}"

    rm -f "$dehydrated_zip"
    rm -rf "$unzip_dir"

    # Create directory only for real downloads.
    # Cached runs will create a symlink instead.
    if [[ ! ( -z "$from_type" && -n "${GENOME_CACHE[$species]:-}" ) ]]; then
        mkdir -p "$unzip_dir"
    fi

    local max_attempts=5
    local attempt=1
    local downloaded=0

    # Download target:
    # normally species name, but may be replaced with taxid
    # if NCBI reports an ambiguous taxon name.
    local download_target="$species"

    # Genome cache reuse (only for taxid-based downloads)
    # Skip cache for reference/type downloads
    if [[ -z "$from_type" && ${#GENOME_CACHE[@]} -gt 0 ]]; then

        local cache_taxid="$species"

        if [[ -n "${GENOME_CACHE[$cache_taxid]:-}" ]]; then

            local cached_dir="${GENOME_CACHE[$cache_taxid]}"

            # Validate cache directory
            if [[ ! -d "$cached_dir" ]]; then
                echo ""
                echo "WARNING: cached directory missing: $cached_dir"

            # Validate cache directory and ensure it contains .fna genomes
            elif [[ $(find "$cached_dir" -follow -name "*.fna" -type f 2>/dev/null | wc -l) -eq 0 ]]; then
                echo ""
                echo "WARNING: cached directory contains no genomes: $cached_dir"

            else

                echo ""
                echo "[$display_name] Using cached genomes for taxid $cache_taxid"

                # Create symlink:
                # OUTPUT/2_results_genomes/2752_unzipped -> old_cache/.../2752_unzipped
                ln -s "$cached_dir" "$unzip_dir"

                echo "  Linked cache:"
                echo "    $cached_dir"
                echo "    -> $unzip_dir"

                return 0
            fi
        fi
    fi

    # Download dehydrated package
    while [ $attempt -le $max_attempts ] && [ $downloaded -eq 0 ]; do
        echo ""
        echo "[$display_name] Attempt $attempt/$max_attempts to download dehydrated ZIP..."

        # Capture output
        download_output=$(
            "${Path_ncbi_datasets}datasets" download genome taxon "$download_target" \
                ${from_type:+$from_type} \
                --dehydrated --no-progressbar \
                --filename "$dehydrated_zip" 2>&1
        ) || true

        echo "$download_output" >> "$LOG_FILE"

        # CASE 0: ambiguous species name
        # NCBI may report multiple matching taxids for the same name.
        # In that case extract the taxid from the line matching
        # the requested species and retry using taxid instead of name.
        if echo "$download_output" | grep -q "exact match for more than one taxid"; then

            local resolved_taxid

            resolved_taxid=$(
                echo "$download_output" \
                | grep -F "$species (" \
                | sed -n 's/.*taxid: \([0-9]\+\).*/\1/p' \
                | head -n1
            )

            if [[ -n "$resolved_taxid" ]]; then

                echo "  [$display_name] Ambiguous species name detected"
                echo "  [$display_name] Resolved taxid: $resolved_taxid"
                echo "[download] Ambiguous species '$species' resolved to taxid $resolved_taxid" >> "$LOG_FILE"

                download_target="$resolved_taxid"

                rm -f "$dehydrated_zip"
                continue
            fi
        fi

        # CASE 1: no assemblies → STOP (not an error)
        # Validate downloaded ZIP archive
        if echo "$download_output" | grep -q "There are no genome assemblies"; then
            echo "  [$display_name] WARNING: no genome assemblies found (skipping)"
            return 0
        fi

        # CASE 2: normal retry logic
        if is_valid_zip "$dehydrated_zip"; then
            echo "  [$display_name] ZIP is valid"
            downloaded=1
        else
            echo "  [$display_name] Download failed or corrupted, retrying..."
            rm -f "$dehydrated_zip"
            attempt=$((attempt + 1))
            sleep 2
        fi
    done

    # Final failure after max attempts
    if [ $downloaded -eq 0 ]; then
        echo ""
        echo "  [$display_name] ERROR: failed to download valid archive after $max_attempts attempts"
        return 1
    fi

    # Extract ZIP archive
    echo "  [$display_name] Unzipping archive..."
    unzip -q "$dehydrated_zip" -d "$unzip_dir"

    # Rehydrate dataset
    echo "  [$display_name] Rehydrating dataset (this may take a while for large downloads)..."

    local rehydrate_ok=0
    local rehydrate_attempt
    local max_rehydrate_attempts=10

    for ((rehydrate_attempt=1; rehydrate_attempt<=max_rehydrate_attempts; rehydrate_attempt++)); do

        if [ "$rehydrate_attempt" -gt 1 ]; then
            echo "  [$display_name] Retrying rehydration using existing partial dataset..."
        fi

        if timeout 900 "${Path_ncbi_datasets}datasets" rehydrate \
            ${progressbar:+$progressbar} \
            --directory "$unzip_dir"; then

            rehydrate_ok=1
            break
        fi

        echo "  [$display_name] WARNING: rehydration failed (attempt $rehydrate_attempt/$max_rehydrate_attempts)" >&2
        sleep 10
    done

    if [ "$rehydrate_ok" -ne 1 ]; then
        echo "  [$display_name] ERROR: rehydration failed after $max_rehydrate_attempts attempts"
        return 1
    fi

    # Extract .fna
    find "$unzip_dir" -name "*.fna.gz" -type f -exec gunzip -f {} \;
}


# Build a deduplicated genome file list with GCF priority
# Usage: build_genome_list <search_dir> <output_list>
build_genome_list() {
    local search_dir="$1"
    local output_list="$2"

    > "$output_list"

    declare -A seen_accessions

    while IFS= read -r fna; do
        acc=$(extract_accession "$fna")

        if [[ -z "$acc" ]]; then
            echo "$fna" >> "$output_list"
            continue
        fi

        base_acc="${acc#GC[AF]_}"

        if [[ -n "${seen_accessions[$base_acc]+x}" ]]; then
            echo "  [dedup] Skipping $acc — already have ${seen_accessions[$base_acc]}" >> "$LOG_FILE"
            continue
        fi

        seen_accessions[$base_acc]="$acc"
        echo "$fna" >> "$output_list"

    # sort -r ensures GCF_* is processed before GCA_*
    done < <(find "$search_dir" -follow -name "*.fna" -type f | sort -r)

    local total unique
    total=$(find "$search_dir" -follow -name "*.fna" -type f | wc -l)
    unique=$(wc -l < "$output_list")
    echo "Unique genomes after GCF/GCA deduplication: $unique (removed $((total - unique)) duplicates)"
    echo "Genome list built: $unique unique genomes → $output_list" >> "$LOG_FILE"
}


# Function to load assembly data from JSONL
# Optional: --no-taxid  → skip expensive species-level taxid normalization
load_assembly_data() {
    local input_dir="$1"
    local mode="${2:-}"

    local skip_taxid=0

    [[ "$mode" == "--no-taxid" ]] && skip_taxid=1

    # Declare a global associative array:
    # Key   → accession (e.g. GCA_00012345.1)
    # Value → "assembly_level<TAB>species_name<TAB>taxid"
    declare -gA ASSEMBLY_DATA
    ASSEMBLY_DATA=()  # clear array before loading

    # Find all assembly_data_report.jsonl files in the input directory
    mapfile -t json_files < <(find "$input_dir" -follow -type f -name "assembly_data_report.jsonl")

    # If no JSONL files are found, exit gracefully
    if [ ${#json_files[@]} -eq 0 ]; then
        echo "WARNING: no assembly_data_report.jsonl files found in $input_dir"
        return 0
    fi

    echo "Loading assembly metadata from ${#json_files[@]} JSONL files..." >> "$LOG_FILE"

    # Process each JSONL file
    for json_file in "${json_files[@]}"; do
        echo "  Processing: $json_file" >> "$LOG_FILE"

        # Extract required fields using jq:
        # 1. currentAccession → unique assembly ID (key)
        # 2. assemblyInfo.assemblyLevel → assembly level
        # 3. organism.organismName → species name
        # 4. strain → from:
        #    - organism.infraspecificNames.strain (preferred)
        #    - fallback: assemblyInfo.biosample.strain
        # 5. organism.taxId → taxonomy ID
        # Output format: tab-separated values (TSV)
        while IFS=$'\t' read -r acc level org strain strain_type taxid; do

            # Skip invalid or missing accession
            [[ -z "$acc" || "$acc" == "null" ]] && continue

            # Normalize missing fields
            [[ -z "$level" || "$level" == "null" ]] && level="Unknown"
            [[ -z "$org"   || "$org"   == "null" ]] && org="Unknown_species"
            [[ -z "$taxid" || "$taxid" == "null" ]] && taxid="NA"

            # Convert assembly/strain taxid → species-level taxid
            # Example:      Carnobacterium funditum DSM 5970 → 1449337
            #      becomes: Carnobacterium funditum → 2752
            # Skip in fast mode (--no-taxid)
            if [[ "$skip_taxid" -eq 0 && "$taxid" != "NA" ]]; then
                if [[ -n "${TAXID_CACHE[$taxid]+x}" ]]; then
                    echo "  [cache] taxid $taxid → ${TAXID_CACHE[$taxid]}" >> "$LOG_FILE"
                    taxid="${TAXID_CACHE[$taxid]}"
                else
                    echo "  [NCBI] querying species-level taxid for taxid $taxid" >> "$LOG_FILE"
                    original_taxid="$taxid"
                    species_taxid=$(
                        datasets_query 60 3 summary taxonomy taxon "$taxid" \
                        | jq -r '
                            .reports[0].taxonomy.classification.species.id
                            // empty
                        '
                    )
                    if [[ -n "$species_taxid" && "$species_taxid" != "null" ]]; then
                        taxid="$species_taxid"
                    fi
                    echo "  [NCBI] taxid $original_taxid → $taxid" >> "$LOG_FILE"
                    TAXID_CACHE["$original_taxid"]="$taxid"
                fi
            fi

            # Construct species name with correct label (strain or isolate)
            if [[ -n "$strain" && "$strain" != "null" ]]; then
                if [[ "$strain_type" == "isolate" ]]; then
                    label="isolate"
                else
                    label="strain"
                fi

                # For ‘Genus sp. <something>’ → remove the tail after sp.
                if echo "$org" | grep -qE ' sp\. '; then
                    base_org=$(echo "$org" | sed -E 's/(sp\.) .*/\1/')
                else
                    base_org="$org"
                fi

                # Check if the strain already has a label and avoid strain name duplication
                # Remove the label prefix from strain for comparison
                strain_without_label="${strain#$label }"
                if [[ "$base_org" == *"$strain_without_label"* ]]; then
                    # The strain is already present in the base organism name → do nothing
                    species="$org"
                elif [[ "$strain" == "$label"* ]]; then
                    # Strain already starts with the label → concatenate base organism name + strain
                    species="$base_org $strain"
                else
                    # Default case → add label before strain
                    species="$base_org $label $strain"
                fi
            else
                species="$org"
            fi

            # Store data in associative array. Use TAB as separator
            ASSEMBLY_DATA["$acc"]="$level"$'\t'"$species"$'\t'"$taxid"

        done < <(
            jq -r '[
              .currentAccession,
              .assemblyInfo.assemblyLevel,
              .organism.organismName,
              (
                .organism.infraspecificNames.strain
                // .assemblyInfo.biosample.strain
                // .organism.infraspecificNames.isolate
                // empty
              ),
              (
                if .organism.infraspecificNames.strain != null then "strain"
                elif .assemblyInfo.biosample.strain != null then "strain"
                elif .organism.infraspecificNames.isolate != null then "isolate"
                else "none"
                end
              ),
              .organism.taxId
            ] | @tsv' "$json_file"
        )
    done

    # Report number of loaded assemblies
    echo "Loaded assemblies: ${#ASSEMBLY_DATA[@]}" >> "$LOG_FILE"
}


# Function to format FastANI results
format_fastani_results() {
    local input_file="$1"    # $1 - FastANI output file
    local output_file="$2"   # $2 - output TSV file
    echo "--------------------------------------------------------------------------------------------------------------"    

    {
        # Table header
        printf "Organism\tAccession|Assembly level\tANI (%%)\tMatched/Total fragments\tAlignment %%\n"

        # Process each line of FastANI output
        # Format: query \t reference \t ANI \t matched \t total
        while IFS=$'\t' read -r query ref ani matched total; do

            # Extract accession from reference file path
            # Example: GCA_00012345.1 or GCF_00012345.1
            accession=$(extract_accession "$ref")
            [ -z "$accession" ] && accession="NA"

            # Retrieve assembly data from associative array
            data="${ASSEMBLY_DATA[$accession]:-}"

            if [ -n "$data" ]; then
                IFS=$'\t' read -r assembly_level species taxid <<< "$data"
            else
                assembly_level="Unknown"
                species="Unknown_species"
            fi

            # Detect metagenome-assembled genomes (MAGs) based on FASTA header and label them
            header=$(grep -m1 "^>" "$ref" 2>/dev/null || true)

            if echo "$header" | grep -Eqi '\bMAG\b|metagenome'; then
                species="(MAG) $species"
            fi

            # Calculate alignment percentage (matched fragments / total fragments)
            align_pct=$(awk -v m="$matched" -v t="$total" 'BEGIN{
                if(t>0) printf "%.2f", (m/t)*100;
                else print "0.00"
            }')

            # Print formatted row
            printf "%s\t%s\t%.4f\t%s/%s\t%s\n" \
                "$species" \
                "$accession|$assembly_level" \
                "$ani" \
                "$matched" \
                "$total" \
                "$align_pct"

        done < "$input_file"

    } | tee "$output_file" | column -t -s $'\t'
}


# Add a species (and optionally related NO_RANK taxonomic groups) to SPECIES_LIST
# Usage: add_species_to_list <species> <taxid> <source_label>
#   source_label — shown in progress output (e.g. "[FastANI]", "[MASH fallback]")
#
# Logic:
#   1. Skip species if already present in SPECIES_LIST
#   2. Determine genus name from species name
#   3. Try to resolve genus taxid from GENUS_CACHE
#   4. Resolve genus taxid via NCBI if cache miss
#   5. Download NO_RANK descendants of the genus via --rank NO_RANK
#   6. Keep only direct NO_RANK children (last taxonomy.parents == genus_taxid)
#   7a. Direct NO_RANK children found → add species + all direct children
#       (unclassified/environmental/ungrouped assemblies)
#   7b. No direct NO_RANK children found → add entire genus instead
#       (genus taxid already covers all species and descendants)
#
# Returns 0 if a new entry was added, 1 if skipped
add_species_to_list() {
    local species="$1"
    local taxid="$2"
    local source_label="$3"

    # Skip if this species is already covered
    if grep -Pq "^${species}\t" "$SPECIES_LIST" 2>/dev/null; then
        echo "  $source_label Skipping $species — species $species already covered in list" >> "$LOG_FILE"
        return 1
    fi

    echo "[taxonomy] Resolving genus for species '$species' (taxid: $taxid)" >> "$LOG_FILE"

# 1: Determine genus name from species name
#Handles both: "Carnobacterium iners" or "Candidatus Liberibacter asiaticus"
local genus
if [[ "$species" =~ ^Candidatus[[:space:]]+([^[:space:]]+) ]]; then
    genus="Candidatus ${BASH_REMATCH[1]}"
else
    genus="${species%% *}"
fi

# 2: Try genus cache lookup by genus name
local genus_taxid genus_name cache_hit=0

for cache_key in "${!GENUS_CACHE[@]}"; do
    [[ "$cache_key" =~ ^norank_ ]] && continue

    local cached_taxid cached_name
    cached_taxid=$(echo "${GENUS_CACHE[$cache_key]}" | cut -f1)
    cached_name=$(echo "${GENUS_CACHE[$cache_key]}"  | cut -f2)

    if [[ "$cached_name" == "$genus" ]]; then
        genus_taxid="$cached_taxid"
        genus_name="$cached_name"
        cache_hit=1
        echo "[taxonomy] Genus cache hit for $genus_name → taxid $genus_taxid" >> "$LOG_FILE"
        break
    fi
done

# 3: Resolve genus via NCBI if cache miss
if [[ "$cache_hit" -eq 0 ]]; then
    read -r genus_taxid genus_name < <(
        datasets_query 60 3 summary taxonomy taxon "$taxid" \
        | jq -r '
            .reports[0].taxonomy.classification.genus
            | [(.id | tostring), .name]
            | @tsv
        '
    )

    if [[ -z "$genus_taxid" || "$genus_taxid" == "null" || -z "$genus_name" ]]; then
        echo "ERROR: failed to resolve genus for taxid $taxid" >&2
        echo "[taxonomy] ERROR: genus resolution failed for taxid $taxid" >> "$LOG_FILE"

        # Fallback: add species as-is
        printf "%s\t%s\n" "$species" "$taxid" >> "$SPECIES_LIST"
        echo "  $source_label $species (taxId: $taxid) [genus resolution failed]"
        return 0
    fi

    # Store:
    #   species taxid -> genus taxid + genus name
    GENUS_CACHE[$taxid]="${genus_taxid}"$'\t'"${genus_name}"

    echo "[taxonomy] Genus resolved: $genus_name ($genus_taxid) for taxid $taxid" >> "$LOG_FILE"
fi

    # 4: Check NO_RANK children cache (keyed by genus_taxid)
    local no_rank_children
    if [[ -n "${GENUS_CACHE[norank_${genus_taxid}]+x}" ]]; then
        no_rank_children="${GENUS_CACHE[norank_${genus_taxid}]}"
        echo "[taxonomy] Using cached NO_RANK children for genus $genus_name ($genus_taxid)" >> "$LOG_FILE"
    else
        # 5: Download NO_RANK children of the genus
        local children_zip children_dir children_jsonl
        children_zip=$(mktemp "$OUTPUT/genus_${genus_taxid}_XXXXXX.zip")
        children_dir=$(mktemp -d "$OUTPUT/genus_${genus_taxid}_XXXXXX")

        local download_ok=1
        if ! timeout 320 "${Path_ncbi_datasets}datasets" download taxonomy taxon "$genus_taxid" \
            --children --rank NO_RANK \
            --filename "$children_zip" --no-progressbar 2>/dev/null; then
            echo "WARNING: failed to download NO_RANK children for genus $genus_name ($genus_taxid)" >&2
            echo "[taxonomy] WARNING: NO_RANK children download failed for $genus_name ($genus_taxid)" >> "$LOG_FILE"
            download_ok=0
        fi

        if [[ $download_ok -eq 1 ]]; then
            unzip -q "$children_zip" -d "$children_dir" 2>/dev/null
            children_jsonl="$children_dir/ncbi_dataset/data/taxonomy_report.jsonl"
        fi
        rm -f "$children_zip"

        if [[ $download_ok -eq 0 || ! -f "${children_jsonl:-}" ]]; then
            [[ -d "$children_dir" ]] && rm -rf "$children_dir"
            no_rank_children=""
        else
            # STEP 6: Filter — keep only direct children (last taxonomy.parents value == genus_taxid)
            no_rank_children=$(
                jq -r --argjson parent "$genus_taxid" '
                    select(
                        (.taxonomy.parents | last // -1) == $parent
                    )
                    | [
                        (.taxonomy.currentScientificName.name? // ""),
                        (.taxonomy.taxId | tostring)
                      ]
                    | @tsv
                ' "$children_jsonl" 2>/dev/null \
                | awk -F'\t' 'NF==2 && $1!="" && $2!=""'
            )
            rm -rf "$children_dir"
            echo "[taxonomy] Direct NO_RANK children of $genus_name ($genus_taxid): $(echo "$no_rank_children" | grep -c .)" >> "$LOG_FILE"
        fi

        GENUS_CACHE[norank_${genus_taxid}]="$no_rank_children"
    fi

    # STEP 7: Decide what to add
    if [[ -n "$no_rank_children" ]]; then
        # Direct NO_RANK children found → add species + all direct children
        printf "%s\t%s\n" "$species" "$taxid" >> "$SPECIES_LIST"
        echo "  $source_label $species (taxId: $taxid)"

        local added_count=0
        while IFS=$'\t' read -r child_name child_taxid; do
            [[ -z "$child_name" || -z "$child_taxid" ]] && continue
            if ! grep -Pq $'\t'"${child_taxid}"'$' "$SPECIES_LIST"; then
                # NCBI reuses names like "environmental samples" across genera — make them unique
                case "$child_name" in
                    "environmental samples")
                        child_name="${child_name} (${genus_name})"
                        ;;
                esac

                printf "%s\t%s\n" "$child_name" "$child_taxid" >> "$SPECIES_LIST"
                if [[ "$added_count" -eq 0 ]]; then
                    echo "  Adding NO_RANK taxonomic groups for genus: $genus_name:"
                    echo "  (these cover unclassified, environmental and other ungrouped genomes)"
                fi
                echo "    + $child_name (taxId: $child_taxid)"
                added_count=$((added_count + 1))
            fi
        done <<< "$no_rank_children"
    else
        # No direct NO_RANK children → add entire genus
        # The genus taxid covers all species, so previously collected species entries
        # for this genus become redundant — they will be skipped via the genus check above
        # for any subsequent species of the same genus.
        printf "%s\t%s\n" "$genus_name" "$genus_taxid" >> "$SPECIES_LIST"
        echo "  $source_label $species — no direct NO_RANK children found;"
        echo "    adding entire genus: $genus_name (taxId: $genus_taxid)"
        echo "[taxonomy] No direct NO_RANK children for $species → added genus $genus_name ($genus_taxid)" >> "$LOG_FILE"
    fi

    return 0
}

#==================================================
# Global caches — declared early to ensure availability before load_assembly_data() is called
#==================================================
declare -gA TAXID_CACHE=()
declare -gA GENUS_CACHE=()
declare -ga CACHE_INPUT_DIRS=()
declare -gA GENOME_CACHE=()

# ============================================
# Command-line argument parsing
# ============================================
# Function to display help message
show_help() {
print_banner
cat << EOF
------------------------------------------------------------------------
Usage:
  $0 --fasta <file> [options]

Required:
  -f, --fasta        Input FASTA file

Options:
  -o, --output         Output directory (default: FASTA file directory)
  -d, --data-base      Path to Mash sketch of RefSeq Bacterial Reference Genomes
  -n, --neighbors      Number of closest species for in-depth analysis (default: 3)
  -m, --top-mash       Number of closest RefSeq genomes based on Mash distances (default: 15)
  -a, --top-ani        Number of closest genomes used for FastANI analysis (default: 10)
  -s, --min-hashes     Minimum number of shared Mash hashes required to include a genome in FastANI analysis (default: 6)
  -r, --ref-or-type    Select genomes for the initial FastANI comparison <reference|from-type> (default: reference)
  --cache-dir          Path to previous MashAnia output directory (can be used multiple times)
  --keep-results-only  Keep only analysis results; remove intermediate files and downloaded genomes
  -h, --help           Show help

Example:
  $0 -f genome.fasta -o results -n 5
EOF
}

# Show help if no arguments provided
if [[ $# -eq 0 ]]; then
    show_help
    exit 0
fi

# Quick help interception
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
        --fasta | -f)
            FASTA_FILE="$2"
            shift 2
            ;;
        --output | -o)
            OUTPUT="$2"
            shift 2
            ;;
        --data-base | -d)
            DATABASE="$2"
            shift 2
            ;;
        --neighbors | -n)
            NEIGHBORS="$2"
            shift 2
            ;;
        --top-mash | -m)
            TOPMASH="$2"
            shift 2
            ;;
        --top-ani | -a)
            TOPANI="$2"
            shift 2
            ;;
        --min-hashes | -s)
            MIN_HASHES="$2"
            shift 2
            ;;
        --ref-or-type | -r)
            REF_OR_TYPE="$2"
            shift 2
            ;;
        --cache-dir)
            CACHE_INPUT_DIRS+=("$2")
            shift 2
            ;;
        --keep-results-only)
            KEEP_ONLY_RESULTS=true
            shift
            ;;
        *)
            echo "Unknown parameter: $1"
            echo "See '$0 --help' for usage."
            exit 1
            ;;
    esac
done

# Check required arguments
if [[ -z "${FASTA_FILE:-}" ]]; then
    echo "ERROR: FASTA file must be specified using --fasta"
    exit 1
fi

# Default working directory
if [ -z "${OUTPUT:-}" ]; then
    OUTPUT="$(dirname "$FASTA_FILE")/$(basename "${FASTA_FILE%.*}")_mashania_$(date +%Y-%m-%d_%H-%M)"
fi

# Default Mash sketch
if [ -z "${DATABASE:-}" ]; then
    DATABASE=$RefSeq_msh
fi

# Default number of neighbors
if [ -z "${NEIGHBORS:-}" ]; then
    NEIGHBORS=3
fi

# Default number of top-mash
if [ -z "${TOPMASH:-}" ]; then
    TOPMASH=15
fi

# Default number of top-ani
if [ -z "${TOPANI:-}" ]; then
    TOPANI=10
fi

# Default value for MIN_HASHES (used for filtering Mash hits)
if [ -z "${MIN_HASHES:-}" ]; then
    MIN_HASHES=6
fi

# Set default value for --ref-or-type option (reference | from-type)
if [ -z "${REF_OR_TYPE:-}" ]; then
    REF_OR_TYPE="reference"
fi

# Create working directory
mkdir -p "$OUTPUT"

# ============================================
# Logging setup
# ============================================
LOG_FILE="$OUTPUT/run.log"
echo "=========================================" > "$LOG_FILE"
# Log the execution command and timestamp
{
echo "Command: $FULL_COMMAND"
echo "Start time: $(date '+%Y-%m-%d %H:%M:%S')"
echo "========================================="
} >> "$LOG_FILE"

# Redirect stdout/stderr to both console and log file.
# ANSI escape sequences are removed before writing to the log.
# Progress-bar updates like: Completed X of Y [...] NN%
# are suppressed in the log to avoid hundreds of duplicate lines,
# but the final 100% completion line is preserved.
exec > >(
    tee >(
        stdbuf -oL sed -u -E 's/\x1b\[[0-9;]*[A-Za-z]//g; s/\r//g' \
        | stdbuf -oL awk '
            /^Completed [0-9]+ of [0-9]+ / {
                last=$0
                next
            }

            {
                if (last != "") {
                    print last
                    last=""
                }
                print
            }

            END {
                if (last != "")
                    print last
            }
        ' >> "$LOG_FILE"
    )
) 2>&1

# Let’s get started!
print_banner

# ============================================
# Validate required tools and files
# ============================================
#jq and unzip dependency checks
command -v jq >/dev/null || { echo "ERROR: jq required (https://jqlang.org/download/)"; exit 1; }
command -v unzip >/dev/null || { echo "ERROR: unzip is required (on Debian/Ubuntu/Mint install it with: sudo apt install unzip)"; exit 1; }
# Check Mash binary
Path_mash=$(resolve_dir_or_empty mash "$Path_mash") || exit 1

# Check datasets CLI
Path_ncbi_datasets=$(resolve_dir_or_empty datasets "$Path_ncbi_datasets") || exit 1

# Check FastANI
Path_fastani=$(resolve_dir_or_empty fastANI "$Path_fastani") || exit 1

# Resolve Mash database (priority: --data-base > RefSeq_msh > script directory largest .msh)
if [ -n "${DATABASE:-}" ] && [ -r "$DATABASE" ]; then
    echo "   Mash database (resolved) from --data-base: $DATABASE" >> "$LOG_FILE"

elif [ -n "${RefSeq_msh:-}" ] && [ -r "$RefSeq_msh" ]; then
    DATABASE="$RefSeq_msh"
    echo "   Mash database (resolved) from RefSeq_msh: $DATABASE" >> "$LOG_FILE"

elif [ -n "${SCRIPT_DIR:-}" ] && [ -d "$SCRIPT_DIR" ]; then

    DATABASE=$(find "$SCRIPT_DIR" -maxdepth 1 -type f -name "*.msh" 2>/dev/null \
        | while read -r f; do
            printf "%s\t%s\n" "$(stat -c%s "$f")" "$f"
          done \
        | sort -nr \
        | head -n1 \
        | cut -f2)
    if [ -n "${DATABASE:-}" ] && [ -r "$DATABASE" ]; then
        echo "   Mash database (resolved) from SCRIPT_DIR: $DATABASE" >> "$LOG_FILE"
    fi
fi

# Warn if Mash database is older than 90 days
if [ -n "${DATABASE:-}" ] && [ -r "$DATABASE" ]; then
    db_age_days=$(( ( $(date +%s) - $(stat -c %Y "$DATABASE") ) / 86400 ))

    if [ "$db_age_days" -gt 90 ]; then
        echo "WARNING: Mash database is $db_age_days days old." >&2
        echo "         Consider downloading or rebuilding a newer RefSeq sketch database." >&2
    fi
    echo "[database] NB: Mash database is $db_age_days days old: $DATABASE" >> "$LOG_FILE"
fi

# Final database validation
if [ -z "${DATABASE:-}" ] || [ ! -r "$DATABASE" ]; then
    echo "ERROR: no valid Mash database (.msh) found" >&2
    echo "Please use --data-base option, or set Path_mash variable in this script (path to .msh file), or place .msh file in script directory" >&2
    echo "Please check that the file exists and is readable." >&2
    echo "RefSeq Mash database can be downloaded here: https://doi.org/10.5281/zenodo.20293962" >&2
    echo "Alternatively, you can build your own database from RefSeq genomes using Mash (see https://github.com/erinyoung/update_mash_dist)" >&2
    exit 1
fi

# Normalize input FASTA (support .gz)
if [[ "$FASTA_FILE" == *.gz ]]; then
    echo "Detected gzipped FASTA: $FASTA_FILE"
    echo "Decompressing into output directory..."

    BASE_INPUT_NAME=$(basename "$FASTA_FILE")
    BASE_INPUT_NAME=${BASE_INPUT_NAME%.gz}

    UNZIPPED_FASTA="$OUTPUT/$BASE_INPUT_NAME"

    if ! gunzip -c "$FASTA_FILE" > "$UNZIPPED_FASTA"; then
        echo "ERROR: failed to decompress FASTA file: $FASTA_FILE"
        exit 1
    fi

    FASTA_FILE="$UNZIPPED_FASTA"
    echo "Decompressed FASTA saved as: $FASTA_FILE"
fi

# Validate FASTA input
if [[ ! -f "$FASTA_FILE" ]]; then
    echo "ERROR: FASTA file does not exist: $FASTA_FILE"
    exit 1
fi

if [[ ! -r "$FASTA_FILE" ]]; then
    echo "ERROR: FASTA file is not readable: $FASTA_FILE"
    exit 1
fi

if [[ ! -s "$FASTA_FILE" ]]; then
    echo "ERROR: FASTA file is empty: $FASTA_FILE"
    exit 1
fi

if [[ $(wc -l < "$FASTA_FILE") -lt 2 ]]; then
    echo "ERROR: FASTA file must contain at least 2 lines"
    exit 1
fi

if ! grep -q '^>' "$FASTA_FILE"; then
    echo "ERROR: Input file does not look like FASTA (no header lines starting with '>')"
    exit 1
fi

# ============================================
# File paths
# ============================================
SKETCH_FILE="$OUTPUT/$(basename "${FASTA_FILE%.*}").msh"
RESULTS_1_MASH="$OUTPUT/1_results_mash_raw.txt"
RESULTS_1_MASH_TOP="$OUTPUT/1_results_mash_top_${TOPMASH}.txt"
RESULTS_1_DIR="$OUTPUT/1_results_genomes"
RESULTS_1_REF_LIST="$OUTPUT/1_results_top_${TOPMASH}_refs.txt"
RESULTS_1_FASTANI_TOP="$OUTPUT/1_results_fastani_raw.txt"
SPECIES_LIST="$OUTPUT/species_list.txt"
RESULTS_2_DIR="$OUTPUT/2_results_genomes"
RESULTS_2_MASH="$OUTPUT/2_results_mash_raw.txt"
RESULTS_2_REF_LIST="$OUTPUT/2_results_top_${TOPANI}_refs.txt"
RESULTS_2_MASH_TOP="$OUTPUT/2_results_mash_top_${TOPANI}.txt"
RESULTS_2_GENOME_LIST="$OUTPUT/2_results_genomes.txt"
RESULTS_2_FASTANI="$OUTPUT/2_results_fastani_raw.txt"


# ============================================
# Basic FASTA statistics
# ============================================
# Count number of contigs (headers) and total sequence length
read CONTIGS LENGTH < <(
    awk '
        /^>/ {c++}
        !/^>/ {l+=length($0)}
        END {print c, l}
    ' "$FASTA_FILE"
)

echo "====================================================="
echo " Input file: $(basename "${FASTA_FILE}") (${CONTIGS} contigs / ${LENGTH} bp)"
echo " Output directory: $OUTPUT"
echo ""
echo " Initial RefSeq Mash database: $DATABASE"
echo " Number of closest species for in-depth analysis: $NEIGHBORS"
if [[ "${NEIGHBORS:-0}" -eq 0 ]]; then
    echo " WARNING: Only RefSeq-based analysis will be performed (GenBank species-level analysis skipped; NEIGHBORS=0)"
fi
echo " Number of closest RefSeq genomes based on Mash distances: $TOPMASH"
echo " Minimum shared hashes (MIN_HASHES): $MIN_HASHES"
echo " Number of closest genomes used for FastANI analysis: $TOPANI"
echo " Genomes for the initial FastANI comparison: $REF_OR_TYPE"
if [ "${KEEP_ONLY_RESULTS:-}" = "true" ]; then
    echo " WARNING: Keep-only-results is enabled — intermediate genomes and sketches will be removed after analysis"
fi
echo " SYSTEM:" >> "$LOG_FILE"
echo "   Locale: $LC_ALL" >> "$LOG_FILE"
echo "   Threads: $(nproc)" >> "$LOG_FILE"
# Resolve tool binaries from PATH, script directory, or user-defined paths, then log paths and detected versions
RESOLVED_MASH_DIR=$(resolve_dir_or_empty mash "$Path_mash") || exit 1
RESOLVED_DSN_DIR=$(resolve_dir_or_empty datasets "$Path_ncbi_datasets") || exit 1
RESOLVED_FASTANI_DIR=$(resolve_dir_or_empty fastANI "$Path_fastani") || exit 1
if command -v mash >/dev/null 2>&1; then
    MASH_BIN="$(command -v mash)"
else
    MASH_BIN="${RESOLVED_MASH_DIR%/}/mash"
fi

if command -v fastANI >/dev/null 2>&1; then
    FASTANI_BIN="$(command -v fastANI)"
else
    FASTANI_BIN="${RESOLVED_FASTANI_DIR%/}/fastANI"
fi

if command -v datasets >/dev/null 2>&1; then
    DATASETS_BIN="$(command -v datasets)"
else
    DATASETS_BIN="${RESOLVED_DSN_DIR%/}/datasets"
fi
echo "   Mash:    $MASH_BIN ($($MASH_BIN --version 2>/dev/null | head -n1 || echo 'version unknown'))" >> "$LOG_FILE"
echo "   FastANI: $FASTANI_BIN ($($FASTANI_BIN -v 2>&1 | head -n1 || echo 'version unknown'))" >> "$LOG_FILE"
echo "   datasets: $DATASETS_BIN ($($DATASETS_BIN version 2>/dev/null | head -n1 || echo 'version unknown'))" >> "$LOG_FILE"
echo "====================================================="

# Store script start time (Unix time)
# The log_step function prints messages with elapsed time
# since the script start (formatted as HH:MM:SS)
START_TIME=$(date +%s)

# ============================================
# Zero-level: Build genome cache index from previous runs
# ============================================
if [[ ${#CACHE_INPUT_DIRS[@]} -gt 0 ]]; then

    echo "Building genome cache index..."

    for cache_root in "${CACHE_INPUT_DIRS[@]}"; do

        cache_genomes_dir="$cache_root/2_results_genomes"

        if [[ ! -d "$cache_genomes_dir" ]]; then
            echo "WARNING: cache directory does not contain 2_results_genomes: $cache_root"
            continue
        fi

        while IFS= read -r cache_dir; do

            dir_name=$(basename "$cache_dir")

            # Extract taxid from names like:
            # 2752_unzipped
            # 2752_unzippedreference
            taxid=$(echo "$dir_name" | grep -oE '^[0-9]+')

            [[ -z "$taxid" ]] && continue

            # Keep first occurrence only
            if [[ -z "${GENOME_CACHE[$taxid]:-}" ]]; then
                GENOME_CACHE["$taxid"]="$cache_dir"
                echo "  Cached taxid: $taxid -> $cache_dir"
            else
                    echo "  Duplicate cached taxid ignored: $taxid -> $cache_dir" >> "$LOG_FILE"
            fi

        done < <(find "$cache_genomes_dir" -maxdepth 1 -type d -name "*_unzipped*" 2>/dev/null)

    done

    echo "Genome cache indexed: ${#GENOME_CACHE[@]} taxids"
    echo ""
fi
# ============================================
# DEBUG: Dump genome cache contents
# ============================================
#echo ""
#echo "=== Genome cache dump ==="

#for taxid in "${!GENOME_CACHE[@]}"; do
#    echo "taxid=$taxid"
#    echo "  ${GENOME_CACHE[$taxid]}"
#done

#echo "========================="
#echo ""

# ============================================
# STEP 1: Search RefSeq database for the most similar genomes using Mash
# ============================================
echo ""
log_step "[1/6] Searching RefSeq database for the most similar genomes..."

# Create sketch from query genome
if ! "${Path_mash}mash" sketch -o "$SKETCH_FILE" "$FASTA_FILE"; then
    echo "ERROR: failed to create sketch" >&2
    exit 1
fi
echo "Sketch saved: $SKETCH_FILE"

# Compute Mash distances vs RefSeq
echo "Comparing with RefSeq database..."
if ! "${Path_mash}mash" dist "$DATABASE" "$SKETCH_FILE" \
| awk -F'\t' '{ sub(".*/", "", $1); print }' OFS='\t' \
> "$RESULTS_1_MASH"; then
    echo "ERROR: failed to compare with RefSeq database" >&2
    exit 1
fi

# Sort by distance and keep top TOPMASH
sort -t $'\t' -k3 -g "$RESULTS_1_MASH" | head -n $TOPMASH > "$RESULTS_1_MASH_TOP" || true
echo "Top $TOPMASH results saved: $RESULTS_1_MASH_TOP"

# Formatted output of initial results
echo ""
echo "=== MASH preliminary results: $TOPMASH closest RefSeq reference genomes for \"$(basename "$FASTA_FILE")\" ==="
echo "--------------------------------------------------------------------------------------------------------------"
{
    printf "Organism\tAccession\tMash distance\tP-value\tShared hashes\n"

while IFS=$'\t' read -r ref_file query mash_dist p_value shared_hashes; do
    base=$(basename "$ref_file")

    # Extract accession
    accession=$(extract_accession "$base")

    # Extract species name from filename by removing accession suffix (GCA/GCF) and replacing underscores with spaces
    species=$(extract_species_from_filename "$base")

    # If first word is "Candidatus", replace with full taxon name from NCBI
    if [[ "${species%% *}" == "Candidatus" ]]; then
        species=$(get_taxon_name "$accession")
    fi

    printf "%s\t%s\t%.7f\t%s\t%s\n" \
        "$species" "$accession" "$mash_dist" "$p_value" "$shared_hashes"
done < "$RESULTS_1_MASH_TOP"

} | column -t -s $'\t'

# ============================================
# STEP 2: Compute ANI for top-mash genomes
# ============================================
echo ""
if [[ "$REF_OR_TYPE" == "from-type" ]]; then
    REFERENCE="type strain"
else
    REFERENCE="reference"
fi
log_step "[2/6] Downloading TOP $TOPMASH $REFERENCE genomes from NCBI and computing FastANI..."

# Filter MASH results by number of shared hashes
# Keep only hits with ≥$MIN_HASHES shared hashes (required for reliable FastANI)

# Create file with filtered TOP-MASH results:
RESULTS_1_MASH_TOP_FILTERED="$OUTPUT/1_results_mash_top_${TOPMASH}_filtered.txt"
> "$RESULTS_1_MASH_TOP_FILTERED"

# Parse original TOP-MASH table line by line
while IFS=$'\t' read -r ref_file query mash_dist p_value shared_hashes; do

    # Skip empty lines (safety)
    [[ -z "$ref_file" ]] && continue

    # Extract number of shared hashes (value before "/")
    shared_num=$(echo "$shared_hashes" | cut -d'/' -f1)

    # Skip weak matches (<$MIN_HASHES shared hashes)
    if [[ -z "${shared_num:-}" || "${shared_num}" -lt "$MIN_HASHES" ]]; then
        base=$(basename "$ref_file")
        accession=$(extract_accession "$base")
        # Derive species name from filename
        species=$(extract_species_from_filename "$base")

        # Log skipped entries (stderr)
        echo "  Skipping for FastANI: $species ($accession) → $shared_hashes shared hashes" >&2
        continue
    fi

    # Keep valid hits (≥$MIN_HASHES shared hashes) → write to filtered file
    echo -e "$ref_file\t$query\t$mash_dist\t$p_value\t$shared_hashes"

done < "$RESULTS_1_MASH_TOP" > "$RESULTS_1_MASH_TOP_FILTERED"

# Fail if no Mash hits pass the minimum shared-hash threshold (no reliable reference genomes found)
if [ ! -s "$RESULTS_1_MASH_TOP_FILTERED" ]; then
    echo ""
    echo "ERROR: No suitable reference genomes found after filtering Mash results."
    echo "All hits had fewer than ${MIN_HASHES} shared hashes."
    echo "Possible reasons:"
    echo "  - Genome is too distant from RefSeq entries"
    echo "  - Assembly is too fragmented"
    echo "  - Database mismatch"
    exit 1
fi

mkdir -p "$RESULTS_1_DIR"
> "$RESULTS_1_REF_LIST"

# Clear (or create) the species list file
> "$SPECIES_LIST"

#-----------------------------------------------------------------------
# Extract species names from MASH results ($RESULTS_1_MASH_TOP_FILTERED)
#-----------------------------------------------------------------------
# Clear (or create) output file
> "$SPECIES_LIST"

echo ""
for ((i=1; i<=TOPMASH; i++)); do
    line=$(sed -n "${i}p" "$RESULTS_1_MASH_TOP_FILTERED")
    [ -z "$line" ] && continue

    ref_path=$(echo "$line" | cut -f1)
    ref_name=$(basename "$ref_path")

    # Derive species label from filename by removing accession and replacing underscores with spaces
    species=$(extract_species_from_filename "$ref_name")

    # Override if Candidatus
    if [[ "$ref_name" == Candidatus* ]]; then
        accession=$(extract_accession "$ref_name")
        species=$(get_taxon_name "$accession")
    fi

    if [ -n "$species" ]; then
        echo "$species" >> "$SPECIES_LIST"
        echo "  File: $ref_name → Species: $species" >> "$LOG_FILE"
    else
        echo "  WARNING: failed to extract species from $ref_name" >> "$LOG_FILE"
    fi
done

# Remove duplicate species entries and normalize order
sort -u "$SPECIES_LIST" -o "$SPECIES_LIST"

# Remove temporary filtered MASH results file if it exists.
rm -f "${RESULTS_1_MASH_TOP_FILTERED:-}"

# Check that the list is not empty
if [ ! -s "$SPECIES_LIST" ]; then
    echo "ERROR: species list is empty"
    echo "First lines of input file:"
    head "$RESULTS_1_MASH_TOP"
    exit 1
fi

# Show final species list
echo "Selected species:"
sed 's/^/    /' "$SPECIES_LIST"

# Sequential processing of all species
while read -r species; do
    if [ -n "$species" ]; then
        download_and_rehydrate "$species" "--$REF_OR_TYPE" "$RESULTS_1_DIR" "--no-progressbar" || exit 1
    fi
done < "$SPECIES_LIST"

# Count downloaded genome files (search recursively in subdirectories)
GENOME_COUNT=$(find "$RESULTS_1_DIR" -follow -name "*.fna" -type f | wc -l)
echo ""
echo "Total downloaded genomes: $GENOME_COUNT"

# Fail if no genomes were downloaded
if [ "${GENOME_COUNT:-0}" -eq 0 ]; then
    echo "ERROR: no genomes were downloaded"
    exit 1
fi

# Build deduplicated reference list for FastANI (GCF preferred over GCA)
build_genome_list "$RESULTS_1_DIR" "$RESULTS_1_REF_LIST"

if [ ! -s "$RESULTS_1_REF_LIST" ]; then
    echo "ERROR: reference list is empty"
    exit 1
fi

# echo "Reference list created: $RESULTS_1_REF_LIST"
# wc -l "$RESULTS_1_REF_LIST"

# Run FastANI
echo ""
log_step "Running FastANI on TOP $TOPMASH genomes..."

"${Path_fastani}fastANI" \
    -q "$FASTA_FILE" \
    --rl "$RESULTS_1_REF_LIST" \
    -o "$RESULTS_1_FASTANI_TOP" >> "$LOG_FILE" 2>&1

if [ $? -ne 0 ]; then
    echo "  ERROR: FastANI failed for $TOPMASH genomes"
    exit 1
fi

log_step "FastANI results saved: $RESULTS_1_FASTANI_TOP"

# Format FastANI output (species, accession, ANI, alignment) and save to TSV
echo ""
echo "=== ANI for \"$(basename "$FASTA_FILE")\" (Query genome vs $REFERENCE genomes) ==="
load_assembly_data "$RESULTS_1_DIR"
format_fastani_results "$RESULTS_1_FASTANI_TOP" "$OUTPUT/1_results_fastani.tsv"

#Conclusion section
echo ""
echo "######################## Conclusion ########################"

if [ ! -s "$RESULTS_1_FASTANI_TOP" ]; then
    echo " No results found."
else
    # Read first (assumed best) hit
    if ! read -r query ref ani matched total < "$RESULTS_1_FASTANI_TOP"; then
        echo " No results found."
    elif [ -z "${ani:-}" ]; then
        echo " No results found."
    elif awk -v a="$ani" 'BEGIN{exit !(a >= 95)}'; then # Species threshold: ANI ≥ 95% is commonly used to define same species

        accession=$(extract_accession "$ref")
        data="${ASSEMBLY_DATA[$accession]:-}"

        if [ -n "$data" ]; then
            IFS=$'\t' read -r assembly_level species taxid <<< "$data"
        else
            species=" Unknown_species"
        fi
        # Extract canonical binomial name (Genus + species), removing strain/subspecies annotations
        short_species=$(echo "$species" | awk '{if (NF>=2) print $1, $2; else print $0}')
        echo " $(basename "$FASTA_FILE") belongs to the species \"$short_species\""

    else
        echo " Congratulations! You have discovered a new species!"
        echo " ANI < 95% suggests a potential novel species (DOI: 10.1099/ijs.0.64483-0)."
    fi

    echo "############################################################"
fi

# Skip downstream species-level analysis when NEIGHBORS=0 (RefSeq + ANI only mode)
if [[ "${NEIGHBORS:-0}" -eq 0 ]]; then
    echo "Skipping downstream analysis (NEIGHBORS=0)"
    echo "========================================="
    log_step "NEIGHBORS=0 → RefSeq-only analysis completed (GenBank species-level step skipped)!"
    echo "Results saved in: $OUTPUT"
    echo "  - Initial Mash results (top $TOPMASH hits): $RESULTS_1_MASH_TOP"
    echo "  - Initial FastANI results (top $TOPMASH hits): $RESULTS_1_FASTANI_TOP"
    echo "========================================="
    echo "End time: $(date '+%Y-%m-%d %H:%M:%S')" >> "$LOG_FILE"
    exit 0
fi


# ============================================
# STEP 3: Extract closest species
# ============================================
echo ""
log_step "[3/6] Selecting related species for in-depth analysis..."

# Clear species list
> "$SPECIES_LIST"

# 1. Take species from FastANI results
FASTANI_COUNT=0

while IFS=$'\t' read -r query ref ani matched total; do

    # Stop when enough neighbors collected
    [[ "$FASTANI_COUNT" -ge "$NEIGHBORS" ]] && break

    # Extract accession
    accession=$(extract_accession "$ref")

    # Get species from ASSEMBLY_DATA
    data="${ASSEMBLY_DATA[$accession]:-}"

    if [ -n "$data" ]; then
        IFS=$'\t' read -r _ species taxid <<< "$data"
        # Keep only canonical species name (Genus species)
        species=$(echo "$species" | awk '{print $1, $2}')
    else
        species="Unknown_species"
        taxid=""
    fi

    # Skip invalid entries
    [[ -z "$species" || "$species" == "Unknown_species" ]] && continue
    [[ -z "${taxid:-}" || "$taxid" == "NA" ]] && continue

    if add_species_to_list "$species" "$taxid" "[FastANI]"; then
        FASTANI_COUNT=$((FASTANI_COUNT + 1))
    fi

done < "$RESULTS_1_FASTANI_TOP"

# 2. If not enough species → add from MASH results
if [[ "$FASTANI_COUNT" -lt "$NEIGHBORS" ]]; then
    while IFS=$'\t' read -r ref_file query mash_dist p_value shared_hashes; do

        # Stop when enough neighbors collected
        [[ "$FASTANI_COUNT" -ge "$NEIGHBORS" ]] && break

        ref_name=$(basename "$ref_file")

        # Extract accession
        accession=$(extract_accession "$ref_name")

        # Get metadata from ASSEMBLY_DATA
        data="${ASSEMBLY_DATA[$accession]:-}"

        if [[ -n "$data" ]]; then
            IFS=$'\t' read -r _ species taxid <<< "$data"
        else
            # Fallback: derive from filename
            species=$(extract_species_from_filename "$ref_name")
            taxid=""
        fi

        # Resolve Candidatus only if no metadata
        if [[ "$ref_name" == Candidatus* && -z "$data" ]]; then
            species=$(get_taxon_name "$accession")
        fi

        [[ -z "$species" ]] && continue

        # Canonical species name (Genus species OR Candidatus Genus species)
        if [[ "$species" == Candidatus* ]]; then
            species=$(echo "$species" | awk '{print $1, $2, $3}')
        else
            species=$(echo "$species" | awk '{print $1, $2}')
        fi

        # If taxid is missing, query NCBI
        if [[ -z "$taxid" || "$taxid" == "NA" ]]; then
            echo "Taxid missing, querying datasets for '$species'" >> "$LOG_FILE"
            taxid=$(
                datasets_query 60 3 summary taxonomy taxon "$species" \
                | jq -r '.reports[0].taxonomy.classification.species.id // .reports[0].taxonomy.tax_id // empty'
            )
            echo "   → datasets returned taxid=$taxid" >> "$LOG_FILE"
        fi

        [[ -z "$taxid" ]] && taxid=""

        # Add species only if it was not skipped by add_species_to_list()
        # (i.e. function returned 0). Only then update log and counter.
        if add_species_to_list "$species" "$taxid" "[MASH fallback]"; then
            FASTANI_COUNT=$((FASTANI_COUNT + 1))
        fi

    done < "$RESULTS_1_MASH_TOP"

fi

# Remove duplicates and normalize order
sort -u "$SPECIES_LIST" -o "$SPECIES_LIST"

# If a whole-genus entry (single-word name) exists, remove all other entries
# for that genus (species, Candidatus species, and NO_RANK children) — already covered.
awk -F'\t' '
    function get_genus(name,    w, n) {
        n = split(name, w, " ")
        if (w[1] == "Candidatus" && n >= 2)
            return w[2]
        return w[1]
    }
    NR==FNR {
        if ($1 !~ / /) genus_set[$1] = 1
        next
    }
    {
        g = get_genus($1)
        if ($1 !~ / / || !genus_set[g])
            print
    }
' "$SPECIES_LIST" "$SPECIES_LIST" > "$OUTPUT/tmp_species" && mv "$OUTPUT/tmp_species" "$SPECIES_LIST"

# Sort: canonical species (Genus species or Candidatus Genus species) first,
# then all NO_RANK / unclassified / environmental entries alphabetically
awk -F'\t' '{
    n = split($1, w, " ")
    if ((n == 2) || (n == 3 && w[1] == "Candidatus"))
        key = 1
    else
        key = 2
    print key "\t" $0
}' "$SPECIES_LIST" \
| sort -k1,1n -k2,2 \
| cut -f2- > "$OUTPUT/tmp_species" && mv "$OUTPUT/tmp_species" "$SPECIES_LIST"

# Validate
if [ ! -s "$SPECIES_LIST" ]; then
    echo "ERROR: species list is empty"
    exit 1
fi

# Show final species list
echo ""
echo "Selected species (taxId):"

while IFS=$'\t' read -r name taxid; do
    if [[ \
        "$name" == unclassified* || \
        "$name" == environmental\ samples* || \
        "$name" == *"incertae sedis"* \
    ]]; then
        printf "  + %s\t%s\n" "$name" "$taxid"
    else
        printf " %s\t%s\n" "$name" "$taxid"
    fi
done < "$SPECIES_LIST"

# ============================================
# STEP 4: Download and rehydrate genomes (sequentially)
# ============================================
echo ""
log_step "[4/6] Downloading selected species genomes..."

mkdir -p "$RESULTS_2_DIR"


# Sequential processing of all species
while IFS=$'\t' read -r species taxid; do
    [ -z "$taxid" ] && continue
    download_and_rehydrate "$taxid" "" "$RESULTS_2_DIR" "" "$species" || exit 1
done < "$SPECIES_LIST"

# Count downloaded genome files (search recursively in subdirectories)
GENOME_COUNT=$(find "$RESULTS_2_DIR" -follow -name "*.fna" -type f | wc -l)
echo ""
echo "Total downloaded genomes: $GENOME_COUNT"

# Fail if no genomes were downloaded
if [ $GENOME_COUNT -eq 0 ]; then
    echo "ERROR: no genomes were downloaded"
    exit 1
fi

# Build deduplicated genome list for Mash sketch (GCF preferred over GCA)
build_genome_list "$RESULTS_2_DIR" "$RESULTS_2_GENOME_LIST"

if [ ! -s "$RESULTS_2_GENOME_LIST" ]; then
    echo "  ERROR: genome list is empty"
    exit 1
fi


# ============================================
# STEP 5: Build species-specific MASH database and run final comparison
# ============================================
echo ""
log_step "[5/6] Building species-specific MASH database and running comparison..."

# Create MASH sketch database from all downloaded genomes
CUSTOM_DB="$OUTPUT/species_db.msh"

if [ ! -s "$RESULTS_2_GENOME_LIST" ]; then
    echo "  ERROR: genome list is empty"
    exit 1
fi

# Build Mash sketch database from deduplicated genome list
genome_count=$(wc -l < "$RESULTS_2_GENOME_LIST")
echo "  Creating MASH database from $genome_count genomes..."
"${Path_mash}mash" sketch \
    -o "$CUSTOM_DB" \
    -p "$(nproc)" \
    -l "$RESULTS_2_GENOME_LIST" >> "$LOG_FILE" 2>&1

echo "  Database created: $CUSTOM_DB"

# Validate number of sketches in Mash database
# (exclude header/comment lines starting with '#')
db_count=$("${Path_mash}mash" info -t "$CUSTOM_DB" | grep -vc '^#')

echo "  Mash database contains $db_count sketches"

if [ "$db_count" -ne "$genome_count" ]; then
    echo "  WARNING: genome count mismatch!"
    echo "           Expected: $genome_count genomes"
    echo "           Found in Mash DB: $db_count sketches"
fi

# Compare query genome against custom MASH database
echo ""
log_step "Comparing query genome against custom MASH database..."
"${Path_mash}mash" dist "$CUSTOM_DB" "$SKETCH_FILE" > "$RESULTS_2_MASH"

if [ $? -ne 0 ]; then
    echo "  ERROR: failed to compare with custom database."
    exit 1
fi

# Sort results and keep top TOPANI hits
log_step "Sorting Mash results..."
sort -t $'\t' -k3 -g "$RESULTS_2_MASH" | head -n $TOPANI > "$RESULTS_2_MASH_TOP" || true

# Fast metadata loading (no taxonomy normalization needed here)
load_assembly_data "$RESULTS_2_DIR" --no-taxid
log_step "Done" >> "$LOG_FILE" 

# Formatted output of final MASH results
echo ""
echo "=== MASH final results: $TOPANI closest genomes from GenBank for \"$(basename "$FASTA_FILE")\" ==="
echo "--------------------------------------------------------------------------------------------------------------"
{
    # Table header
    printf "Organism\tAccession|Assembly level\tMash distance\tP-value\tShared hashes\n"

    # Process each line from RESULTS_2_MASH_TOP results
    # Format: ref_file \t query \t distance \t p-value \t hashes
    while IFS=$'\t' read -r ref_file query mash_dist p_value shared_hashes; do

        # Extract accession from reference filename
        accession=$(extract_accession "$ref_file")
        [ -z "$accession" ] && accession="NA"

        # Retrieve assembly data from ASSEMBLY_DATA
        # Stored format: "assembly_level<TAB>species"
        data="${ASSEMBLY_DATA[$accession]}"

        if [ -n "$data" ]; then
            IFS=$'\t' read -r assembly_level species taxid <<< "$data"
        else
            assembly_level="Unknown"
            species="Unknown_species"
        fi

        # MAG labeling
        header=$(grep -m1 "^>" "$ref_file" 2>/dev/null || true)

        if echo "$header" | grep -Eqi '\bMAG\b|metagenome'; then
                species="(MAG) $species"
        fi

        # Print formatted row
        printf "%s\t%s\t%.7f\t%s\t%s\n" \
            "$species" \
            "$accession|$assembly_level" \
            "$mash_dist" \
            "$p_value" \
            "$shared_hashes"

    done < "$RESULTS_2_MASH_TOP"

} | tee "$OUTPUT/2_results_mash_top_$TOPANI.tsv" | column -t -s $'\t'

# ============================================
# STEP 6: Compute Average Nucleotide Identity (ANI) using FastANI
# ============================================
echo ""
log_step "[6/6] Computing Average Nucleotide Identity using FastANI..."

# Extract reference genome paths (first column from RESULTS_2_MASH_TOP)
cut -f1 "$RESULTS_2_MASH_TOP" > "$RESULTS_2_REF_LIST"

# Validate reference list
if [ ! -s "$RESULTS_2_REF_LIST" ]; then
    echo "  ERROR: reference list is empty"
    exit 1
fi

echo "  Running FastANI..."

# Run FastANI (query vs reference list)
"${Path_fastani}fastANI" \
    -q "$FASTA_FILE" \
    --rl "$RESULTS_2_REF_LIST" \
    -o "$RESULTS_2_FASTANI" >> "$LOG_FILE" 2>&1

# Check execution status
if [ $? -ne 0 ]; then
    echo "  ERROR: FastANI execution failed"
    exit 1
fi

echo "  FastANI completed successfully: $RESULTS_2_FASTANI"

echo ""
echo "=== ANI for \"$(basename "$FASTA_FILE")\" (Query genome vs GenBank Reference) ==="

# Format FastANI output (species, accession, ANI, alignment) and save to TSV
format_fastani_results "$RESULTS_2_FASTANI" "$OUTPUT/2_results_fastani.tsv"

# ============================================
# End of analysis
# ============================================

# If KEEP_ONLY_RESULTS is explicitly set to true, remove intermediate genome directories and Mash sketches, keeping only analysis outputs
if [ "${KEEP_ONLY_RESULTS:-}" = "true" ]; then

    rm -rf "$RESULTS_1_DIR"

    # Remove only local entries inside RESULTS_2_DIR.
    # Symlinks are removed safely without touching original cache directories.
    if [[ -d "$RESULTS_2_DIR" ]]; then
        find "$RESULTS_2_DIR" -mindepth 1 -maxdepth 1 -exec rm -rf {} +
        rmdir "$RESULTS_2_DIR" 2>/dev/null || true
    fi

    rm -f "$SKETCH_FILE" "$CUSTOM_DB" "$SPECIES_LIST" "$RESULTS_2_GENOME_LIST"

    echo "" >> "$LOG_FILE"
    echo "KEEP_ONLY_RESULTS=true → removed:" >> "$LOG_FILE"
    echo "  - $RESULTS_1_DIR" >> "$LOG_FILE"
    echo "  - contents of $RESULTS_2_DIR" >> "$LOG_FILE"
    echo "  - $SKETCH_FILE" >> "$LOG_FILE"
    echo "  - $CUSTOM_DB" >> "$LOG_FILE"
    echo "  - $SPECIES_LIST" >> "$LOG_FILE"
    echo "  - $RESULTS_2_GENOME_LIST" >> "$LOG_FILE"
fi

echo ""
echo "========================================="
log_step "Analysis completed!"

echo "Results saved in: $OUTPUT"
echo "  - Initial Mash results (top $TOPMASH hits): $RESULTS_1_MASH_TOP"
echo "  - Initial FastANI results (top $TOPMASH hits): $RESULTS_1_FASTANI_TOP"
echo "  - Final Mash results (top $TOPANI hits): $RESULTS_2_MASH_TOP"
echo "  - Final FastANI results: $RESULTS_2_FASTANI"
echo "========================================="
echo "End time: $(date '+%Y-%m-%d %H:%M:%S')" >> "$LOG_FILE"
