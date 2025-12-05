#!/usr/bin/env python3
# -*- coding: utf-8 -*-

"""
parse_runlog.py — HTSIM log parser + dipendenze da CM (COMPLETO, VERSIONE CORRETTA)

In questa versione:
- Rimossa completamente la gestione di “Start is …”
- Lo start time di un flusso è SOLO quello di:  startflow Roce_X_Y at T
- Nessuna sostituzione, nessuna conversione: quello è il tempo reale della simulazione.
"""

import argparse
import re
import csv
from collections import defaultdict, deque
import math
from pathlib import Path
import sys

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

# ---------------------------
# Regex log
# ---------------------------
STARTFLOW_RE = re.compile(r'^startflow\s+(\S+)\s+at\s+([0-9.eE+-]+)$')
FINISH_RE    = re.compile(r'^Flow\s+(\S+)\s+(\d+)\s+finished\s+at\s+([0-9.eE+-]+)\s+total\s+bytes\s+(\d+)$')
CONN_LOG_RE  = re.compile(r'^Connection\s+(\d+)->(\d+)\s+starting\s+at\s+([0-9.eE+-]+)\s+size\s+.*$')

UNIT_CHOICES = ("s", "ms", "us")

# ---------------------------
# Regex CM
# ---------------------------
CM_CONN_RE = re.compile(
    r'^\s*(\d+)->(\d+)\s+id\s+(\d+)\s+'
    r'(start\s+[0-9.eE+-]+|trigger\s+[0-9.eE+\-]+(?:\s+trigger\s+[0-9.eE+\-]+)*)\s+'
    r'size\s+(\d+)'
    r'(?:\s+send_done_trigger\s+(\d+))?\s*$'
)
CM_TRIG_DEF_RE = re.compile(r'^\s*trigger\s+id\s+(\d+)\s+oneshot\s*$', re.IGNORECASE)

# ---------------------------
# CLI
# ---------------------------
def parse_args():
    p = argparse.ArgumentParser(
        description="Parser HTSIM completo (deps/chain/summary/DOT/Gantt). Versione corretta senza Start is.",
        formatter_class=argparse.ArgumentDefaultsHelpFormatter
    )
    p.add_argument("logfile", help="File di log HTSIM")
    p.add_argument("--cmfile", required=True, help="Connection-matrix (.cm)")
    p.add_argument("--unit-finish", choices=UNIT_CHOICES, required=True,
                   help="Unità per i timestamp 'finished at' e per gli startflow.")
    p.add_argument("--unit-startis", choices=UNIT_CHOICES, required=False,
                   help="Ignorato. Presente solo per retrocompatibilità.", default="us")

    p.add_argument("--out-csv", required=True, help="CSV con flussi+deps")
    p.add_argument("--out-summary", required=True, help="Summary")
    p.add_argument("--out-dot", default=None, help="(Opzionale) Esporta grafo deps in DOT")

    p.add_argument("--plots-dir", default=None, help="Cartella per il Gantt per catena")
    p.add_argument("--gantt-max-flows", type=int, default=200)

    p.add_argument("--n-hosts", type=int, required=True)
    p.add_argument("--num-chunks", type=int, required=True)
    p.add_argument("--chunk-size-bytes", type=int, required=True)
    return p.parse_args()


# ---------------------------
# Utils
# ---------------------------
def to_seconds(val_str, unit):
    t = float(val_str)
    if unit == "s":  return t
    if unit == "ms": return t / 1e3
    if unit == "us": return t / 1e6
    return t

def bytes_to_gb_decimal(b):
    return float(b) / 1_000_000_000.0


def split_flow_name(flow_name):
    parts = flow_name.split("_")
    if len(parts) >= 3 and parts[0].lower().startswith("roce"):
        return parts[1], parts[2]
    return None, None


def _ensure_outdir(outdir: Path):
    outdir.mkdir(parents=True, exist_ok=True)

def _ensure_parent(path: Path):
    path.parent.mkdir(parents=True, exist_ok=True)


