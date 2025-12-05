#!/usr/bin/env bash
set -euo pipefail

# ------------------------------------------------------------
# sweep_pipeline.sh — Sweep TE-CCL + MPI (Dragonfly+ bilanciata, ordine: TCCL→MPI per config)
#   - Intervallo radix: min_radix ... max_radix (K pari, >=4) oppure singolo -radix/-K
#   - NOVITÀ: range gruppi configurabile via min_groups / max_groups (default: 2..min(4, Gmax))
#   - Per ogni K: L=S=P=K/2; hosts_per_group=(K/2)^2; Gmax=K^2/4 + 1
#   - Per ogni (K,g): PRIMA TCCL su tutti i chunk, POI MPI (tutti gli algoritmi) su tutti i chunk
#   - Chunk fissi: 8KB,64KB,128KB,256KB,512KB,1MB,2MB,4MB
#   - Nomi output IDENTICI:
#       TE-CCL: groups${NG}_spine${SR}_leaf${LR}_host${HPR}_chunks1_size${S_BYTES}
#       MPI:    mpi_${algo}_host${N}_chunks1_size${S_BYTES}
#   - Mostra progress: [ i / TOT ]
#   - NON cancella ./output_pipeline
# ------------------------------------------------------------

# --- styling ANSI ---
if [[ -t 1 ]] && command -v tput >/devnull 2>&1; then
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

# ---- utilità parsing ----
_norm_key()   { echo "$1" | sed -E 's/^-+//'; }
_norm_block() { _norm_key "$1"; }
is_block_token() {
  local t="$(_norm_block "$1")"
  case "$t" in convert|parser|htsim|topology|mpi-gen) return 0 ;; *) return 1 ;; esac
}

# ---- setup ambiente ----
OUT_BASE="./output_pipeline"
[[ -d "$OUT_BASE" ]] || mkdir -p "$OUT_BASE"

[[ -x ./run_pipeline.sh ]] || { [[ -f ./run_pipeline.sh ]] && chmod +x ./run_pipeline.sh || { log_error "run_pipeline.sh non trovato"; exit 1; }; }
[[ -x ./run_mpi_pipeline.sh ]] || { [[ -f ./run_mpi_pipeline.sh ]] && chmod +x ./run_mpi_pipeline.sh || true; }

if ! command -v conda >/dev/null 2>&1; then
  log_error "conda non trovato nel PATH."
  exit 1
fi

CONDA_ENV="te-ccl-env"
CONDA_RUN="conda run -n ${CONDA_ENV}"
log_info "Userò ${BOLD}${CONDA_RUN}${RESET} per i comandi Python chiamati dallo sweep"

# ---- parsing argomenti ----
TECCL_EXTRA_ARGS=()
CONVERT_BIN="./convertTecclSchedule"
HTSIM_BIN=""
HTSIM_ARGS=()
PARSER_PY="python3"
PARSER_SCRIPT="./parse_runlog.py"
PARSER_ARGS=()
MPI_GEN_DIR=""
TOPO_BIN=""

SINGLE_RADIX=""
MIN_RADIX=""
MAX_RADIX=""

# NOVITÀ: range gruppi opzionale
USER_MIN_GROUPS=""
USER_MAX_GROUPS=""

