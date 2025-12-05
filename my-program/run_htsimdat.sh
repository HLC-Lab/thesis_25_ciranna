#!/usr/bin/env bash
set -euo pipefail

HTSIM_BIN="../csg-htsim/sim/datacenter/htsim_roce"
BASE_DIR="./output_pipeline"

if [[ ! -d "$BASE_DIR" ]]; then
    echo "Errore: directory ${BASE_DIR} non trovata (lancia lo script dalla dir che contiene output_pipeline/)" >&2
    exit 1
fi

for dir in "${BASE_DIR}"/*/; do
    dir_name="$(basename "$dir")"

    # Cerca file .cm nella cartella
    shopt -s nullglob
    cm_files=( "$dir"/*.cm )
    shopt -u nullglob

    if (( ${#cm_files[@]} == 0 )); then
        echo "Nessun .cm trovato in ${dir_name}, salto."
        continue
    elif (( ${#cm_files[@]} > 1 )); then
        echo "Attenzione: più di un .cm in ${dir_name}, uso il primo: ${cm_files[0]}" >&2
    fi

    cm_file="${cm_files[0]}"
    cm_base="$(basename "$cm_file" .cm)"

    # Calcola il numero di nodi
    nodes=""

    if [[ "$dir_name" == groups* ]]; then
        # pattern: groups2_spine4_leaf4_host4_chunks1_size1048576
        if [[ "$dir_name" =~ groups([0-9]+)_spine([0-9]+)_leaf([0-9]+)_host([0-9]+)_ ]]; then
            groups="${BASH_REMATCH[1]}"
            # spine="${BASH_REMATCH[2]}"   # non serve per nodes
            leaf="${BASH_REMATCH[3]}"
            host="${BASH_REMATCH[4]}"
            nodes=$(( groups * leaf * host ))
        else
            echo "Impossibile parsare dir (groups*): ${dir_name}, salto." >&2
            continue
        fi
    elif [[ "$dir_name" == mpi_* ]]; then
        # pattern: mpi_bine_host64_chunks1_size8192
        if [[ "$dir_name" =~ host([0-9]+)_ ]]; then
            nodes="${BASH_REMATCH[1]}"
        else
            echo "Impossibile trovare hostN in ${dir_name}, salto." >&2
            continue
        fi
    else
        echo "Directory non riconosciuta (né groups* né mpi_*): ${dir_name}, salto."
        continue
    fi

    out_file="${dir}/htsim_logout_${cm_base}.dat"

    echo "=== Lancio HTSIM per ${dir_name} ==="
    echo "  .cm     : ${cm_file}"
    echo "  nodes   : ${nodes}"
    echo "  output  : ${out_file}"
    echo

    "${HTSIM_BIN}" \
        -tm "${cm_file}" \
        -type Df+ \
        -nodes "${nodes}" \
        -linkspeed 200000 \
        -mtu 9000 \
        -hop_latency 1 \
        -switch_latency 0.05 \
        -queue_type lossless_input \
        -q 64 \
        -pfc_thresholds 12 15 \
        -threshold 64 \
        -strat minimal \
        -start_delta 200000 \
        -end 800000 \
        -log sink \
        -log traffic \
        -logtime 1.0 \
        > "${out_file}"

    echo "Completato: ${dir_name}"
    echo
done

echo "Tutti i lanci HTSIM sono terminati."