# ---------------------------
# Parse CM
# ---------------------------
def parse_cm(cm_path: Path):
    conns = {}
    trig_producers = defaultdict(set)
    trig_consumers = defaultdict(set)
    trigger_defs = set()
    sd_index = defaultdict(deque)

    with cm_path.open("r", encoding="utf-8", errors="ignore") as f:
        for raw in f:
            line = raw.strip()
            if not line:
                continue

            mdef = CM_TRIG_DEF_RE.match(line)
            if mdef:
                trigger_defs.add(int(mdef.group(1)))
                continue

            m = CM_CONN_RE.match(line)
            if not m:
                continue

            s = int(m.group(1))
            d = int(m.group(2))
            conn_id = int(m.group(3))
            start_or_trig = m.group(4)
            size = int(m.group(5))
            send_done = m.group(6)

            wait_triggers = set()
            if start_or_trig.startswith("trigger"):
                trig_ids = re.findall(r'trigger\s+([0-9.eE+\-]+)', start_or_trig)
                for tid in trig_ids:
                    wait_triggers.add(int(float(tid)))

            fire_triggers = set()
            if send_done is not None:
                fire_triggers.add(int(send_done))

            conns[conn_id] = {
                "src": s,
                "dst": d,
                "size": size,
                "wait_triggers": wait_triggers,
                "fire_triggers": fire_triggers,
            }

            sd_index[(s, d)].append(conn_id)

            for t in wait_triggers:
                trig_consumers[t].add(conn_id)
            for t in fire_triggers:
                trig_producers[t].add(conn_id)

    return conns, trig_producers, trig_consumers, trigger_defs, sd_index


# ---------------------------
# Dipendenze
# ---------------------------
def build_dependency_graph(conns, trig_producers, trig_consumers):
    preds = defaultdict(set)
    succs = defaultdict(set)

    for t, producers in trig_producers.items():
        consumers = trig_consumers[t]
        for p in producers:
            for c in consumers:
                preds[c].add(p)
                succs[p].add(c)

    for cid in conns:
        preds.setdefault(cid, set())
        succs.setdefault(cid, set())

    return preds, succs


def topo_order(preds, succs):
    indeg = {u: len(preds[u]) for u in preds}
    q = deque([u for u in preds if indeg[u] == 0])
    order = []
    while q:
        u = q.popleft()
        order.append(u)
        for v in succs[u]:
            indeg[v] -= 1
            if indeg[v] == 0:
                q.append(v)
    for u in preds:
        if u not in order:
            order.append(u)
    return order


def compute_depth(order, preds):
    depth = {u: 0 for u in preds}
    for u in order:
        if preds[u]:
            depth[u] = max(depth[p] + 1 for p in preds[u])
    return depth


def build_chains_from_roots(preds, succs):
    indeg = {u: len(preds[u]) for u in preds}
    outdeg = {u: len(succs[u]) for u in succs}
    roots = [u for u in preds if indeg[u] == 0 and outdeg[u] > 0]

    chain_id_of = {}
    chain_pos_of = {}
    chains = defaultdict(list)

    for r in sorted(roots):
        q = deque([(r, 0)])
        if r not in chain_id_of:
            chain_id_of[r] = r
            chain_pos_of[r] = 0
            chains[r].append(r)

        while q:
            u, dist = q.popleft()
            for v in succs[u]:
                nd = dist + 1
                if v not in chain_id_of:
                    chain_id_of[v] = r
                    chain_pos_of[v] = nd
                    chains[r].append(v)
                    q.append((v, nd))

    return chain_id_of, chain_pos_of, dict(chains)


# ---------------------------
# Gantt
# ---------------------------
def _try_savefig(path: Path):
    try:
        plt.tight_layout()
        plt.savefig(path, dpi=160)
    except Exception as e:
        print(f"[PLOT] ERRORE {path}: {e}")
    finally:
        plt.close()


