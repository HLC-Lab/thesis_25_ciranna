#!/usr/bin/env bash
set -euo pipefail

# ------------------------------------------------------------
# run_pipeline.sh — TE-CCL end-to-end: teccl -> convert -> htsim -> parser
#  - Naming: include num_chunks + chunk_size (byte) + name (opzionale)
#  - Nessun prefisso "run_" nelle directory
#  - chunk_size SEMPRE interpretato in GB (decimali, 1 GB = 1e9 B)
#  - Passa a parse_runlog.py: --n-hosts, --num-chunks, --chunk-size-bytes
#  - Tutto l'output finisce sotto ./output_pipeline/ (override: --out-dir)
#  - Opzioni blocco: --topology, --convert, --htsim, --parser, --solver-time
#  - NOVITÀ: parametri TE-CCL accettano anche forma con trattino: -num_groups / --num_groups
# ------------------------------------------------------------

# --- styling ANSI (come sweep_pipeline.sh; auto-disabilitato se non TTY) ---
if [[ -t 1 ]] && command -v tput >/dev/null 2>&1; then
  if [[ $(tput colors 2>/dev/null || echo 0) -ge 8 ]]; then
    BOLD="$(tput bold)"; RESET="$(tput sgr0)"
    RED="$(tput setaf 1)"; GREEN="$(tput setaf 2)"; YELLOW="$(tput setaf 3)"
    BLUE="$(tput setaf 4)"; MAGENTA="$(tput setaf 5)"; CYAN="$(tput setaf 6)"
  else
    BOLD=""; RESET=""; RED=""; GREEN=""; YELLOW=""; BLUE=""; MAGENTA=""; CYAN=""
  fi
else
  BOLD=""; RESET=""; RED=""; GREEN=""; YELLOW=""; BLUE=""; MAGENTA=""; CYAN=""
fi

# ---- utilità base (coerenti con sweep_pipeline.sh) ----
ts() { date '+%Y-%m-%d %H:%M:%S'; }
log_info()  { echo "${BOLD}${BLUE}[INFO]${RESET} $*"; }
log_ok()    { echo "${BOLD}${GREEN}[OK]${RESET}   $*"; }
log_warn()  { echo "${BOLD}${YELLOW}[WARN]${RESET} $*"; }
log_error() { echo "${BOLD}${RED}[ERRORE]${RESET} $*" >&2; }

# ---- precondizioni ambiente ----
if ! command -v conda >/dev/null 2>&1; then
  log_error "conda non trovato nel PATH."
  exit 1
fi

CONDA_ENV="te-ccl-env"
CONDA_RUN="conda run -n ${CONDA_ENV}"
log_info "Userò ${BOLD}${CONDA_RUN}${RESET} per i comandi Python"

