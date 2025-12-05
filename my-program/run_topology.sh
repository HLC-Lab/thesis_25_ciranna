#!/usr/bin/env bash
set -euo pipefail

# ------------------------------------------------------------
# run_topology.sh — genera l'input JSON per TE-CCL e lancia il solver
# ------------------------------------------------------------
# Uso:
#   ./run_topology.sh <INPUT_JSON_PATH> [param valore ...]
#
# Esempio:
#   ./run_topology.sh ./teccl/inputs/dragonflyPlus_input.json \
#     num_groups 2 spine_routers 4 leaf_routers 4 hosts_per_router 4 chunk_size 0.05 \
#     alpha '[1.0, 10.0]' heuristics 0.95 collective 1 time_limit 600 \
#     feasibility_tol 0.0001 intfeas_tol 0.0001 optimality_tol 0.0001 output_flag 0 \
#     log_file "" log_to_console 1 mip_gap 0.001 mip_focus 1 crossover -1 method -1 \
#     num_chunks 3 epoch_type 2 epoch_duration 20000 num_epochs 10 alpha_threshold 0.1 \
#     switch_copy false debug false debug_output_file "" objective_type 1 solution_method 2 \
#     schedule_output_file "teccl/schedules/dragonflyPlus_schedule.json"
#
# Requisiti: jq, teccl nel PATH
# ------------------------------------------------------------

# --- styling ANSI (uniforme con sweep/run_mpi/run_pipeline; auto-disabilitato se non TTY) ---
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

# ---- utilità base ----
ts() { date '+%Y-%m-%d %H:%M:%S'; }
log_info()  { echo "${BOLD}${BLUE}[INFO]${RESET} $*"; }
log_ok()    { echo "${BOLD}${GREEN}[OK]${RESET}   $*"; }
log_warn()  { echo "${BOLD}${YELLOW}[WARN]${RESET} $*"; }
log_error() { echo "${BOLD}${RED}[ERRORE]${RESET} $*" >&2; }

# --- prerequisiti ---
if ! command -v jq >/dev/null 2>&1; then
  log_error "jq non trovato. Installa con: sudo apt-get install jq"
  exit 1
fi
if ! command -v teccl >/dev/null 2>&1; then
  log_error "comando 'teccl' non trovato nel PATH. Aggiungilo prima di procedere."
  exit 1
fi

