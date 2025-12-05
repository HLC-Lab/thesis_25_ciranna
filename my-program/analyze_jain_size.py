#!/usr/bin/env python3
import re
import csv
import argparse
from pathlib import Path
import sys
import matplotlib.pyplot as plt

# ========= ANSI / colori =========

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
    BOLD = RESET = GREEN = YELLOW = RED = CYAN = ""

def info(msg: str):
    print(f"{CYAN}{BOLD}[INFO]{RESET} {msg}")

def ok(msg: str):
    print(f"{GREEN}{BOLD}[OK]  {RESET} {msg}")

def warn(msg: str):
    print(f"{YELLOW}{BOLD}[WARN]{RESET} {msg}")

def error(msg: str):
    print(f"{RED}{BOLD}[ERROR]{RESET} {msg}", file=sys.stderr)

# ========= regex directory =========
# TE-CCL: groups2_spine2_leaf2_host4_chunks1_size262144
TECCl_DIR_RE = re.compile(
    r"^groups(?P<ng>\d+)_spine(?P<sr>\d+)_leaf(?P<lr>\d+)"
    r"_host(?P<hpr>\d+)_chunks(?P<chunks>\d+)_size(?P<size>\d+)$"
)

# MPI: mpi_ring_host16_chunks1_size262144
MPI_DIR_RE = re.compile(
    r"^(?P<impl>mpi_[a-zA-Z0-9]+)_host(?P<hosts>\d+)_chunks(?P<chunks>\d+)_size(?P<size>\d+)$"
)

# ========= util =========

def is_power_of_two(n: int) -> bool:
    return n > 0 and (n & (n - 1)) == 0

# ========= parser summary_*.txt =========
def parse_summary_file(path: Path):
    """
    Ritorna dict con:
      hosts,
      size_bytes,
      jain
    """
    hosts = None
    size_bytes = None
    jain = None

    try:
        text = path.read_text()
    except Exception:
        return None

    for line in text.splitlines():
        line = line.strip()

        # Host: 8
        if line.startswith("Host:"):
            try:
                hosts = int(line.split(":", 1)[1].strip())
            except:
                pass

        # Chunk size: 8192 bytes (0.000008 GB)
        elif line.startswith("Chunk size:"):
            try:
                # prende solo il numero prima di "bytes"
                num = line.split(":",1)[1].strip().split()[0]
                size_bytes = int(num)
            except:
                pass

        # Fairness Jain: 0.434380
        elif line.startswith("Fairness Jain:"):
            try:
                jain = float(line.split(":",1)[1].strip())
            except:
                pass

    if size_bytes is None or jain is None:
        return None

    return {
        "hosts": hosts,
        "size_bytes": size_bytes,
        "jain": jain,
    }


# ========= estrazione impl/host/size da directory =========

def detect_impl_and_hosts(dirname: str):
    """
    Ritorna (impl, hosts, size_from_dir) se la directory è riconosciuta,
    altrimenti (None, None, None).
    """
    m_mpi = MPI_DIR_RE.match(dirname)
    if m_mpi:
        impl = m_mpi.group("impl")              # es. mpi_ring, mpi_bruck, mpi_recdub, mpi_bine
        hosts = int(m_mpi.group("hosts"))
        size = int(m_mpi.group("size"))
        return impl, hosts, size

    m_teccl = TECCl_DIR_RE.match(dirname)
    if m_teccl:
        ng = int(m_teccl.group("ng"))
        lr = int(m_teccl.group("lr"))
        hpr = int(m_teccl.group("hpr"))
        size = int(m_teccl.group("size"))
        hosts = ng * lr * hpr
        return "teccl", hosts, size

    return None, None, None

# ========= plotting =========

MARKERS = {
    "mpi_ring": "o",
    "mpi_bruck": "s",
    "mpi_bine": "D",
    "mpi_recdub": "^",
    "teccl": "x",
}

# Ordine fisso per coerenza visuale
PLOT_ORDER = ["mpi_ring", "mpi_bruck", "mpi_bine", "mpi_recdub", "teccl"]

def plot_host_group(host_val, impl_map, outdir: Path):
    """
    impl_map: { impl_name: [ {size_bytes, jain}, ... ] }
    Crea il plot Fairness di Jain vs size (KiB) per questo numero di host.
    Usa un leggero jitter sull'asse X per non sovrapporre le serie.
    """
    # lista ordinata di implementazioni effettivamente presenti
    impl_list = [impl for impl in PLOT_ORDER if impl in impl_map] + \
                [impl for impl in sorted(impl_map.keys()) if impl not in PLOT_ORDER]

    plt.figure(figsize=(8, 5))
    any_series = False

    # calcola span X per jitter
    all_sizes = []
    for items in impl_map.values():
        all_sizes.extend([it["size_bytes"] for it in items])
    if all_sizes:
        min_x = min(all_sizes) / 1024.0
        max_x = max(all_sizes) / 1024.0
        span = max(max_x - min_x, 1e-9)
    else:
        span = 1.0
    base_jitter = span * 0.01  # 1% dello span totale

    n_impl = len(impl_list)

    for idx, impl_name in enumerate(impl_list):
        items = impl_map.get(impl_name, [])
        if not items:
            continue

        items_sorted = sorted(items, key=lambda x: x["size_bytes"])
        xs_bytes = [it["size_bytes"] for it in items_sorted]
        ys = [it["jain"] for it in items_sorted]

        if not xs_bytes or not ys:
            continue

        xs_kib = [b / 1024.0 for b in xs_bytes]

        # jitter centrato: implementazioni diverse hanno piccoli shift diversi
        shift = (idx - (n_impl - 1) / 2.0) * base_jitter
        xs_kib_jittered = [x + shift for x in xs_kib]

        marker = MARKERS.get(impl_name, "o")

        plt.plot(
            xs_kib_jittered,
            ys,
            marker=marker,
            linestyle="-",
            markersize=6,
            linewidth=1.6,
            label=impl_name,
        )
        any_series = True

    if not any_series:
        warn(f"[host={host_val}] Nessuna serie plottabile, nessun grafico generato.")
        plt.close()
        return

    plt.xlabel("Chunk size (KiB)", fontsize=11)
    plt.ylabel("Fairness di Jain", fontsize=11)
    plt.title(f"Fairness di Jain vs size – host={host_val}", fontsize=13, pad=10)
    plt.grid(True, which="both", linestyle="--", alpha=0.3)

    # Jain di solito in [0,1]; lasciamo un po' di margine sopra
    plt.ylim(0.0, 1.05)

    plt.legend(
        title="implementazione",
        fontsize=9,
        title_fontsize=9,
        frameon=True,
        fancybox=True,
        framealpha=0.85,
        loc="best",
    )

    plt.xticks(fontsize=9)
    plt.yticks(fontsize=9)
    plt.tight_layout()

    out_path = outdir / f"jain_vs_size_host{host_val}.png"
    plt.savefig(out_path, dpi=160, bbox_inches="tight")
    plt.close()
    ok(f"Plot host={host_val} salvato: {out_path} (Y = Fairness di Jain, X = KiB)")

