#!/usr/bin/env bash
set -euo pipefail

BASE_DIR="./output_pipeline"
PARSE_SCRIPT="./parse_runlog.py"

if [[ ! -d "$BASE_DIR" ]]; then
    echo "Errore: directory ${BASE_DIR} non trovata (lancia lo script dalla dir che contiene output_pipeline/)" >&2
    exit 1
fi

if [[ ! -f "$PARSE_SCRIPT" ]]; then
    echo "Errore: script ${PARSE_SCRIPT} non trovato (mettilo nella stessa dir di questo script)." >&2
    exit 1
fi

for dir in "${BASE_DIR}"/*/; do
    dir_name="$(basename "$dir")"

    # --- cerca DAT e CM ---
    shopt -s nullglob
    dat_files=( "$dir"/htsim_logout_*.dat )
    cm_files=( "$dir"/*.cm )
    shopt -u nullglob

    if (( ${#dat_files[@]} == 0 )); then
        echo "Nessun htsim_logout_*.dat in ${dir_name}, salto."
        continue
    fi
    if (( ${#cm_files[@]} == 0 )); then
        echo "Nessun .cm in ${dir_name}, salto."
        continue
    fi

    if (( ${#dat_files[@]} > 1 )); then
        echo "Attenzione: più file .dat in ${dir_name}, uso il primo: ${dat_files[0]}" >&2
    fi
    if (( ${#cm_files[@]} > 1 )); then
        echo "Attenzione: più file .cm in ${dir_name}, uso il primo: ${cm_files[0]}" >&2
    fi

    dat_file="${dat_files[0]}"
    cm_file="${cm_files[0]}"

    # --- parse parametri da nome directory ---
    nodes=""
    num_chunks=""
    chunk_size=""

    if [[ "$dir_name" == groups* ]]; then
        # es: groups3_spine4_leaf4_host4_chunks1_size8192
        if [[ "$dir_name" =~ groups([0-9]+)_spine([0-9]+)_leaf([0-9]+)_host([0-9]+)_chunks([0-9]+)_size([0-9]+) ]]; then
            groups="${BASH_REMATCH[1]}"
            leaf="${BASH_REMATCH[3]}"
            host="${BASH_REMATCH[4]}"
            num_chunks="${BASH_REMATCH[5]}"
            chunk_size="${BASH_REMATCH[6]}"
            nodes=$(( groups * leaf * host ))
        else
            echo "Impossibile parsare (groups*): ${dir_name}, salto." >&2
            continue
        fi
    elif [[ "$dir_name" == mpi_* ]]; then
        # es: mpi_bine_host64_chunks1_size8192
        if [[ "$dir_name" =~ host([0-9]+)_chunks([0-9]+)_size([0-9]+) ]]; then
            nodes="${BASH_REMATCH[1]}"
            num_chunks="${BASH_REMATCH[2]}"
            chunk_size="${BASH_REMATCH[3]}"
        else
            echo "Impossibile parsare (mpi_*): ${dir_name}, salto." >&2
            continue
        fi
    else
        echo "Directory non riconosciuta (né groups* né mpi_*): ${dir_name}, salto."
        continue
    fi

    # --- costruzione nomi output ---
    plots_dir="${dir}/plots"
    mkdir -p "${plots_dir}"

    out_csv="${dir}/flows_with_deps_host${nodes}_chunks${num_chunks}_size${chunk_size}.csv"
    out_summary="${dir}/summary_host${nodes}_chunks${num_chunks}_size${chunk_size}.txt"
    out_dot="${dir}/deps_host${nodes}_chunks${num_chunks}_size${chunk_size}.dot"

    echo "=== parse_runlog per ${dir_name} ==="
    echo "  dat        : ${dat_file}"
    echo "  cm         : ${cm_file}"
    echo "  n-hosts    : ${nodes}"
    echo "  num-chunks : ${num_chunks}"
    echo "  chunk-size : ${chunk_size} byte"
    echo "  out-csv    : ${out_csv}"
    echo "  out-summary: ${out_summary}"
    echo "  out-dot    : ${out_dot}"
    echo "  plots-dir  : ${plots_dir}"
    echo

    python3 "${PARSE_SCRIPT}" \
        "${dat_file}" \
        --cmfile "${cm_file}" \
        --n-hosts "${nodes}" \
        --num-chunks "${num_chunks}" \
        --chunk-size-byte "${chunk_size}" \
        --unit-finish us \
        --unit-start us \
        --out-csv "${out_csv}" \
        --out-summary "${out_summary}" \
        --out-dot "${out_dot}" \
        --plots-dir "${plots_dir}" \
        --gantt-max-flows 200

    echo "Completato: ${dir_name}"
    echo
done

echo "Tutti i parse_runlog sono terminati."