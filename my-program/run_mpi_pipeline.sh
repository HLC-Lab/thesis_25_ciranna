#!/usr/bin/env bash
set -euo pipefail

# ------------------------------------------------------------
# run_mpi_pipeline.sh — MPI AllGather (ring/bruck/recdub/bine...) end-to-end:
#   gen_allgather_*.py -> htsim -> parser
#   - Naming: (se --algo) mpi_<algo>_hostN_chunksK_sizeBYTES, altrimenti mpi_hostN_chunksK_sizeBYTES
#   - chunk-size: preferisce --chunk-size-bytes; fallback a --chunk-size-gb (1 GB = 1e9 B)
#   - Passa al parser: --n-hosts, --num-chunks, --chunk-size-bytes
#   - Tutto l'output finisce sotto ./output_pipeline/ (override: --out-dir)
#   - NOVITÀ: accetta --s-df / --l-df / --h-df / --p-df e li passa a htsim_roce come -s/-l/-h/-p
# ------------------------------------------------------------

# --- styling ANSI (uniforme con gli altri script; auto-disabilitato se non TTY) ---
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

# ---- helper formattazione dimensioni ----
fmt_gb_no_sci() { awk -v b="$1" 'BEGIN{ s=sprintf("%.12f", b/1000000000.0); gsub(/0+$/,"",s); sub(/\.$/,"",s); if(s=="")s="0"; print s; }'; }
fmt_kb_no_sci() { awk -v b="$1" 'BEGIN{ s=sprintf("%.6f",  b/1024.0);        gsub(/0+$/,"",s); sub(/\.$/,"",s); if(s=="")s="0"; print s; }'; }

# --- prerequisiti: conda disponibile ---
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

# --- parsing argomenti ---
GEN_PROG=""
N=""
P4=""
P5=""
K="1"                   # --chunks (default 1)
CHUNK_SIZE_GB=""        # opzionale (fallback)
CHUNK_SIZE_BYTES=""     # preferito se presente
ALGO=""                 # nome algoritmo per naming (es. ring, bruck, recdub, bine)
HTSIM_BIN=""; HTSIM_ARGS=()
PARSER_PY="python3"; PARSER_SCRIPT=""; PARSER_ARGS=()

# NOVITÀ: parametri Dragonfly+ da passare a htsim_roce
S_DF=""; L_DF=""; H_DF=""; P_DF=""