# --- parsing input path ---
if [[ $# -lt 1 ]]; then
  log_info "${BOLD}Uso:${RESET}"
  cat >&2 <<USO
  $0 <INPUT_JSON_PATH> [param valore ...]
USO
  exit 1
fi

strip_quotes() {
  local s="$1"
  if [[ "$s" =~ ^\".*\"$ ]]; then
    s="${s:1:-1}"
  fi
  echo "$s"
}

INPUT_PATH_RAW="$1"
shift 1
INPUT_PATH="$(strip_quotes "$INPUT_PATH_RAW")"

# Crea cartella destinazione del JSON di input
mkdir -p "$(dirname -- "$INPUT_PATH")"

log_info "Generazione input JSON: ${BOLD}${CYAN}${INPUT_PATH}${RESET}"

# --- defaults (come da specifica) ---
# NOTA: questi sono i valori di default sovrascrivibili da CLI
DEFAULT_JSON='{
  "TopologyParams": {
    "name": "DragonflyPlus",
    "num_groups": 2,
    "leaf_routers": 1,
    "spine_routers": 2,
    "hosts_per_router": 2,
    "chunk_size": 0.05,
    "alpha": [1.0, 10.0]
  },
  "GurobiParams": {
    "time_limit": 600,
    "feasibility_tol": 0.0001,
    "intfeas_tol": 0.0001,
    "optimality_tol": 0.0001,
    "output_flag": 0,
    "log_file": "",
    "log_to_console": 1,
    "mip_gap": 0.001,
    "mip_focus": 1,
    "crossover": -1,
    "method": -1,
    "heuristics": 0.95
  },
  "InstanceParams": {
    "collective": 1,
    "num_chunks": 1,
    "epoch_type": 2,
    "epoch_duration": 200,
    "num_epochs": 10,
    "alpha_threshold": 0.1,
    "switch_copy": false,
    "debug": false,
    "debug_output_file": "",
    "objective_type": 1,
    "solution_method": 2,
    "schedule_output_file": "teccl/schedules/dragonflyPlus_schedule.json"
  }
}'

TMP_JSON="$(mktemp)"
echo "$DEFAULT_JSON" > "$TMP_JSON"

# --- mapping sezioni ---
# TopologyParams
declare -A MAP_TOPO=(
  [name]=1
  [num_groups]=1
  [leaf_routers]=1
  [spine_routers]=1
  [hosts_per_router]=1
  [chunk_size]=1
  [alpha]=1
)
# GurobiParams
declare -A MAP_GUROBI=(
  [time_limit]=1
  [feasibility_tol]=1
  [intfeas_tol]=1
  [optimality_tol]=1
  [output_flag]=1
  [log_file]=1
  [log_to_console]=1
  [mip_gap]=1
  [mip_focus]=1
  [crossover]=1
  [method]=1
  [heuristics]=1
)
# InstanceParams
declare -A MAP_INSTANCE=(
  [collective]=1
  [num_chunks]=1
  [epoch_type]=1
  [epoch_duration]=1
  [num_epochs]=1
  [alpha_threshold]=1
  [switch_copy]=1
  [debug]=1
  [debug_output_file]=1
  [objective_type]=1
  [solution_method]=1
  [schedule_output_file]=1
)

is_json_literal() {
  local v="$1"
  # numero int/float, true/false/null, array [], object {}
  if [[ "$v" =~ ^-?[0-9]+(\.[0-9]+)?$ ]] || [[ "$v" == "true" ]] || [[ "$v" == "false" ]] || [[ "$v" == "null" ]] || [[ "$v" =~ ^\[.*\]$ ]] || [[ "$v" =~ ^\{.*\}$ ]]; then
    return 0
  else
    return 1
  fi
}

SCHEDULE_PATH_SET=""

# --- applica coppie param/valore ---
if (( $# % 2 != 0 )); then
  log_error "Parametri non a coppie. Ogni 'param' deve avere un 'valore'."
  exit 1
fi

while [[ $# -gt 0 ]]; do
  PARAM="$1"
  RAW_VAL="$2"
  shift 2

  VAL="$(strip_quotes "$RAW_VAL")"

  # percorso schedule: crea dir se serve
  if [[ "$PARAM" == "schedule_output_file" ]]; then
    SCHEDULE_PATH_SET="$VAL"
    if [[ -n "$SCHEDULE_PATH_SET" ]]; then
      mkdir -p "$(dirname -- "$SCHEDULE_PATH_SET")"
    fi
  fi

  # decidi se valore è json grezzo o stringa
  if is_json_literal "$VAL"; then
    JQ_ARG="--argjson"; JQ_VAL="$VAL"
  else
    JQ_ARG="--arg"; JQ_VAL="$VAL"
  fi

  if [[ -n "${MAP_TOPO[$PARAM]:-}" ]]; then
    jq $JQ_ARG v "$JQ_VAL" --arg k "$PARAM" '.TopologyParams[$k] = $v' \
      "$TMP_JSON" > "${TMP_JSON}.new"
  elif [[ -n "${MAP_GUROBI[$PARAM]:-}" ]]; then
    jq $JQ_ARG v "$JQ_VAL" --arg k "$PARAM" '.GurobiParams[$k] = $v' \
      "$TMP_JSON" > "${TMP_JSON}.new"
  elif [[ -n "${MAP_INSTANCE[$PARAM]:-}" ]]; then
    jq $JQ_ARG v "$JQ_VAL" --arg k "$PARAM" '.InstanceParams[$k] = $v' \
      "$TMP_JSON" > "${TMP_JSON}.new"
  else
    log_warn "Parametro sconosciuto '${PARAM}' → inserito in InstanceParams"
    jq $JQ_ARG v "$JQ_VAL" --arg k "$PARAM" '.InstanceParams[$k] = $v' \
      "$TMP_JSON" > "${TMP_JSON}.new"
  fi
  mv "${TMP_JSON}.new" "$TMP_JSON"
done

# forza schedule_output_file se passato esplicitamente (sanificato)
if [[ -n "$SCHEDULE_PATH_SET" ]]; then
  jq --arg sched "$SCHEDULE_PATH_SET" '.InstanceParams.schedule_output_file = $sched' \
    "$TMP_JSON" > "${TMP_JSON}.new" && mv "${TMP_JSON}.new" "$TMP_JSON"
fi

# scrivi JSON finale
cp "$TMP_JSON" "$INPUT_PATH"
rm -f "$TMP_JSON"

log_ok "File JSON generato: ${BOLD}${CYAN}${INPUT_PATH}${RESET}"

# --- lancio solver ---
log_info "Lancio solver: ${BOLD}teccl solve --input_args \"${INPUT_PATH}\"${RESET}"
set +e
teccl solve --input_args "$INPUT_PATH"
RC=$?
set -e

if [[ $RC -ne 0 ]]; then
  log_error "Solver terminato con codice ${RC}"
  exit $RC
fi
log_ok "Solver completato con successo."

# --- info finale sullo schedule ---
SCHEDULE_PATH="$(jq -r '.InstanceParams.schedule_output_file // empty' "$INPUT_PATH")"
if [[ -n "$SCHEDULE_PATH" ]]; then
  if [[ -f "$SCHEDULE_PATH" ]]; then
    log_ok "Schedule scritto in: ${BOLD}${CYAN}${SCHEDULE_PATH}${RESET}"
  else
    log_warn "schedule_output_file impostato a: ${BOLD}${CYAN}${SCHEDULE_PATH}${RESET} (file non trovato)."
  fi
fi