# ========= main =========

def main():
    ap = argparse.ArgumentParser(
        description="Analisi Fairness di Jain vs size per tutte le implementazioni e host"
    )
    ap.add_argument("--root", type=Path, required=True,
                    help="Directory output_pipeline/ da analizzare")
    ap.add_argument("--outdir", type=Path, required=True,
                    help="Directory dove salvare CSV e plot")
    args = ap.parse_args()

    info("Avvio analisi Fairness di Jain vs size")
    info(f"Root:   {args.root}")
    info(f"Outdir: {args.outdir}")

    args.outdir.mkdir(parents=True, exist_ok=True)

    rows = []
    scanned_dirs = 0
    summary_ok = 0

    for sub in sorted(args.root.iterdir()):
        if not sub.is_dir():
            continue

        dirname = sub.name
        impl, hosts_from_dir, size_from_dir = detect_impl_and_hosts(dirname)
        if impl is None:
            continue

        scanned_dirs += 1

        # mpi_recdub solo per potenze di due
        if impl == "mpi_recdub" and not is_power_of_two(hosts_from_dir):
            warn(f"[{dirname}] mpi_recdub con hosts={hosts_from_dir} non è potenza di due: ignorata.")
            continue

        summaries = list(sub.glob("summary_*.txt"))
        if not summaries:
            continue

        for sm in summaries:
            parsed = parse_summary_file(sm)
            if not parsed:
                warn(f"Impossibile parsare {sm}")
                continue

            summary_ok += 1

            if parsed["hosts"] is not None and parsed["hosts"] != hosts_from_dir:
                warn(
                    f"[{dirname}] Mismatch hosts: dir={hosts_from_dir}, summary={parsed['hosts']} (uso dir)"
                )

            size_bytes = parsed["size_bytes"]
            if size_from_dir is not None and size_from_dir != size_bytes:
                warn(
                    f"[{dirname}] Mismatch size: dir={size_from_dir}, summary={size_bytes} (uso summary)"
                )

            rows.append({
                "dir": str(sub),
                "dirname": dirname,
                "impl": impl,
                "summary_file": sm.name,
                "hosts": hosts_from_dir,
                "size_bytes": size_bytes,
                "jain": parsed["jain"],
            })

    info(f"Cartelle esperimenti riconosciute: {scanned_dirs}")
    info(f"Summary validi letti:             {summary_ok}")

    if not rows:
        warn("Nessun dato valido trovato. Esco.")
        return

    # CSV globale
    csv_all = args.outdir / "jain_all.csv"
    with csv_all.open("w", newline="") as f:
        w = csv.DictWriter(
            f,
            fieldnames=[
                "dir", "dirname", "impl", "summary_file",
                "hosts", "size_bytes", "jain",
            ],
        )
        w.writeheader()
        w.writerows(rows)
    ok(f"CSV globale: {csv_all}")

    # Raggruppo per host
    by_hosts = {}
    for r in rows:
        by_hosts.setdefault(r["hosts"], []).append(r)

    info(f"Host distinti trovati: {sorted(by_hosts.keys())}")

    # Per ogni host: CSV + plot
    for host_val, host_rows in sorted(by_hosts.items()):
        impl_map = {}
        for r in host_rows:
            impl_map.setdefault(r["impl"], []).append({
                "size_bytes": r["size_bytes"],
                "jain": r["jain"],
            })

        counts_str = ", ".join(
            f"{impl}={len(pts)}" for impl, pts in sorted(impl_map.items())
        )
        info(f"[host={host_val}] punti per implementazione: {counts_str}")

        # CSV per host
        csv_host = args.outdir / f"jain_host{host_val}.csv"
        with csv_host.open("w", newline="") as f:
            w = csv.DictWriter(
                f,
                fieldnames=[
                    "impl", "size_bytes", "jain",
                    "dirname", "summary_file",
                ],
            )
            w.writeheader()
            for r in sorted(
                host_rows,
                key=lambda x: (x["impl"], x["size_bytes"])
            ):
                w.writerow({
                    "impl": r["impl"],
                    "size_bytes": r["size_bytes"],
                    "jain": r["jain"],
                    "dirname": r["dirname"],
                    "summary_file": r["summary_file"],
                })
        ok(f"CSV host={host_val}: {csv_host}")

        # Plot
        plot_host_group(host_val, impl_map, args.outdir)

    ok("Analisi completata.")

if __name__ == "__main__":
    main()