def plot_gantt_by_chain(rows, outdir: Path, max_flows=200):
    good = [
        r for r in rows
        if r["start_time_s"] is not None and r["finish_time_s"] is not None
        and r["finish_time_s"] >= r["start_time_s"]
    ]
    if not good:
        print("[PLOT] Nessun intervallo valido")
        return

    chain = [r for r in good if r["chain_id"] != -1]
    solo  = [r for r in good if r["chain_id"] == -1]

    chain.sort(key=lambda r: (r["chain_id"], r["chain_pos"], r["start_time_s"]))
    solo.sort(key=lambda r: r["start_time_s"])

    ordered = (chain + solo)[:max_flows]

    plt.figure(figsize=(11, max(4, min(14, int(len(ordered)*0.13)))))
    labels = []
    for i, r in enumerate(ordered):
        s = r["start_time_s"]
        dur = r["finish_time_s"] - s
        plt.barh(i, dur, left=s)
        if r["chain_id"] != -1:
            label = f"c{r['chain_id']}: id{r['conn_id']} ({r['flow_name']})"
        else:
            label = f"solo: id{r['conn_id']} ({r['flow_name']})"
        labels.append(label[:70])

    plt.yticks(range(len(ordered)), labels, fontsize=7)
    plt.xlabel("Tempo (s)")
    plt.title("Gantt (chain + solo)")
    _ensure_outdir(outdir)
    _try_savefig(outdir / "gantt_by_chain.png")


# ---------------------------
# LOG + CM join
# ---------------------------
def parse_log_and_join(log_path, unit_finish,
                       cm_conns, preds, succs, chain_id_of, chain_pos_of, sd_index):
    starts = defaultdict(deque)
    rows = []

    min_start = None
    max_finish = None

    unmatched = 0

    with log_path.open("r", encoding="utf-8", errors="ignore") as f:
        for raw in f:
            line = raw.strip()
            if not line:
                continue

            if CONN_LOG_RE.match(line):
                continue

            m_sf = STARTFLOW_RE.match(line)
            if m_sf:
                flow = m_sf.group(1)
                t = to_seconds(m_sf.group(2), unit_finish)
                starts[flow].append(t)
                if min_start is None or t < min_start:
                    min_start = t
                continue

            m_fin = FINISH_RE.match(line)
            if m_fin:
                flow = m_fin.group(1)
                log_id = int(m_fin.group(2))
                finish_t = to_seconds(m_fin.group(3), unit_finish)
                bytes_ = int(m_fin.group(4))

                if starts[flow]:
                    start_t = starts[flow].popleft()
                else:
                    start_t = None
                    unmatched += 1

                src, dst = split_flow_name(flow)
                s = int(src) if src else None
                d = int(dst) if dst else None
                conn_id = None

                if s is not None and d is not None:
                    dq = sd_index.get((s, d), deque())
                    if dq:
                        conn_id = dq.popleft()

                if conn_id is None and log_id in cm_conns:
                    conn_id = log_id

                cm_src = cm_dst = cm_size = None
                wait_triggers = fire_triggers = []
                predecessors = successors = []
                indeg = outdeg = 0
                chain_id = chain_pos = -1

                if conn_id is not None and conn_id in cm_conns:
                    meta = cm_conns[conn_id]
                    cm_src = meta["src"]
                    cm_dst = meta["dst"]
                    cm_size = meta["size"]
                    wait_triggers = meta["wait_triggers"]
                    fire_triggers = meta["fire_triggers"]
                    predecessors = preds[conn_id]
                    successors = succs[conn_id]
                    indeg = len(predecessors)
                    outdeg = len(successors)
                    chain_id = chain_id_of.get(conn_id, -1)
                    chain_pos = chain_pos_of.get(conn_id, -1)

                if max_finish is None or finish_t > max_finish:
                    max_finish = finish_t

                if start_t is not None:
                    dur = finish_t - start_t
                    thr = (bytes_ * 8) / dur if dur > 0 else float("nan")
                else:
                    dur = float("nan")
                    thr = float("nan")

                rows.append({
                    "flow_name": flow,
                    "src": src,
                    "dst": dst,
                    "log_internal_id": log_id,
                    "conn_id": conn_id if conn_id is not None else -1,
                    "start_time_s": start_t,
                    "finish_time_s": finish_t,
                    "duration_s": dur,
                    "total_bytes": bytes_,
                    "throughput_bps": thr,
                    "throughput_Mbps": thr / 1e6 if not math.isnan(thr) else float("nan"),
                    "throughput_Gbps": thr / 1e9 if not math.isnan(thr) else float("nan"),
                    "cm_src": cm_src,
                    "cm_dst": cm_dst,
                    "cm_size": cm_size,
                    "wait_triggers": ";".join(map(str, wait_triggers)),
                    "fire_triggers": ";".join(map(str, fire_triggers)),
                    "indegree": indeg,
                    "outdegree": outdeg,
                    "chain_id": chain_id,
                    "chain_pos": chain_pos,
                })

    thr_list = [r["throughput_Mbps"] for r in rows if not math.isnan(r["throughput_Mbps"])]
    if thr_list:
        mean_thr = sum(thr_list) / len(thr_list)
        var_thr = sum((x - mean_thr)**2 for x in thr_list) / max(1, len(thr_list)-1)
        std_thr = math.sqrt(var_thr)
        jain = (sum(thr_list)**2) / (len(thr_list) * sum(x**2 for x in thr_list))
    else:
        mean_thr = std_thr = jain = float("nan")

    makespan = max_finish - min_start if min_start is not None else float("nan")

    diag = {
        "unmatched_finishes": unmatched,
        "min_start_sec": min_start,
        "max_finish_sec": max_finish,
        "makespan_s": makespan,
        "mean_Mbps": mean_thr,
        "std_Mbps": std_thr,
        "jain": jain,
        "n_results": len(rows),
        "n_valid": len(thr_list)
    }
    return rows, diag


