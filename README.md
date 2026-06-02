# Mashania

**Mashania** *(Mash + ANI analysis)* is a prokaryotic genome analysis pipeline designed to identify prokaryotic organisms based on whole-genome sequences and to find their closest currently available relatives in GenBank.

The workflow combines rapid genome screening with Mash and high-resolution Average Nucleotide Identity (ANI) calculations using FastANI. Unlike approaches that rely solely on RefSeq reference genomes, Mashania performs a second-stage targeted search across all available assemblies within the closest taxonomic neighborhood, including draft genomes, metagenome-assembled genomes (MAGs), environmental assemblies, and other non-reference datasets available through GenBank.

The tool is intended for microbial genomics, taxonomy, genome quality assessment, and the characterization of potentially novel species.

## Contents

- [Features](#features)
- [Scientific Background](#scientific-background)
- [Workflow](#workflow)
- [Dependencies](#dependencies)
- [Installation](#installation)
- [Mash Database](#mash-database)
- [Usage](#usage)
- [Command Line Options](#command-line-options)
- [Output Files](#output-files)
- [Interpretation of Results](#interpretation-of-results)
- [Typical Applications](#typical-applications)
- [Citation](#citation)

---

## Features

* Identification of prokaryotic organisms from whole-genome sequences.
* Species assignment based on Average Nucleotide Identity (ANI).
* Detection of potentially novel species (maximum ANI < 95%).
* Two-stage search strategy:

  * Initial screening against a Mash database of representative RefSeq genomes (reference or type assemblies).
  * Species-level genome retrieval from GenBank followed by refined Mash and FastANI comparisons.
* Automatic retrieval of genomes from NCBI.
* Support for:

  * complete genomes,
  * chromosome-level assemblies,
  * scaffold assemblies,
  * contig assemblies,
  * MAGs (Metagenome-Assembled Genomes).
* Automatic handling of ambiguous taxonomic names.
* Taxonomic expansion using closely related species.
* Detection of environmental and unclassified genomic groups.
* Local genome cache reuse between runs.
* Detailed logging and reproducible workflows.
* Optional cleanup mode for storage-efficient execution.

---

## Scientific Background

Average Nucleotide Identity (ANI) is currently the most widely accepted genomic criterion for prokaryotic species delineation.

A threshold of approximately **95% ANI** is commonly used to define species boundaries.

**References**

1. Goris J, Konstantinidis KT, Klappenbach JA, Coenye T, Vandamme P, Tiedje JM. DNA-DNA hybridization values and their relationship to whole-genome sequence similarities. Int J Syst Evol Microbiol. 2007 Jan;57(Pt 1):81-91. doi: 10.1099/ijs.0.64483-0. PMID: 17220447.

2. Jain C, Rodriguez-R LM, Phillippy AM, Konstantinidis KT, Aluru S. High throughput ANI analysis of 90K prokaryotic genomes reveals clear species boundaries. Nat Commun. 2018 Nov 30;9(1):5114. doi: 10.1038/s41467-018-07641-9. PMID: 30504855; PMCID: PMC6269478.

Mashania uses ANI to:

1. Assign a query genome to a known species.

2. Detect potentially novel species.

3. Identify the closest currently available genome in public databases.

---

## Workflow

```text
Input genome
      │
      ▼
Create Mash sketch
      │
      ▼
Compare against RefSeq Mash database
      │
      ▼
Select closest RefSeq genomes
      │
      ▼
Download genomes from NCBI
      │
      ▼
FastANI analysis
      │
      ▼
Species identification
      │
      ▼
Select closest species
      │
      ▼
Download all genomes from selected taxa
      │
      ▼
Build custom Mash database
      │
      ▼
Final Mash comparison
      │
      ▼
Final FastANI analysis
      │
      ▼
Closest genome currently available in GenBank
```

---

## Dependencies

The following software must be installed:

* Mash ≥ 2.0: [https://github.com/marbl/Mash](https://github.com/marbl/Mash);
* FastANI ≥ 1.3: [https://github.com/ParBLiSS/FastANI](https://github.com/ParBLiSS/FastANI);
* NCBI Datasets CLI: [https://www.ncbi.nlm.nih.gov/datasets/docs/v2/download-and-install](https://www.ncbi.nlm.nih.gov/datasets/docs/v2/download-and-install);
* jq [https://jqlang.org](https://jqlang.org);
* GNU unzip (usually available via system package manager, e.g. `sudo apt install unzip`).

---

## Installation

Clone the repository:

```bash
git clone https://github.com/USERNAME/Mashania.git
cd Mashania
```

Download or install the required dependencies.

Mashania automatically searches for required executables (`mash`, `fastANI`, and `datasets`) in the following order:

1. System `PATH`.
2. The directory containing the `mashania.sh` script.
3. User-defined paths specified in the script:

```bash
Path_mash=""
Path_fastani=""
Path_ncbi_datasets=""
```

This allows Mashania to be used as a fully portable package by simply placing the required executables next to the script.


---

## Mash Database

Mashania requires a Mash sketch database for the initial screening step.

### Building a Custom Database

Users are encouraged to build and maintain their own Mash databases from RefSeq genomes. This allows:

* Inclusion of bacteria, archaea, or both.
* Use of the most up-to-date RefSeq assemblies.
* Regular database updates as new genomes become available.

Custom databases can be generated and updated using the companion script `refseq_to_mash.sh`.

Mashania can locate the database in several ways (in order of priority):

1. Explicitly specified via:

```bash
--data-base database.msh
```

2. Defined inside the script:

```bash
RefSeq_msh="/path/to/database.msh"
```

3. Placed in the same directory as the Mashania script.

### Precomputed Database

For convenience, a precomputed database containing one RefSeq reference genome for each described bacterial species can be downloaded from:

https://doi.org/10.5281/zenodo.20293962

This database is generated and maintained by Erin Young through the update_mash_dist project:

https://github.com/erinyoung/update_mash_dist

The Zenodo record may contain newer database releases. Users are encouraged to download the most recent available version.

Note that this database currently covers Bacteria only.

---

## Usage

### Basic usage

```bash
bash Mashania.sh --fasta genome.fasta
```

---

### Specify output directory

```bash
bash Mashania.sh \
    --fasta genome.fasta \
    --output results
```

---

### RefSeq-only identification

```bash
bash Mashania.sh \
    --fasta genome.fasta \
    --neighbors 0
```

This mode performs:

* RefSeq Mash screening
* FastANI species identification

and skips the GenBank neighborhood analysis.

---

### Deep GenBank search

```bash
bash Mashania.sh \
    --fasta genome.fasta \
    --neighbors 5
```

This mode searches additional related taxa and identifies the closest genome currently available in GenBank.

---

### Reuse genomes from previous runs

```bash
bash Mashania.sh \
    --fasta genome.fasta \
    --cache-dir previous_run
```

Multiple cache directories may be specified:

```bash
bash Mashania.sh \
    --fasta genome.fasta \
    --cache-dir run1 \
    --cache-dir run2 \
    --cache-dir run3
```

---

### Keep only final results

```bash
bash Mashania.sh \
    --fasta genome.fasta \
    --keep-results-only
```

### Find out Mashania version

```bash
bash Mashania.sh --help
```


If `--keep-results-only` is specified, the downloaded genomes, Mash sketches, and intermediate databases will be removed after the analysis completes.

---

## Command Line Options

| Option                              | Description                                                                                                                                                                         |
| ----------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `--fasta`                             | Input FASTA genome                                                                                                                                                                  |
| `--output`                            | Output directory                                                                                                                                                                    |
| `--data-base`                         | RefSeq Mash database                                                                                                                                                                |
| `--neighbors`                         | Number of neighboring species for GenBank analysis                                                                                                                                  |
| `--top-mash`                          | Number of top Mash hits retained                                                                                                                                                    |
| `--top-ani`                           | Number of top genomes used for final ANI analysis                                                                                                                                   |
| `--min-hashes`                        | Minimum shared Mash hashes required                                                                                                                                                 |
| `--ref-or-type`                       | `reference` or `from-type`. Select genomes used for the initial RefSeq-based ANI screening: RefSeq reference genomes (`reference`, default) or genomes assembled from nomenclatural type material (`from-type`) |
| `--cache-dir`                         | Reuse genomes from previous analyses                                                                                                                                                |
| `--keep-results-only`                 | Remove intermediate files                                                                                                                                                           |
| `--help`                              | Show help                                                                                                                                                                           |


---

## Output Files

### Initial RefSeq-based search

#### 1_results_mash_top_N.txt

Top matches identified by Mash in the RefSeq reference genome database containing one representative genome per described species.

Contains:

* Mash distance
* p-value
* number of shared hashes

---

#### 1_results_fastani.tsv

FastANI results for the query genome against the closest RefSeq reference genomes (or genomes assembled from nomenclatural type material when `--ref-or-type from-type` is used).
These results are used for preliminary species assignment and selection of neighboring taxa for downstream analysis.

Also used for species identification.

---

### GenBank neighborhood search

#### 2_results_mash_top_N.tsv

Top genomes identified from the custom species-level GenBank database.

Contains:

* organism name
* assembly accession
* assembly level
* Mash distance
* shared hashes

---

#### 2_results_fastani.tsv

Final ANI analysis against the closest GenBank genomes.

This file contains the primary result of the pipeline.

---

#### run.log

Complete execution log including:

* software versions,
* execution parameters,
* download information,
* taxonomy resolution,
* warnings,
* timing information.

---

## Result Interpretation

### ANI ≥ 95%

The query genome most likely belongs to an already described species.

Example:

```text
ANI = 98.7%
```

Strong evidence that both the query and the reference belong to the same species.

---

### ANI < 95%

The query genome may represent a novel species.

Example:

```text
ANI = 91.2%
```

This result should be investigated further using phylogenomic and taxonomic analyses.

---

## Typical Applications

* Taxonomic identification of prokaryotic organisms using whole-genome comparisons.
* Validation of isolate identity.
* Discovery of potentially novel species.
* Selection of reference genomes.
* Comparative genomics.
* MAG characterization.
* Genome quality control.
* Microbial systematics and taxonomy.

---

## Citation

If you use Mashania in published work, please cite the software on which it depends:

### Mash

Ondov B.D. et al. Mash: fast genome and metagenome distance estimation using MinHash. Genome Biol. 2016 Jun 20;17(1):132. DOI: [10.1186/s13059-016-0997-x](https://doi.org/10.1186/s13059-016-0997-x). PMID: [27323842](https://pubmed.ncbi.nlm.nih.gov/27323842/); PMCID: [PMC4915045](https://pmc.ncbi.nlm.nih.gov/articles/PMC4915045/).

### FastANI

Jain C. et al. High throughput ANI analysis of 90K prokaryotic genomes reveals clear species boundaries. Nat Commun. 2018 Nov 30;9(1):5114. DOI: [10.1038/s41467-018-07641-9](https://doi.org/10.1038/s41467-018-07641-9). PMID: [30504855](https://pubmed.ncbi.nlm.nih.gov/30504855/); PMCID: [PMC6269478](https://pmc.ncbi.nlm.nih.gov/articles/PMC6269478/).

### NCBI Datasets

O’Leary N.A. et al. Exploring and retrieving sequence and metadata for species across the tree of life with NCBI Datasets. Sci Data. 2024 Jul 5;11(1):732. DOI: [10.1038/s41597-024-03571-y](https://doi.org/10.1038/s41597-024-03571-y). PMID: [38969627](https://pubmed.ncbi.nlm.nih.gov/38969627/); PMCID: [PMC11226681](https://pmc.ncbi.nlm.nih.gov/articles/PMC11226681/).
