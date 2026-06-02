# `refseq_to_mash.sh` — Database Builder Utility for Mashania

`refseq_to_mash.sh` is a companion Bash script for building and maintaining a Mash sketch database from NCBI RefSeq species-level reference genome assemblies. It is designed to keep the database up-to-date as RefSeq evolves, handling new genomes, taxonomic renames, and accession version changes automatically.

## Contents

- [Dependencies](#dependencies)
- [Usage](#usage)
- [Output Directory Structure](#output-directory-structure)
- [Operating Modes](#operating-modes)
- [Consistency Checks](#consistency-checks)
- [Log Files](#log-files)
- [Limitations](#limitations)

## Dependencies

| Tool | Source |
|------|--------|
| [NCBI Datasets CLI](https://www.ncbi.nlm.nih.gov/datasets/docs/v2/download-and-install/) (`datasets` and `dataformat`) | https://ftp.ncbi.nlm.nih.gov/pub/datasets/command-line/LATEST/linux-amd64/ |
| [Mash](https://github.com/marbl/Mash/releases) (v2.0 or later) | https://github.com/marbl/Mash/releases |
| `unzip` | Available via system package manager (e.g. `sudo apt install unzip`) |

Both `datasets`/`dataformat` and `mash` can either be placed in the same directory as the script, added to `$PATH`, or their locations specified directly in the script header:

```bash
Path_ncbi_datasets="/path/to/ncbi-datasets-cli/"
Path_mash="/path/to/mash/"
```

## Usage

```bash
bash refseq_to_mash.sh [options]
```
```text
Options:
  -o, --workdir    Output directory (default: ./RefSeqSketches)
  -d, --domain     Taxonomic domain: bacteria, archaea, or both (default: bacteria)
  -h, --help       Show help message and exit
```

**Examples:**

```bash
# Build a bacterial database in the default directory
bash refseq_to_mash.sh

# Build a database covering both bacteria and archaea
bash refseq_to_mash.sh -o /data/mash_db -d both

# Build an archaeal-only database
bash refseq_to_mash.sh -o /data/mash_archaea -d archaea
```

## Output Directory Structure

All output is written to the output directory (default: `./RefSeqSketches`):

```text
RefSeqSketches/
├── sketches/                                  # Individual .msh sketch per genome
│   ├── Escherichia_coli_GCF_000005845.2.msh
│   └── ...
├── ids_2026-06-02_08-29.txt                   # Genome list retrieved from NCBI
├── ids_2026-06-02_08-29_processed.txt         # Record of successfully processed genomes
├── RefSeqSketches_2026-06-02_08-29.msh        # Final Mash database
├── run.log                                    # Full run log (previous runs archived automatically)
└── error.log                                  # Error log
```

The final database file and associated metadata files are named with the run timestamp, allowing multiple database versions to coexist in the same directory.

## Operating Modes

The script automatically selects one of three operating modes on each run:

### Mode 1. New (first run)

If no previous database or processed genome list is found, the script downloads all reference genomes for the specified domain, creates individual Mash sketches, and assembles the final database. If the run is interrupted and restarted, already-created sketches are detected and skipped automatically.

### Mode 2. Incremental update

If the new genome list from NCBI is a strict superset of the previous run — meaning only new genomes have been added and no existing entries have changed — the script downloads and sketches only the new genomes and appends them to the existing database. Genomes that have been removed from RefSeq reference status are detected and their sketches deleted.

### Mode 3. Full rebuild

If any previously processed genome has changed its organism name or accession version number, the script enters rebuild mode. Only the affected sketches are deleted and re-downloaded; all other sketches are reused. The final database is then reassembled from all sketches. This process may take over two hours for a full bacterial database (~22,000 genomes).

> **Note:** The previous database file is retained on disk during a rebuild. Only after the new database has been successfully assembled does the old file become superseded (though it is not deleted automatically).

## Consistency Checks

At the end of each run, the script validates that the number of sketches in the `sketches/` directory, the number of entries in the processed list, and the number of sketches embedded in the final `.msh` file all match. A warning is written to `error.log` if any discrepancy is detected.

## Log Files

Each run produces a `run.log` containing the full execution trace, including timestamps, detected changes, and system information. If a `run.log` from a previous run already exists, it is automatically renamed to `run_<date>.log` before the new log is created. The same applies to `error.log`.

## Limitations

- Only assemblies designated as **reference genomes** in NCBI RefSeq are included (one per species). This is a small subset of all RefSeq assemblies.
- The script is sequential; parallel downloading is not currently implemented.
- Assembling the final database from ~22,000 sketches via iterative `mash paste` is time-consuming (approximately 2–3 hours). This step is required whenever a full rebuild is triggered.
