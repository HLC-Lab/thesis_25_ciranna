#!/usr/bin/env bash
set -euo pipefail

# Uso: ./sweep_run.sh <MAX_HOSTS>
# - N parte da 16 (salta 2,4,8)
# - num_groups >= 2; gruppi crescono lentamente (2 -> 3 dove possibile -> 4)
# - Target: N = 2^k e N = 3*2^k (<= MAX_HOSTS)
# - Bias 60/40: hosts_per_router cresce più dei leaf; spine = leaf
# - Pipeline: TE-CCL solve -> (schedule.json) -> convertTecclSchedule -> (.cm) -> HTSIM -> parser

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <MAX_HOSTS (>=16)>" >&2
  exit 1
fi

MAX_HOSTS="$1"
if ! [[ "$MAX_HOSTS" =~ ^[0-9]+$ ]] || [[ "$MAX_HOSTS" -lt 16 ]]; then
  echo "Errore: MAX_HOSTS deve essere un intero >= 16" >&2
  exit 1
fi

# ---- Strumenti richiesti ----
# run.sh: fa solo solve (niente --htsim/--parser)
if [[ ! -x ./run.sh ]]; then
  [[ -f ./run.sh ]] && chmod +x ./run.sh || { echo "Errore: ./run.sh non trovato."; exit 1; }
fi
# convertitore schedule->cm
CONVERT_BIN="./convertTecclSchedule"
[[ -x "$CONVERT_BIN" ]] || { echo "Errore: convertitore non eseguibile: $CONVERT_BIN"; exit 1; }
# htsim
HTSIM_BIN="../csg-htsim/sim/datacenter/htsim_roce"
[[ -x "$HTSIM_BIN" ]] || { echo "Errore: simulatore non eseguibile: $HTSIM_BIN"; exit 1; }
# parser
PARSER_PY="python3"
PARSER_SCRIPT="./parse_runlog.py"
[[ -f "$PARSER_SCRIPT" ]] || { echo "Errore: parser non trovato: $PARSER_SCRIPT"; exit 1; }

# ---- Parametri fissi TE-CCL (tuoi) ----
JSON_FILE="./teccl/inputs/dragonflyPlus_input.json"
CHUNK_SIZE="0.000008"
ALPHA="[1.0, 10.0]"
HEURISTICS="0.95"
COLLECTIVE="1"

# Argomenti HTSIM e Parser
HTSIM_ARGS=(-type Df+ -linkspeed 200000000 -mtu 9000 -hop_latency 1 -switch_latency 0.05
            -queue_type lossless_input -q 64 -pfc_thresholds 12 15 -threshold 64
            -strat minimal -start_delta 200000 -end 800000 -log sink -log traffic -logtime 1.0)

PARSER_ARGS=(--unit-finish s --unit-startis us --gantt-max-flows 200)

# ---- Helper: split resto potenza di 2 con bias host 60% ----
split_pow2_rem() {
  local rem="$1" k=0 tmp="$1"
  while (( tmp > 1 )); do
    (( tmp % 2 )) && { echo "ERR"; return 1; }
    tmp=$(( tmp / 2 )); ((k++))
  done
  local hosts_exp=$(( (6*k + 9)/10 ))  # ceil(0.6*k)
  (( hosts_exp < 0 )) && hosts_exp=0
  (( hosts_exp > k )) && hosts_exp=k
  local leaf_exp=$(( k - hosts_exp ))
  local lr=$(( 1 << leaf_exp ))
  local hpr=$(( 1 << hosts_exp ))
  echo "$lr $hpr"
}

# ---- Fattorizzazione: gruppi lenti / host veloci, num_groups >= 2 ----
best_factors() {
  local N="$1"

  # preferisci 3 gruppi se N = 3*2^k
  if (( N % 3 == 0 )); then
    local rem=$(( N / 3 ))
    local t="$rem"
    while (( t > 1 )); do
      (( t % 2 )) && { t=-1; break; }
      t=$(( t / 2 ))
    done
    if (( t != -1 )); then
      read -r LR HPR <<<"$(split_pow2_rem "$rem")"
      echo "3 $LR $HPR"
      return 0
    fi
  fi

  # altrimenti 16..63 -> ng=2 ; >=64 -> ng=4
  local ng=$(( N < 64 ? 2 : 4 ))
  local rem=$(( N / ng ))
  read -r LR HPR <<<"$(split_pow2_rem "$rem")"
  echo "$ng $LR $HPR"
}