# ---------------------------
# Export CSV
# ---------------------------
def write_csv(rows, path):
    fn = [
        "flow_name","src","dst","log_internal_id","conn_id",
        "start_time_s","finish_time_s","duration_s",
        "total_bytes","throughput_bps","throughput_Mbps","throughput_Gbps",
        "cm_src","cm_dst","cm_size",
        "wait_triggers","fire_triggers",
        "indegree","outdegree","chain_id","chain_pos","depth"
    ]
    _ensure_parent(path)
    with path.open("w", newline="", encoding="utf-8") as f:
        w = csv.DictWriter(f, fieldnames=fn)
        w.writeheader()
        for r in rows:
            w.writerow(r)


# ---------------------------
# Summary
# ---------------------------
def write_summary(diag, out_path, cm_stats, chain_stats, out_csv_path,
                  n_hosts, num_chunks, chunk_size_bytes):

    _ensure_parent(out_path)
    size_gb = bytes_to_gb_decimal(chunk_size_bytes)

    with out_path.open("w", encoding="utf-8") as f:
        f.write("== Statistiche Parsing ==\n")
        f.write(f"Host: {n_hosts}\n")
        f.write(f"Chunk: {num_chunks}\n")
        f.write(f"Chunk size: {chunk_size_bytes} bytes ({size_gb:.6f} GB)\n")
        f.write(f"Flussi totali: {diag['n_results']}\n")
        f.write(f"Flussi validi (throughput): {diag['n_valid']}\n")
        f.write(f"Mean throughput (Mbps): {diag['mean_Mbps']:.6f}\n")
        f.write(f"Std throughput (Mbps): {diag['std_Mbps']:.6f}\n")
        f.write(f"Fairness Jain: {diag['jain']:.6f}\n")
        f.write(f"Makespan (s): {diag['makespan_s']:.6f}\n")
        f.write(f"Min start: {diag['min_start_sec']}\n")
        f.write(f"Max finish: {diag['max_finish_sec']}\n")
        f.write(f"Finish senza start: {diag['unmatched_finishes']}\n")
        f.write(f"CSV: {out_csv_path.resolve()}\n")

        f.write("\n== CM ==\n")
        f.write(f"Connessioni in CM: {cm_stats['n_conns']}\n")
        f.write(f"Trigger definiti: {cm_stats['n_trig_defs']}\n")
        f.write(f"Trigger producers: {cm_stats['n_trig_prod']}\n")
        f.write(f"Trigger consumers: {cm_stats['n_trig_cons']}\n")
        f.write(f"Archi nel grafo: {cm_stats['n_edges']}\n")
        f.write(f"Radici: {cm_stats['n_roots']}\n")

        f.write("\n== Catene ==\n")
        f.write(f"Numero catene: {chain_stats['n_chains']}\n")
        f.write(f"Lunghezza max: {chain_stats['max_chain_len']}\n")
        f.write(f"Lunghezza media: {chain_stats['avg_chain_len']:.2f}\n")
        f.write(f"Profondità max: {chain_stats['max_chain_depth']}\n")
        f.write(f"Profondità media: {chain_stats['avg_chain_depth']:.2f}\n")