if (( $# == 0 )); then
  log_info "${BOLD}Uso:${RESET}"
  cat >&2 <<USO
  $0 [--out-dir DIR]
     --gen <gen_allgather_*.py>
     --n <N> --p4 <val> --p5 <val>
     [--chunks <K>] [--chunk-size-bytes <BYTES>] [--chunk-size-gb <GB>] [--algo <nome>]
     [--s-df <S>] [--l-df <L>] [--h-df <H>] [--p-df <P>]
     --htsim <path_htsim_roce> <args...>
     [--parser <python> <script> <args...>]
USO
  exit 1
fi

while (( $# > 0 )); do
  case "${1:-}" in
    --gen)               shift; [[ $# -ge 1 ]] || { log_error "manca il path dopo --gen"; exit 1; }; GEN_PROG="$1"; shift;;
    --n)                 shift; [[ $# -ge 1 ]] || { log_error "manca il valore dopo --n"; exit 1; }; N="$1"; shift;;
    --p4)                shift; [[ $# -ge 1 ]] || { log_error "manca il valore dopo --p4"; exit 1; }; P4="$1"; shift;;
    --p5)                shift; [[ $# -ge 1 ]] || { log_error "manca il valore dopo --p5"; exit 1; }; P5="$1"; shift;;
    --chunks)            shift; [[ $# -ge 1 ]] || { log_error "manca il valore dopo --chunks"; exit 1; }; K="$1"; shift;;
    --chunk-size-bytes)  shift; [[ $# -ge 1 ]] || { log_error "manca il valore dopo --chunk-size-bytes"; exit 1; }; CHUNK_SIZE_BYTES="$1"; shift;;
    --chunk-size-gb)     shift; [[ $# -ge 1 ]] || { log_error "manca il valore dopo --chunk-size-gb"; exit 1; }; CHUNK_SIZE_GB="$1"; shift;;
    --algo)              shift; [[ $# -ge 1 ]] || { log_error "manca il nome dopo --algo"; exit 1; }; ALGO="$1"; shift;;
    # --- NUOVO: parametri Dragonfly+ da passare a htsim_roce ---
    --s-df)              shift; [[ $# -ge 1 ]] || { log_error "manca il valore dopo --s-df"; exit 1; }; S_DF="$1"; shift;;
    --l-df)              shift; [[ $# -ge 1 ]] || { log_error "manca il valore dopo --l-df"; exit 1; }; L_DF="$1"; shift;;
    --h-df)              shift; [[ $# -ge 1 ]] || { log_error "manca il valore dopo --h-df"; exit 1; }; H_DF="$1"; shift;;
    --p-df)              shift; [[ $# -ge 1 ]] || { log_error "manca il valore dopo --p-df"; exit 1; }; P_DF="$1"; shift;;
    --htsim)
      shift
      [[ $# -ge 1 ]] || { log_error "manca il path a htsim_roce dopo --htsim"; exit 1; }
      HTSIM_BIN="$1"; shift
      while (( $# > 0 )) && [[ "$1" != "--gen" && "$1" != "--n" && "$1" != "--p4" && "$1" != "--p5" && "$1" != "--chunks" && "$1" != "--chunk-size-bytes" && "$1" != "--chunk-size-gb" && "$1" != "--algo" && "$1" != "--htsim" && "$1" != "--parser" && "$1" != "--out-dir" && "$1" != "--s-df" && "$1" != "--l-df" && "$1" != "--h-df" && "$1" != "--p-df" ]]; do
        HTSIM_ARGS+=("$1"); shift
      done
      ;;
    --parser)
      shift
      [[ $# -ge 2 ]] || { log_error "usa: --parser <python> <script> [args...]"; exit 1; }
      PARSER_PY="$1"; PARSER_SCRIPT="$2"; shift 2
      while (( $# > 0 )) && [[ "$1" != "--gen" && "$1" != "--n" && "$1" != "--p4" && "$1" != "--p5" && "$1" != "--chunks" && "$1" != "--chunk-size-bytes" && "$1" != "--chunk-size-gb" && "$1" != "--algo" && "$1" != "--htsim" && "$1" != "--parser" && "$1" != "--out-dir" && "$1" != "--s-df" && "$1" != "--l-df" && "$1" != "--h-df" && "$1" != "--p-df" ]]; do
        PARSER_ARGS+=("$1"); shift
      done
      ;;
    *) log_error "Opzione non riconosciuta: $1"; exit 1;;
  esac
done

# --- validazione ---
[[ -n "$GEN_PROG" ]] || { log_error "specifica --gen <gen_allgather_*.py>"; exit 1; }
[[ -f "$GEN_PROG" ]] || { log_error "file generatore non trovato: $GEN_PROG"; exit 1; }
[[ -n "$N" && "$N" =~ ^[0-9]+$ ]] || { log_error "--n deve essere intero"; exit 1; }
[[ -n "$P4" ]] || { log_error "specifica --p4 <val>"; exit 1; }
[[ -n "$P5" ]] || { log_error "specifica --p5 <val>"; exit 1; }
[[ "$K" =~ ^[0-9]+$ && "$K" -ge 1 ]] || { log_error "--chunks deve essere intero >= 1"; exit 1; }
[[ -n "$HTSIM_BIN" ]] || { log_error "specifica --htsim /path/to/htsim_roce <args...>"; exit 1; }
[[ -x "$HTSIM_BIN" ]] || { log_error "htsim_roce non eseguibile: $HTSIM_BIN"; exit 1; }
for a in "${HTSIM_ARGS[@]}"; do
  [[ "$a" != "-tm"    ]] || { log_error "Non passare -tm: lo imposta lo script."; exit 1; }
  [[ "$a" != "-nodes" ]] || { log_error "Non passare -nodes: lo imposta lo script."; exit 1; }
done

# --- dimensione chunk: priorità BYTES; fallback GB (1e9) ---
LC_NUMERIC=C
if [[ -n "$CHUNK_SIZE_BYTES" ]]; then
  [[ "$CHUNK_SIZE_BYTES" =~ ^[0-9]+$ ]] || { log_error "--chunk-size-bytes deve essere intero >= 0"; exit 1; }
  SIZE_BYTES="$CHUNK_SIZE_BYTES"
else
  gb="${CHUNK_SIZE_GB:-0}"
  SIZE_BYTES="$(awk -v gb="$gb" 'BEGIN{ if (gb+0!=gb) gb=0; printf "%.0f", gb*1000000000.0 }')"
fi

SIZE_KB="$(fmt_kb_no_sci "$SIZE_BYTES")"
SIZE_GB_DEC="$(fmt_gb_no_sci "$SIZE_BYTES")"

# --- naming e path output ---
if [[ -n "$ALGO" ]]; then
  TAG="mpi_${ALGO}_host${N}_chunks${K}_size${SIZE_BYTES}"
else
  TAG="mpi_host${N}_chunks${K}_size${SIZE_BYTES}"
fi
RUN_DIR="${OUT_ROOT}/${TAG}"
CM_PATH="${RUN_DIR}/${TAG}.cm"
LOG_OUT="${RUN_DIR}/htsim_logout_${TAG}.dat"
CSV_OUT="${RUN_DIR}/flows_with_deps_host${N}_chunks${K}_size${SIZE_BYTES}.csv"
SUMMARY_OUT="${RUN_DIR}/summary_host${N}_chunks${K}_size${SIZE_BYTES}.txt"
DOT_OUT="${RUN_DIR}/deps_host${N}_chunks${K}_size${SIZE_BYTES}.dot"
PLOTS_DIR="${RUN_DIR}/plots"

# --- PULIZIA: se la directory esiste già, rimuovila e ricreala pulita ---
if [[ -d "$RUN_DIR" ]]; then
  log_warn "Rimuovo directory esistente: ${BOLD}${CYAN}${RUN_DIR}${RESET}"
  rm -rf "$RUN_DIR"
fi
mkdir -p "$RUN_DIR" "$PLOTS_DIR"

log_info "Parametri MPI: N=${BOLD}${N}${RESET}, chunks=${BOLD}${K}${RESET}, chunk_size=${BOLD}${SIZE_GB_DEC}${RESET} GB | ${BOLD}${SIZE_KB}${RESET} KB | ${BOLD}${SIZE_BYTES}${RESET} B ${ALGO:+| algo=${BOLD}${ALGO}${RESET}}"
log_info "Genero CM con ${BOLD}${GEN_PROG}${RESET}"
log_info "Output CM: ${BOLD}${CYAN}${CM_PATH}${RESET}"

# --- step 1: generazione CM (python) ---
set -x
${CONDA_RUN} python3 "$GEN_PROG" "$CM_PATH" "$N" "$N" "$P4" "$P5"
RC=$?
set +x
(( RC == 0 )) || { log_error "generatore rc=$RC"; exit $RC; }
[[ -f "$CM_PATH" ]] || { log_error "CM non generata: $CM_PATH"; exit 1; }

log_ok "CM creata: ${BOLD}${CYAN}$CM_PATH${RESET}"

# --- aggiungo parametri Dragonfly+ a HTSIM_ARGS se presenti (come -s/-l/-h/-p) ---
EXTRA_DF_ARGS=()
if [[ -n "$S_DF" ]]; then EXTRA_DF_ARGS+=(-s "$S_DF"); fi
if [[ -n "$L_DF" ]]; then EXTRA_DF_ARGS+=(-l "$L_DF"); fi
if [[ -n "$H_DF" ]]; then EXTRA_DF_ARGS+=(-h "$H_DF"); fi
if [[ -n "$P_DF" ]]; then EXTRA_DF_ARGS+=(-p "$P_DF"); fi

# ---- garantisci flag logging HTSIM se mancanti ----
have_log_sink=0; have_log_traffic=0; have_logtime=0
i=0
while (( i < ${#HTSIM_ARGS[@]} )); do
  a="${HTSIM_ARGS[i]}"
  if [[ "$a" == "-log" && $((i+1)) -lt ${#HTSIM_ARGS[@]} ]]; then
    case "${HTSIM_ARGS[i+1]}" in
      sink)    have_log_sink=1 ;;
      traffic) have_log_traffic=1 ;;
    esac
    i=$((i+2)); continue
  fi
  if [[ "$a" == "-logtime" ]]; then
    have_logtime=1; i=$((i+2)); continue
  fi
  i=$((i+1))
done
(( have_log_sink    == 1 )) || HTSIM_ARGS+=(-log sink)
(( have_log_traffic == 1 )) || HTSIM_ARGS+=(-log traffic)
(( have_logtime     == 1 )) || HTSIM_ARGS+=(-logtime 1.0)

# --- step 2: htsim_roce ---
log_info "Lancio htsim_roce (stdout/stderr → ${BOLD}${CYAN}${LOG_OUT}${RESET})"
{
  set -x
  "$HTSIM_BIN" \
    -tm "$CM_PATH" \
    -nodes "$N" \
    "${EXTRA_DF_ARGS[@]}" \
    "${HTSIM_ARGS[@]}"
  RC=$?
  set +x
} >"$LOG_OUT" 2>&1
(( RC == 0 )) || { log_error "htsim_roce rc=$RC"; exit $RC; }

# --- step 3: parser (opzionale ma consigliato) ---
if [[ -n "$PARSER_SCRIPT" ]]; then
  RESERVED=(--cmfile --out-csv --out-summary --out-dot --plots-dir --n-hosts --num-chunks --chunk-size-bytes)
  FILTERED_PARSER_ARGS=()
  i=0
  while (( i < ${#PARSER_ARGS[@]} )); do
    a="${PARSER_ARGS[i]}"
    if [[ "$a" == -* ]]; then
      skip=0
      for r in "${RESERVED[@]}"; do
        if [[ "$a" == "$r" ]]; then i=$((i+2)); skip=1; break; fi
      done
      (( skip == 1 )) && continue
      FILTERED_PARSER_ARGS+=("$a")
      if (( i+1 < ${#PARSER_ARGS[@]} )) && [[ "${PARSER_ARGS[i+1]}" != -* ]]; then
        FILTERED_PARSER_ARGS+=("${PARSER_ARGS[i+1]}")
        i=$((i+2)); continue
      fi
      i=$((i+1))
    else
      log_warn "Ignoro argomento posizionale del parser: '${a}' (uso ${LOG_OUT})"
      i=$((i+1))
    fi
  done

  [[ -f "$PARSER_SCRIPT" ]] || { log_error "Script parser non trovato: $PARSER_SCRIPT"; exit 1; }
  [[ -x "$PARSER_PY" ]] || true

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
    --n-hosts "$N" \
    --num-chunks "$K" \
    --chunk-size-bytes "$SIZE_BYTES"
  RC=$?
  set +x
  (( RC == 0 )) || { log_error "parser rc=$RC"; exit $RC; }
fi

log_ok "Pipeline completata:"
echo " - Connection Matrix (.cm): ${BOLD}${CYAN}$CM_PATH${RESET}"
echo " - Log HTSIM:               ${BOLD}${CYAN}$LOG_OUT${RESET}"
if [[ -n "${PARSER_SCRIPT}" ]]; then
  echo " - CSV:                     ${BOLD}${CYAN}$CSV_OUT${RESET}"
  echo " - SUMMARY:                 ${BOLD}${CYAN}$SUMMARY_OUT${RESET}"
  echo " - DOT:                     ${BOLD}${CYAN}$DOT_OUT${RESET}"
  echo " - PLOTS:                   ${BOLD}${CYAN}$PLOTS_DIR/${RESET}"
fi