# ---- Target: 2^k da 16 + 3*2^k da 24 ----
build_targets() {
  local max="$1"; local -a t=(); local n
  n=16; while (( n <= max )); do t+=( "$n" ); n=$(( n * 2 )); done
  n=24; while (( n <= max )); do t+=( "$n" ); n=$(( n * 2 )); done
  printf "%s\n" "${t[@]}" | sort -n -u
}

echo "== Sweep (N>=16) → schedule_teccl/.json → convertTecclSchedule → connection_matrix/.cm → HTSIM+parser =="
mapfile -t TARGETS < <(build_targets "$MAX_HOSTS")

for N in "${TARGETS[@]}"; do
  IFS=' ' read -r NG LR HPR <<<"$(best_factors "$N")"
  SR="$LR"
  echo "--> N=$N  =>  num_groups=$NG  leaf=$LR  spine=$SR  hosts_per_router=$HPR"

  # Cartelle e nomi richiesti
  RUN_BASE="run_group${NG}_spine${SR}_leaf${LR}_host${HPR}"
  RUN_DIR="${RUN_BASE}"
  SCHED_DIR="${RUN_DIR}/schedule_teccl"
  CM_DIR="${RUN_DIR}/connection_matrix"
  PLOTS_DIR="${RUN_DIR}/plots"
  mkdir -p "$SCHED_DIR" "$CM_DIR" "$PLOTS_DIR"

  SCHED_JSON="${SCHED_DIR}/allgather_Teccl_host${N}.json"
  CM_TARGET="${CM_DIR}/allgather_Teccl_host${N}.cm"

  # 1) Solve TE-CCL (solo se manca lo schedule)
  if [[ -f "$SCHED_JSON" ]]; then
    echo "    [INFO] Schedule già presente: $SCHED_JSON (skip solve)"
  else
    ./run.sh "$JSON_FILE" \
      num_groups "$NG" \
      spine_routers "$SR" \
      leaf_routers "$LR" \
      hosts_per_router "$HPR" \
      chunk_size "$CHUNK_SIZE" \
      alpha "$ALPHA" \
      heuristics "$HEURISTICS" \
      collective "$COLLECTIVE" \
      schedule_output_file "$SCHED_JSON"
    echo "    [OK] Schedule TE-CCL salvato: $SCHED_JSON"
  fi

  # 2) Conversione schedule -> CM (solo se manca la CM)
  if [[ -f "$CM_TARGET" ]]; then
    echo "    [INFO] CM già presente: $CM_TARGET (skip convert)"
  else
    # Se il tuo convertitore accetta solo 2 argomenti, usa: "$CONVERT_BIN" "$SCHED_JSON" "$CM_TARGET"
    "$CONVERT_BIN" "$JSON_FILE" "$SCHED_JSON" "$CM_TARGET"
    echo "    [OK] Connection Matrix salvata: $CM_TARGET"
  fi

  # 3) HTSIM
  RUN_LOG="${RUN_DIR}/${RUN_BASE}.log"
  "$HTSIM_BIN" -tm "$CM_TARGET" -nodes "$N" "${HTSIM_ARGS[@]}" > "$RUN_LOG"
  echo "    [OK] HTSIM completato: $RUN_LOG"

  # 4) Parser
  SUMMARY_OUT="${RUN_DIR}/summary.csv"
  CSV_OUT="${RUN_DIR}/flows.csv"
  DOT_OUT="${RUN_DIR}/graph.dot"

  "$PARSER_PY" "$PARSER_SCRIPT" \
    "$RUN_LOG" \
    --cmfile "$CM_TARGET" \
    --out-csv "$CSV_OUT" \
    --out-summary "$SUMMARY_OUT" \
    --out-dot "$DOT_OUT" \
    --plots-dir "$PLOTS_DIR" \
    "${PARSER_ARGS[@]}"

  echo "    [OK] Parser → CSV: $CSV_OUT | Summary: $SUMMARY_OUT | DOT: $DOT_OUT | Plots: $PLOTS_DIR/"
done

echo "== Sweep completato =="