# --- radice output (default fisso) ---
OUT_ROOT="./output_pipeline"
# override opzionale: --out-dir <DIR> come primissimo argomento
if [[ $# -ge 2 && "${1:-}" == "--out-dir" ]]; then
  OUT_ROOT="$2"; shift 2
fi
mkdir -p "$OUT_ROOT"

(( $# > 0 )) || {
  log_info "${BOLD}Uso:${RESET}"
  cat >&2 <<USO
  $0 [--out-dir DIR]
     [--topology <path_run_topology.sh>]
     <param valore ...>                # es: num_groups 2  oppure  --num_groups 2
     [--convert <path_convertTecclSchedule>]
     [--solver-time <python> <script>] # estrae Solver_Time da schedule.json
     [--parser <python> <script> <args...>]
     --htsim <path_htsim_roce> <args...>

Note:
- Le coppie TE-CCL <param valore> devono essere in numero pari.
- I nomi parametro TE-CCL possono avere zero/uno/due trattini iniziali: num_groups / -num_groups / --num_groups.
- --topology è opzionale; se omesso usa ./run_topology.sh.
- Non passare 'schedule_output_file' (lo imposta lo script).
- In HTSIM non passare -tm/-nodes (li imposta lo script).
- --solver-time: se omesso, si prova automaticamente ./extract_solver_time.py se presente.
USO
  exit 1
}

# --- parsing ---
RUN_ARGS=()
CONVERT_BIN="./convertTecclSchedule"
HTSIM_BIN=""; HTSIM_ARGS=()
PARSER_PY="python3"; PARSER_SCRIPT="./parse_runlog.py"; PARSER_ARGS=()
TOPO_BIN="./run_topology.sh"  # opzionale: override con --topology

# Nuovi: estrazione Solver_Time
SOLVER_PY=""       # es: python3
SOLVER_SCRIPT=""   # es: ./extract_solver_time.py

# regex numero (interi/float, anche con notazione scientifica)
_is_numeric() {
  [[ "$1" =~ ^-?[0-9]+([.][0-9]+)?([eE][-+]?[0-9]+)?$ ]]
}

# normalizza i nomi parametro TE-CCL: rimuove 1 o 2 trattini iniziali
_norm_key() {
  local k="$1"
  echo "$k" | sed -E 's/^--?//'
}

while (( $# > 0 )); do
  case "${1:-}" in
    --topology)
      shift
      [[ $# -ge 1 ]] || { log_error "manca il path dopo --topology"; exit 1; }
      TOPO_BIN="$1"; shift
      ;;
    --convert)
      shift
      [[ $# -ge 1 ]] || { log_error "manca il path dopo --convert"; exit 1; }
      CONVERT_BIN="$1"; shift
      ;;
    --solver-time)
      shift
      [[ $# -ge 2 ]] || { log_error "usa: --solver-time <python> <script>"; exit 1; }
      SOLVER_PY="$1"; SOLVER_SCRIPT="$2"; shift 2
      ;;
    --htsim)
      shift
      [[ $# -ge 1 ]] || { log_error "manca il path a htsim_roce dopo --htsim"; exit 1; }
      HTSIM_BIN="$1"; shift
      while (( $# > 0 )) && [[ "$1" != "--convert" && "$1" != "--parser" && "$1" != "--topology" && "$1" != "--solver-time" && "$1" != "--out-dir" ]]; do
        HTSIM_ARGS+=("$1"); shift
      done
      ;;
    --parser)
      shift
      [[ $# -ge 2 ]] || { log_error "usa: --parser <python> <script> [args...]"; exit 1; }
      PARSER_PY="$1"; PARSER_SCRIPT="$2"; shift 2
      while (( $# > 0 )) && [[ "$1" != "--convert" && "$1" != "--htsim" && "$1" != "--topology" && "$1" != "--solver-time" && "$1" != "--out-dir" ]]; do
        PARSER_ARGS+=("$1"); shift
      done
      ;;
    *)
      # coppie TE-CCL <nome valore>, accettando anche -nome / --nome
      (( $# >= 2 )) || { log_error "Parametri TE-CCL devono essere coppie <nome valore>."; exit 1; }
      P="$1"; V="$2"; shift 2
      if _is_numeric "$P"; then
        log_error "Trovato valore numerico dove mi aspetto un nome parametro: '${P}'"
        exit 1
      fi
      P="$(_norm_key "$P")"
      [[ "$P" != "host_per_router" ]] || { log_error "Usa 'hosts_per_router'."; exit 1; }
      [[ "$P" != "schedule_output_file" ]] || { log_warn "Ignoro 'schedule_output_file' passato."; continue; }
      RUN_ARGS+=("$P" "$V")
      ;;
  esac
done

(( ${#RUN_ARGS[@]} % 2 == 0 )) || { log_error "Parametri TE-CCL non a coppie."; exit 1; }

# --- helpers ---
get_val () {
  local name="$1" default="$2" i
  for ((i=0; i<${#RUN_ARGS[@]}; i+=2)); do
    if [[ "${RUN_ARGS[i]}" == "$name" ]]; then
      printf '%s' "${RUN_ARGS[i+1]}" | sed 's/^"\(.*\)"$/\1/'
      return 0
    fi
  done
  printf '%s' "$default"
}

sanitize () {
  echo "$1" | tr '[:upper:]' '[:lower:]' | sed -E 's/[[:space:]]+/-/g; s/[^a-z0-9._-]+//g'
}

# --- estrai parametri chiave ---
NUM_GROUPS="$(get_val num_groups 2)"
SPINE_ROUTERS="$(get_val spine_routers 2)"
LEAF_ROUTERS="$(get_val leaf_routers 1)"
HOSTS_PER_ROUTER="$(get_val hosts_per_router 2)"
NUM_CHUNKS_RAW="$(get_val num_chunks 1)"
CHUNK_SIZE_GB_RAW="$(get_val chunk_size 0)"   # SEMPRE GB decimali
NAME_RAW="$(get_val name "")"

[[ "$NUM_GROUPS" =~ ^[0-9]+$ ]] || { log_error "num_groups deve essere intero."; exit 1; }
[[ "$LEAF_ROUTERS" =~ ^[0-9]+$ ]] || { log_error "leaf_routers deve essere intero."; exit 1; }
[[ "$HOSTS_PER_ROUTER" =~ ^[0-9]+$ ]] || { log_error "hosts_per_router deve essere intero."; exit 1; }

# Numero di host
HOST_COUNT=$(( NUM_GROUPS * LEAF_ROUTERS * HOSTS_PER_ROUTER ))

# Normalizza num_chunks
if [[ "$NUM_CHUNKS_RAW" =~ ^[0-9]+$ ]] && (( NUM_CHUNKS_RAW >= 1 )); then
  NUM_CHUNKS="$NUM_CHUNKS_RAW"
else
  NUM_CHUNKS=1
fi

# conversione GB -> byte (1 GB = 1e9 B)
LC_NUMERIC=C
CHUNK_SIZE_BYTES="$(awk -v gb="$CHUNK_SIZE_GB_RAW" 'BEGIN {
  if (gb+0 != gb) gb=0;
  printf "%.0f", gb * 1000000000.0
}')"

NAME_SAFE=""
if [[ -n "$NAME_RAW" ]]; then
  NAME_SAFE="$(sanitize "$NAME_RAW")"
fi

# --- TAG e cartella (sotto OUT_ROOT) ---
BASE_TAG="groups${NUM_GROUPS}_spine${SPINE_ROUTERS}_leaf${LEAF_ROUTERS}_host${HOSTS_PER_ROUTER}"
CHUNK_TAG="_chunks${NUM_CHUNKS}"
SIZE_TAG="_size${CHUNK_SIZE_BYTES}"
NAME_TAG=""
[[ -n "$NAME_SAFE" ]] && NAME_TAG="_${NAME_SAFE}"

TAG="${BASE_TAG}${CHUNK_TAG}${SIZE_TAG}${NAME_TAG}"
RUN_DIR="${OUT_ROOT}/${TAG}"   # niente prefisso run_

# --- PULIZIA: se la directory esiste già, rimuovila prima di ricrearla ---
if [[ -d "$RUN_DIR" ]]; then
  log_warn "Rimuovo directory esistente: ${BOLD}${CYAN}${RUN_DIR}${RESET}"
  rm -rf "$RUN_DIR"
fi

INPUT_PATH="${RUN_DIR}/input_${TAG}.json"
SCHEDULE_PATH="${RUN_DIR}/schedule_${TAG}.json"
CM_PATH="${RUN_DIR}/connection_matrix_${TAG}.cm"
LOG_OUT="${RUN_DIR}/htsim_logout_${TAG}.dat"

# (ricreo directory "pulita")
mkdir -p "$RUN_DIR" "${RUN_DIR}/plots"

log_info "Cartella output: ${BOLD}${CYAN}${RUN_DIR}${RESET}"
log_info "NODES:           ${BOLD}${HOST_COUNT}${RESET}"
log_info "chunk_size GB:   ${BOLD}${CHUNK_SIZE_GB_RAW}${RESET}"
log_info "chunk_size B:    ${BOLD}${CHUNK_SIZE_BYTES}${RESET}"

# --- step 1: teccl -> JSON & schedule ---
[[ -f "$TOPO_BIN" ]] || { log_error "run_topology.sh non trovato: $TOPO_BIN"; exit 1; }
[[ -x "$TOPO_BIN" ]] || { log_error "non eseguibile: $TOPO_BIN"; exit 1; }

log_info "Eseguo ${BOLD}${CONDA_RUN} ${TOPO_BIN}${RESET} → genera input & schedule"
set -x
${CONDA_RUN} "$TOPO_BIN" "$INPUT_PATH" \
  "${RUN_ARGS[@]}" \
  schedule_output_file "$SCHEDULE_PATH"
RC=$?
set +x
(( RC == 0 )) || { log_error "run_topology.sh rc=$RC"; exit $RC; }

# --- step 1.1: estrazione Solver_Time dal schedule JSON ---
# Auto-discovery se non passato: usa python3 ./extract_solver_time.py se esiste
if [[ -z "$SOLVER_PY" || -z "$SOLVER_SCRIPT" ]]; then
  if [[ -f "./extract_solver_time.py" ]]; then
    SOLVER_PY="python3"
    SOLVER_SCRIPT="./extract_solver_time.py"
    log_info "Auto: uso ${SOLVER_PY} ${SOLVER_SCRIPT} per estrarre Solver_Time"
  else
    log_warn "Nessun --solver-time e ./extract_solver_time.py non trovato: salto estrazione Solver_Time."
  fi
fi

SOLVER_TIME_TXT=""
if [[ -n "$SOLVER_PY" && -n "$SOLVER_SCRIPT" ]]; then
  [[ -x "$SOLVER_PY" ]] || true
  if [[ ! -f "$SCHEDULE_PATH" ]]; then
    log_warn "Schedule JSON non trovato: impossibile estrarre Solver_Time."
  else
    SOLVER_TIME_TXT="${RUN_DIR}/solver_time_${TAG}.txt"
    log_info "Estraggo Solver_Time da ${BOLD}${SCHEDULE_PATH}${RESET} → ${BOLD}${SOLVER_TIME_TXT}${RESET}"
    set -x
    ${CONDA_RUN} "$SOLVER_PY" "$SOLVER_SCRIPT" "$SCHEDULE_PATH" "$SOLVER_TIME_TXT"
    RC=$?
    set +x
    if (( RC != 0 )); then
      log_warn "Estrazione Solver_Time fallita (rc=$RC)."
      SOLVER_TIME_TXT=""
    fi
  fi
fi

# --- step 2: convertTecclSchedule -> .cm ---
[[ -x "$CONVERT_BIN" ]] || { log_error "convertTecclSchedule non eseguibile: $CONVERT_BIN"; exit 1; }
log_info "Converto schedule in Connection Matrix (.cm)"
set -x
"$CONVERT_BIN" "$INPUT_PATH" "$SCHEDULE_PATH" "$CM_PATH"
RC=$?
set +x
(( RC == 0 )) || { log_error "convertTecclSchedule rc=$RC"; exit $RC; }
[[ -f "$CM_PATH" ]] || { log_error "CM non generato: $CM_PATH"; exit 1; }

# --- step 3: htsim_roce ---
[[ -n "${HTSIM_BIN}" ]] || { log_error "Specifica --htsim /path/to/htsim_roce <args...>"; exit 1; }
[[ -x "$HTSIM_BIN" ]] || { log_error "htsim_roce non eseguibile: $HTSIM_BIN"; exit 1; }
for a in "${HTSIM_ARGS[@]}"; do
  [[ "$a" != "-tm" ]]    || { log_error "Non passare -tm: imposto io ${CM_PATH}."; exit 1; }
  [[ "$a" != "-nodes" ]] || { log_error "Non passare -nodes: calcolato (${HOST_COUNT})."; exit 1; }
done

log_info "Lancio htsim_roce (stdout/stderr → ${BOLD}${CYAN}${LOG_OUT}${RESET})"
{
  set -x
  "$HTSIM_BIN" \
    -tm "$CM_PATH" \
    -nodes "$HOST_COUNT" \
    "${HTSIM_ARGS[@]}"
  RC=$?
  set +x
} >"$LOG_OUT" 2>&1
(( RC == 0 )) || { log_error "htsim_roce rc=$RC"; exit $RC; }

# --- step 4: parser (parse_runlog.py) ---
RESERVED=(--cmfile --out-csv --out-summary --out-dot --plots-dir --n-hosts --num-chunks --chunk-size-bytes)
FILTERED_PARSER_ARGS=()
i=0
while (( i < ${#PARSER_ARGS[@]} )); do
  a="${PARSER_ARGS[i]}"
  if [[ "$a" == -* ]]; then
    skip=0
    for r in "${RESERVED[@]}"; do
      if [[ "$a" == "$r" ]]; then
        # salta anche l'eventuale valore successivo
        i=$((i+2)); skip=1; break
      fi
    done
    (( skip == 1 )) && continue
    FILTERED_PARSER_ARGS+=("$a")
    # se flag ha un valore separato, copia anche quello
    if (( i+1 < ${#PARSER_ARGS[@]} )) && [[ "${PARSER_ARGS[i+1]}" != -* ]]; then
      FILTERED_PARSER_ARGS+=("${PARSER_ARGS[i+1]}")
      i=$((i+2)); continue
    fi
    i=$((i+1))
  else
    # argomento posizionale (es. run.log) — ignoriamo, useremo LOG_OUT
    log_warn "Ignoro argomento posizionale del parser: '${a}' (uso ${LOG_OUT})"
    i=$((i+1))
  fi
done

# --- nomi file con host + chunks + size ---
CSV_OUT="${RUN_DIR}/flows_with_deps_host${HOST_COUNT}_chunks${NUM_CHUNKS}_size${CHUNK_SIZE_BYTES}.csv"
SUMMARY_OUT="${RUN_DIR}/summary_host${HOST_COUNT}_chunks${NUM_CHUNKS}_size${CHUNK_SIZE_BYTES}.txt"
DOT_OUT="${RUN_DIR}/deps_host${HOST_COUNT}_chunks${NUM_CHUNKS}_size${CHUNK_SIZE_BYTES}.dot"
PLOTS_DIR="${RUN_DIR}/plots"

[[ -x "$PARSER_PY" ]] || true
[[ -f "$PARSER_SCRIPT" ]] || { log_error "Script parser non trovato: $PARSER_SCRIPT"; exit 1; }

log_info "Eseguo parser su log e CM generati"
set -x
${CONDA_RUN} "$PARSER_PY" "$PARSER_SCRIPT" \
  "$LOG_OUT" \
  --cmfile "$CM_PATH" \
  "${FILTERED_PARSER_ARGS[@]}" \
  --out-csv "$CSV_OUT" \
  --out-summary "$SUMMARY_OUT" \
  --out-dot "$DOT_OUT" \
  --plots-dir "$PLOTS_DIR" \
  --n-hosts "$HOST_COUNT" \
  --num-chunks "$NUM_CHUNKS" \
  --chunk-size-bytes "$CHUNK_SIZE_BYTES"
RC=$?
set +x
(( RC == 0 )) || { log_error "parser rc=$RC"; exit $RC; }

log_ok "Pipeline completata:"
echo " - Cartella:                ${BOLD}${CYAN}$RUN_DIR/${RESET}"
echo " - Input JSON:              ${BOLD}${CYAN}$INPUT_PATH${RESET}"
echo " - Schedule JSON:           ${BOLD}${CYAN}$SCHEDULE_PATH${RESET}"
[[ -n "$SOLVER_TIME_TXT" && -f "$SOLVER_TIME_TXT" ]] && \
echo " - Solver_Time:             ${BOLD}${CYAN}$SOLVER_TIME_TXT${RESET}"
echo " - Connection Matrix (.cm): ${BOLD}${CYAN}$CM_PATH${RESET}"
echo " - Log HTSIM:               ${BOLD}${CYAN}$LOG_OUT${RESET}"
echo " - CSV:                     ${BOLD}${CYAN}$CSV_OUT${RESET}"
echo " - SUMMARY:                 ${BOLD}${CYAN}$SUMMARY_OUT${RESET}"
echo " - DOT:                     ${BOLD}${CYAN}$DOT_OUT${RESET}"
echo " - PLOTS:                   ${BOLD}${CYAN}$PLOTS_DIR/${RESET}"
