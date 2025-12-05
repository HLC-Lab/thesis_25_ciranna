#!/usr/bin/env python3
import re
import csv
import argparse
import statistics
from pathlib import Path
import sys
import matplotlib.pyplot as plt

# =========================
# ANSI / colori
# =========================

def _supports_color() -> bool:
    return sys.stdout.isatty()

if _supports_color():
    BOLD   = "\033[1m"
    RESET  = "\033[0m"
    GREEN  = "\033[92m"
    YELLOW = "\033[93m"
    RED    = "\033[91m"
    CYAN   = "\033[96m"
else:
    # nessun colore se non è tty
    BOLD = RESET = GREEN = YELLOW = RED = CYAN = ""

def info(msg: str):
    print(f"{CYAN}{BOLD}[INFO]{RESET} {msg}")

def ok(msg: str):
    print(f"{GREEN}{BOLD}[OK]  {RESET} {msg}")

def warn(msg: str):
    print(f"{YELLOW}{BOLD}[WARN]{RESET} {msg}")

def error(msg: str):
    print(f"{RED}{BOLD}[ERROR]{RESET} {msg}", file=sys.stderr)

# =========================
# regex per i nomi delle cartelle TE-CCL
# =========================
TAG_RE = re.compile(
    r"groups(?P<ng>\d+)_spine(?P<sr>\d+)_leaf(?P<lr>\d+)_host(?P<hpr>\d+)_chunks(?P<chunks>\d+)_size(?P<size>\d+)"
)

def parse_tag(tag: str):
    m = TAG_RE.search(tag)
    if not m:
        return None
    d = {k: int(v) for k, v in m.groupdict().items()}
    d["nodes"] = d["ng"] * d["lr"] * d["hpr"]
    return d

# =========================
# raccolta dati
# =========================
def collect_rows(root: Path):
    """Legge TUTTI i solver_time_*.txt sotto root (non filtrati)."""
    rows = []
    for txt in sorted(root.rglob("solver_time_*.txt")):
        tag = txt.parent.name
        meta = parse_tag(tag)
        if not meta:
            continue
        try:
            st = float(txt.read_text().strip())
        except Exception:
            continue
        rows.append({
            "tag": tag,
            "nodes": meta["nodes"],
            "num_groups": meta["ng"],
            "spine": meta["sr"],
            "leaf": meta["lr"],
            "hpr": meta["hpr"],
            "num_chunks": meta["chunks"],
            "chunk_bytes": meta["size"],
            "solver_time": st,
            "path": str(txt),
        })
    return rows

def filter_by_size(rows, size_val: int):
    return [r for r in rows if r["chunk_bytes"] == size_val]

def aggregate_per_N(rows):
    """Per ogni N fa la mediana dei solver_time."""
    byN = {}
    for r in rows:
        byN.setdefault(r["nodes"], []).append(r["solver_time"])
    perN = []
    for N in sorted(byN.keys()):
        vals = byN[N]
        rep = statistics.median(vals)
        perN.append({
            "nodes": N,
            "solver_time": rep,
            "st_min": min(vals),
            "st_max": max(vals),
            "count": len(vals),
        })
    return perN

def choose_time_unit(perN):
    if not perN:
        return "s", 1.0
    mx = max(r["solver_time"] for r in perN)
    if mx < 1.0:
        return "ms", 1000.0
    elif mx > 120.0:
        return "min", 1.0/60.0
    else:
        return "s", 1.0

def plot_perN(perN, out_path: Path):
    xs = [r["nodes"] for r in perN]
    ys_s = [r["solver_time"] for r in perN]

    unit, factor = choose_time_unit(perN)
    ys = [y*factor for y in ys_s]

    plt.figure()
    plt.plot(xs, ys, marker="o", linestyle="-")
    # barre min-max
    for x, r in zip(xs, perN):
        if r["st_min"] != r["st_max"]:
            plt.vlines(x, r["st_min"]*factor, r["st_max"]*factor, alpha=0.4)
    plt.xlabel("N (numero host)")
    if unit == "ms":
        plt.ylabel("Solver_Time (ms)")
    elif unit == "min":
        plt.ylabel("Solver_Time (min)")
    else:
        plt.ylabel("Solver_Time (s)")
    plt.title("Solver_Time vs N")
    plt.grid(True, alpha=0.25)
    plt.tight_layout()
    plt.savefig(out_path, dpi=150, bbox_inches="tight")
    plt.close()
    ok(f"Plot salvato: {out_path} (unità: {unit})")

# =========================
# main
# =========================
def main():
    ap = argparse.ArgumentParser(
        description="TE-CCL — parser tempi di solver per una sola size"
    )
    ap.add_argument("--root", type=Path, required=True,
                    help="Directory radice dove cercare i solver_time_*.txt")
    ap.add_argument("--outdir", type=Path, required=True,
                    help="Directory dove salvare CSV e plot")
    ap.add_argument("--size", type=int, required=True,
                    help="Valore di 'size' da filtrare (es: 53687091)")
    args = ap.parse_args()

    info("Avvio parser solver_time")
    info(f"Root:   {args.root}")
    info(f"Outdir: {args.outdir}")
    info(f"Size:   {args.size}")

    # crea output
    args.outdir.mkdir(parents=True, exist_ok=True)

    # 1) leggo TUTTI
    rows_all = collect_rows(args.root)
    total_files = len(rows_all)
    info(f"File solver_time_* trovati (TUTTI): {total_files}")

    # 2) filtro per size
    rows = filter_by_size(rows_all, args.size)
    matched_files = len(rows)
    info(f"File utilizzati (size={args.size}): {matched_files}")

    if matched_files == 0:
        warn("Nessun file corrisponde alla size richiesta. Interrompo.")
        return

    # 3) salvo CSV grezzo (solo quelli filtrati)
    raw_csv = args.outdir / f"solver_times_size{args.size}.csv"
    with raw_csv.open("w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=list(rows[0].keys()))
        w.writeheader()
        w.writerows(rows)
    ok(f"CSV (filtrato): {raw_csv}")

    # 4) aggrego per N
    perN = aggregate_per_N(rows)
    if not perN:
        warn("Nessun dato aggregato per N. Stop.")
        return

    # 5) salvo CSV aggregato
    agg_csv = args.outdir / f"solver_times_perN_size{args.size}.csv"
    with agg_csv.open("w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=["nodes","solver_time","st_min","st_max","count"])
        w.writeheader()
        w.writerows(perN)
    ok(f"CSV per-N: {agg_csv}")

    # 6) plot
    plot_path = args.outdir / f"solver_time_vs_N_size{args.size}.png"
    plot_perN(perN, plot_path)

    ok("Completato.")

if __name__ == "__main__":
    main()