# Prima fase: coppie param/valore (e --topology)
while (( $# > 0 )); do
  case "$(_norm_block "$1")" in
    topology)
      shift; [[ $# -ge 1 ]] || { log_error "Manca il path dopo --topology"; exit 1; }
      TOPO_BIN="$1"; shift
      ;;
    convert|htsim|parser|mpi-gen)
      break
      ;;
    *)
      if (( $# < 2 )); then
        log_error "Coppia <parametro valore> incompleta vicino a '$1'."
        exit 1
      fi
      P_RAW="$1"; V="$2"; shift 2
      P="$(_norm_key "$P_RAW")"
      case "$P" in
        radix|K)
          [[ "$V" =~ ^[0-9]+$ && $((V%2)) -eq 0 && "$V" -ge 4 ]] \
            || { log_error "radix K deve essere intero, PARI, >=4"; exit 1; }
          SINGLE_RADIX="$V"
          ;;
        min_radix)
          [[ "$V" =~ ^[0-9]+$ && $((V%2)) -eq 0 && "$V" -ge 4 ]] \
            || { log_error "min_radix deve essere intero, PARI, >=4"; exit 1; }
          MIN_RADIX="$V"
          ;;
        max_radix)
          [[ "$V" =~ ^[0-9]+$ && $((V%2)) -eq 0 && "$V" -ge 4 ]] \
            || { log_error "max_radix deve essere intero, PARI, >=4"; exit 1; }
          MAX_RADIX="$V"
          ;;
        # --- NOVITÀ: accetta min_groups / max_groups come interi ---
        min_groups)
          [[ "$V" =~ ^[0-9]+$ ]] || { log_error "min_groups deve essere intero >=2"; exit 1; }
          USER_MIN_GROUPS="$V"
          ;;
        max_groups)
          [[ "$V" =~ ^[0-9]+$ ]] || { log_error "max_groups deve essere intero >=2"; exit 1; }
          USER_MAX_GROUPS="$V"
          ;;
        *)
          TECCL_EXTRA_ARGS+=("$P" "$V")
          ;;
      esac
      ;;
  esac
done