# ---------------------------
# DOT
# ---------------------------
def export_dot(preds, succs, out_dot_path):
    _ensure_parent(out_dot_path)
    with out_dot_path.open("w", encoding="utf-8") as f:
        f.write("digraph deps {\n  rankdir=LR;\n")
        for u in preds:
            f.write(f"  n{u} [label=\"{u}\"];\n")
        for u, outs in succs.items():
            for v in outs:
                f.write(f"  n{u} -> n{v};\n")
        f.write("}\n")


# ---------------------------
# MAIN
# ---------------------------
def main():
    args = parse_args()

    log_path = Path(args.logfile)
    cm_path = Path(args.cmfile)
    out_csv_path = Path(args.out_csv)
    out_summary_path = Path(args.out_summary)

    if not log_path.exists():
        print("Log mancante:", log_path)
        sys.exit(1)
    if not cm_path.exists():
        print("CM mancante:", cm_path)
        sys.exit(1)

    cm_conns, trig_producers, trig_consumers, trig_defs, sd_index = parse_cm(cm_path)
    preds, succs = build_dependency_graph(cm_conns, trig_producers, trig_consumers)
    order = topo_order(preds, succs)
    depth = compute_depth(order, preds)
    chain_id_of, chain_pos_of, chains = build_chains_from_roots(preds, succs)

    rows, diag = parse_log_and_join(
        log_path,
        args.unit_finish,
        cm_conns, preds, succs, chain_id_of, chain_pos_of, sd_index
    )

    for r in rows:
        cid = r["conn_id"]
        r["depth"] = depth.get(cid, 0)

    write_csv(rows, out_csv_path)

    cm_stats = {
        "n_conns": len(cm_conns),
        "n_trig_defs": len(trig_defs),
        "n_trig_prod": len([t for t in trig_producers if trig_producers[t]]),
        "n_trig_cons": len([t for t in trig_consumers if trig_consumers[t]]),
        "n_edges": sum(len(succs[u]) for u in succs),
        "n_roots": len([u for u in preds if len(preds[u]) == 0 and len(succs[u]) > 0]),
    }

    chain_lens = [len(v) for v in chains.values()] if chains else []
    chain_depths = []
    for root, members in chains.items():
        if members:
            chain_depths.append(1 + max(chain_pos_of[m] for m in members))
        else:
            chain_depths.append(0)

    chain_stats = {
        "n_chains": len(chains),
        "max_chain_len": max(chain_lens) if chain_lens else 0,
        "avg_chain_len": (sum(chain_lens) / len(chain_lens)) if chain_lens else 0,
        "max_chain_depth": max(chain_depths) if chain_depths else 0,
        "avg_chain_depth": (sum(chain_depths) / len(chain_depths)) if chain_depths else 0,
    }

    write_summary(diag, out_summary_path, cm_stats, chain_stats,
                  out_csv_path,
                  args.n_hosts, args.num_chunks, args.chunk_size_bytes)

    if args.out_dot:
        export_dot(preds, succs, Path(args.out_dot))

    if args.plots_dir:
        plot_gantt_by_chain(rows, Path(args.plots_dir), max_flows=args.gantt_max_flows)

    print("[OK] Completato.")


if __name__ == "__main__":
    main()