# Seconda fase: blocchi opzionali
while (( $# > 0 )); do
  case "$(_norm_block "$1")" in
    convert)  shift; CONVERT_BIN="$1"; shift ;;
    topology) shift; TOPO_BIN="$1"; shift ;;
    htsim)
      shift; HTSIM_BIN="$1"; shift
      while (( $# > 0 )) && ! is_block_token "$1"; do HTSIM_ARGS+=("$1"); shift; done
      ;;
    parser)
      shift; PARSER_PY="$1"; PARSER_SCRIPT="$2"; shift 2
      while (( $# > 0 )) && ! is_block_token "$1"; do PARSER_ARGS+=("$1"); shift; done
      ;;
    mpi-gen)  shift; MPI_GEN_DIR="$1"; shift ;;
    *) log_error "Opzione sconosciuta: $1"; exit 1 ;;
  esac
done

# ---- validazioni di base ----
[[ -n "$HTSIM_BIN" ]] || { log_error "Devi specificare --htsim."; exit 1; }
# Coerenza min/max radix
if [[ -n "$MIN_RADIX" || -n "$MAX_RADIX" ]]; then
  [[ -n "$MIN_RADIX" && -n "$MAX_RADIX" ]] || { log_error "Specificare entrambi: min_radix e max_radix"; exit 1; }
  (( MIN_RADIX <= MAX_RADIX )) || { log_error "min_radix deve essere <= max_radix"; exit 1; }
fi
# Coerenza min/max groups se entrambi forniti
if [[ -n "$USER_MIN_GROUPS" && -n "$USER_MAX_GROUPS" ]]; then
  (( USER_MIN_GROUPS <= USER_MAX_GROUPS )) || { log_error "min_groups deve essere <= max_groups"; exit 1; }
fi

# Determina lista di K
K_LIST=()
if [[ -n "$MIN_RADIX" || -n "$MAX_RADIX" ]]; then
  for ((k=MIN_RADIX; k<=MAX_RADIX; k+=2)); do K_LIST+=("$k"); done
elif [[ -n "$SINGLE_RADIX" ]]; then
  K_LIST+=("$SINGLE_RADIX")
else
  log_error "Devi passare o -radix K (singolo) oppure min_radix e max_radix (intervallo)."
  exit 1
fi

# ---- MPI generatori (opzionale) ----
MPI_ALGOS=()
if [[ -n "$MPI_GEN_DIR" ]]; then
  [[ -d "$MPI_GEN_DIR" ]] || { log_error "--mpi-gen deve essere una directory esistente: $MPI_GEN_DIR"; exit 1; }
  mapfile -t _found < <(find "$MPI_GEN_DIR" -maxdepth 1 -type f -name 'gen_allgather_*.py' | sort)
  (( ${#_found[@]} > 0 )) || { log_error "Nessun generatore trovato in ${MPI_GEN_DIR} (attesi: gen_allgather_*.py)."; exit 1; }
  for f in "${_found[@]}"; do
    base="$(basename -- "$f")"
    algo="${base#gen_allgather_}"; algo="${algo%.py}"
    [[ -n "$algo" ]] || { log_warn "File anomalo (nome algoritmo vuoto): $base — salto"; continue; }
    MPI_ALGOS+=("${algo}:${f}")
  done
  log_info "Generatori MPI: ${#MPI_ALGOS[@]} trovati."
fi

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

# ---- helper formattazione ----
fmt_gb_no_sci() { awk -v b="$1" 'BEGIN{ s=sprintf("%.12f", b/1000000000.0); gsub(/0+$/,"",s); sub(/\.$/,"",s); if(s=="")s="0"; print s; }'; }
fmt_kb_no_sci() { awk -v b="$1" 'BEGIN{ s=sprintf("%.6f", b/1024.0); gsub(/0+$/,"",s); sub(/\.$/,"",s); if(s=="")s="0"; print s; }'; }

# ---- chunk fissi ----
generate_fixed_chunk_series() {
  local -a sizes_bytes=(
    $(( 8   * 1024 ))
    $(( 64  * 1024 ))
    $(( 128 * 1024 ))
    $(( 256 * 1024 ))
    $(( 512 * 1024 ))
    $(( 1024 * 1024 ))
    $(( 2    * 1024 * 1024 ))
    $(( 4    * 1024 * 1024 ))
  )
  printf "%s\n" "${sizes_bytes[@]}"
}
mapfile -t CHUNK_SERIES < <(generate_fixed_chunk_series)

# ---- pre-conteggio passi totali per progress [i/TOT] ----
NUM_CHUNKS=${#CHUNK_SERIES[@]}
NUM_MPI_ALGOS=${#MPI_ALGOS[@]}

TOTAL_STEPS=0
for RADIX_K in "${K_LIST[@]}"; do
  L=$(( RADIX_K / 2 )); S=$(( RADIX_K / 2 )); P=$(( RADIX_K / 2 ))
  HOSTS_PER_GROUP=$(( L * P ))
  GMAX=$(( (RADIX_K * RADIX_K) / 4 + 1 ))

  # Intervallo gruppi effettivo per questo K
  DEFAULT_G_MIN=2
  DEFAULT_G_MAX=$(( 4 <= GMAX ? 4 : GMAX ))
  # Applica override utente (intersezione con [2, GMAX])
  G_MIN=$DEFAULT_G_MIN
  G_MAX=$DEFAULT_G_MAX
  if [[ -n "$USER_MIN_GROUPS" ]]; then
    (( USER_MIN_GROUPS > G_MIN )) && G_MIN="$USER_MIN_GROUPS"
  fi
  if [[ -n "$USER_MAX_GROUPS" ]]; then
    (( USER_MAX_GROUPS < G_MAX )) && G_MAX="$USER_MAX_GROUPS"
  fi
  (( G_MIN < 2 )) && G_MIN=2
  (( G_MAX > GMAX )) && G_MAX=$GMAX
  if (( G_MAX < G_MIN )); then
    log_warn "K=$RADIX_K: range gruppi vuoto dopo i vincoli (richiesto ${USER_MIN_GROUPS:-2}..${USER_MAX_GROUPS:-$DEFAULT_G_MAX}, limite 2..${GMAX}) — salto K."
    continue
  fi

  for ((g=G_MIN; g<=G_MAX; g++)); do
    TOTAL_STEPS=$(( TOTAL_STEPS + NUM_CHUNKS ))                    # TE-CCL
    (( NUM_MPI_ALGOS > 0 )) && TOTAL_STEPS=$(( TOTAL_STEPS + NUM_MPI_ALGOS * NUM_CHUNKS ))  # MPI
  done
done

CURR=0
echo
log_info "== Sweep Df+ bilanciata (ordine: TCCL→MPI) su K in [${MIN_RADIX:-$SINGLE_RADIX}, ${MAX_RADIX:-$SINGLE_RADIX}] =="
if [[ -n "$USER_MIN_GROUPS" || -n "$USER_MAX_GROUPS" ]]; then
  log_info "Range gruppi richiesto: ${BOLD}${USER_MIN_GROUPS:-2}${RESET}..${BOLD}${USER_MAX_GROUPS:-4}${RESET} (sarà intersecato con 2..Gmax per ogni K)"
else
  log_info "Range gruppi default: ${BOLD}2..min(4, Gmax)${RESET}"
fi
log_info "Totale lanci previsti: ${BOLD}${TOTAL_STEPS}${RESET}"

# ---- sweep su K ----
for RADIX_K in "${K_LIST[@]}"; do
  L=$(( RADIX_K / 2 ))
  S=$(( RADIX_K / 2 ))
  P=$(( RADIX_K / 2 ))
  HOSTS_PER_GROUP=$(( L * P ))
  GMAX=$(( (RADIX_K * RADIX_K) / 4 + 1 ))

  # Calcolo range gruppi effettivo per questo K (come sopra)
  DEFAULT_G_MIN=2
  DEFAULT_G_MAX=$(( 4 <= GMAX ? 4 : GMAX ))
  G_MIN=$DEFAULT_G_MIN
  G_MAX=$DEFAULT_G_MAX
  if [[ -n "$USER_MIN_GROUPS" ]]; then
    (( USER_MIN_GROUPS > G_MIN )) && G_MIN="$USER_MIN_GROUPS"
  fi
  if [[ -n "$USER_MAX_GROUPS" ]]; then
    (( USER_MAX_GROUPS < G_MAX )) && G_MAX="$USER_MAX_GROUPS"
  fi
  (( G_MIN < 2 )) && G_MIN=2
  (( G_MAX > GMAX )) && G_MAX=$GMAX
  if (( G_MAX < G_MIN )); then
    log_warn "K=$RADIX_K: range gruppi vuoto (richiesto ${USER_MIN_GROUPS:-2}..${USER_MAX_GROUPS:-$DEFAULT_G_MAX}, limite 2..${GMAX}) — salto K."
    continue
  fi

  log_info "K=${BOLD}${RADIX_K}${RESET} ⇒ L=S=P=${BOLD}$L${RESET}, hosts/gruppo=${BOLD}${HOSTS_PER_GROUP}${RESET}, Gmax=${BOLD}${GMAX}${RESET} | gruppi: ${BOLD}${G_MIN}..${G_MAX}${RESET}"

  for ((g=G_MIN; g<=G_MAX; g++)); do
    N=$(( g * HOSTS_PER_GROUP ))
    NG="$g"; LR="$L"; SR="$S"; HPR="$P"

    log_info "  Config: N=${BOLD}${N}${RESET} ⇒ num_groups=${BOLD}${NG}${RESET}, leaf=${BOLD}${LR}${RESET}, spine=${BOLD}${SR}${RESET}, hosts_per_leaf=${BOLD}${HPR}${RESET}"

    # === 1) TE-CCL per tutti i chunk ===
    for S_BYTES in "${CHUNK_SERIES[@]}"; do
      S_GB="$(fmt_gb_no_sci "$S_BYTES")"
      S_KB="$(fmt_kb_no_sci "$S_BYTES")"

      CURR=$(( CURR + 1 ))
      TEC_TAG="groups${NG}_spine${SR}_leaf${LR}_host${HPR}_chunks1_size${S_BYTES}"
      TEC_DIR="${OUT_BASE}/${TEC_TAG}"
      mkdir -p "$TEC_DIR"

      echo
      echo "${BOLD}[$(ts)] [ ${CURR} / ${TOTAL_STEPS} ]${RESET} K=${RADIX_K} | N=${N} | NG=${NG} LR=${LR} SR=${SR} HPR=${HPR} | chunk=${S_GB} GB (${S_KB} KB)"
      log_info "TE-CCL: start  → ${BOLD}${CYAN}${TEC_TAG}${RESET}"
      {
        echo "[$(ts)] [CMD] run_pipeline.sh (log in tempo reale + file: ${TEC_DIR}/run_pipeline.log)"
        stdbuf -oL -eL $CONDA_RUN ./run_pipeline.sh \
          ${TOPO_BIN:+--topology "$TOPO_BIN"} \
          num_groups "$NG" spine_routers "$SR" leaf_routers "$LR" hosts_per_router "$HPR" \
          num_chunks 1 chunk_size "$S_GB" "${TECCL_EXTRA_ARGS[@]}" \
          --convert "$CONVERT_BIN" \
          --htsim "$HTSIM_BIN" "${HTSIM_ARGS[@]}" \
          --parser "$PARSER_PY" "$PARSER_SCRIPT" "${PARSER_ARGS[@]}"
      } 2>&1 | tee "${TEC_DIR}/run_pipeline.log"
      RC=${PIPESTATUS[0]}
      if (( RC == 0 )); then
        log_ok   "TE-CCL: completato  → ${BOLD}${CYAN}${TEC_TAG}${RESET}"
      else
        log_error "TE-CCL: rc=${RC}     → ${BOLD}${CYAN}${TEC_TAG}${RESET} (vedi ${TEC_DIR}/run_pipeline.log)"
      fi
    done

    # === 2) MPI per tutti gli algoritmi e tutti i chunk ===
    if (( NUM_MPI_ALGOS > 0 )); then
      for pair in "${MPI_ALGOS[@]}"; do
        algo="${pair%%:*}"
        gen_path="${pair#*:}"

        # Skip recdub se N non è potenza di 2
        is_pow2() { local n="$1"; (( n>0 && (n & (n-1)) == 0 )); }
        if [[ "$algo" == "recdub" ]] && ! is_pow2 "$N"; then
          log_warn "MPI[recdub]: N=${N} non è potenza di 2 → salto algoritmo per questa config."
          continue
        fi

        for S_BYTES in "${CHUNK_SERIES[@]}"; do
          S_GB="$(fmt_gb_no_sci "$S_BYTES")"
          S_KB="$(fmt_kb_no_sci "$S_BYTES")"
          MPI_P5=0
          MPI_P4=$(( S_BYTES * N ))

          CURR=$(( CURR + 1 ))
          MPI_TAG="mpi_${algo}_host${N}_chunks1_size${S_BYTES}"
          MPI_DIR="${OUT_BASE}/${MPI_TAG}"
          mkdir -p "$MPI_DIR"

          echo
          echo "${BOLD}[$(ts)] [ ${CURR} / ${TOTAL_STEPS} ]${RESET} K=${RADIX_K} | N=${N} | algo=${algo} | chunk=${S_GB} GB (${S_KB} KB)"
          log_info "MPI[${BOLD}${algo}${RESET}]: start → ${BOLD}${CYAN}${MPI_TAG}${RESET}  (p4=${BOLD}${MPI_P4}${RESET}, p5=${BOLD}${MPI_P5}${RESET})"
          {
            echo "[$(ts)] [CMD] run_mpi_pipeline.sh (log in tempo reale + file: ${MPI_DIR}/run_mpi_pipeline.log)"
            stdbuf -oL -eL $CONDA_RUN ./run_mpi_pipeline.sh \
              --gen "$gen_path" --n "$N" --chunks 1 \
              --chunk-size-bytes "$S_BYTES" \
              --p4 "$MPI_P4" --p5 "$MPI_P5" \
              --algo "$algo" \
              --s-df "$SR" --l-df "$LR" --h-df "$HPR" --p-df "$HPR" \
              --htsim "$HTSIM_BIN" "${HTSIM_ARGS[@]}" \
              --parser "$PARSER_PY" "$PARSER_SCRIPT" "${PARSER_ARGS[@]}"
          } 2>&1 | tee "${MPI_DIR}/run_mpi_pipeline.log"
          RC_MPI=${PIPESTATUS[0]}
          if (( RC_MPI == 0 )); then
            log_ok "MPI[${algo}]: completato  → ${BOLD}${CYAN}${MPI_TAG}${RESET}"
          else
            log_error "MPI[${algo}]: rc=${RC_MPI} → ${BOLD}${CYAN}${MPI_TAG}${RESET} (vedi ${MPI_DIR}/run_mpi_pipeline.log)"
          fi
        done
      done
    fi

  done
done

echo
log_ok "Sweep completato. Lanci eseguiti: ${BOLD}${CURR}/${TOTAL_STEPS}${RESET}. Output in ${BOLD}${CYAN}${OUT_BASE}/${RESET}"
