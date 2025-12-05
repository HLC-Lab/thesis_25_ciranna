// simulateAllSchedule.c
// Simula uno schedule TE-CCL (8-Chunk paths) con MPI non-bloccante per epoca
// e confronta il risultato con MPI_Allgather.
// Build:
//   mpicc -O2 -Wall -Wextra -DDEBUG_SIM \
//     -o simulateAllSchedule simulateAllSchedule.c ../cJSON/cJSON.c -I../cJSON
// Run:
//   mpirun --oversubscribe -np N ./simulateAllSchedule config.json schedule.json

#include <mpi.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include "../cJSON/cJSON.h"

#ifndef MAX_PRINT_ELEMS
#define MAX_PRINT_ELEMS 32
#endif

int my_rank = 0;

#ifdef DEBUG_SIM
  #define DBG(fmt, ...) fprintf(stderr, "[DBG r%d] " fmt "\n", my_rank, ##__VA_ARGS__)
#else
  #define DBG(...) do{}while(0)
#endif

typedef struct {
    int num_chunks;
    int num_epochs;
    int chunk_size; // bytes
} ConfigParams;

typedef struct {
    int src, dst, epoch, seq;
    int origin, chunk;
} Msg;

// ----------------- IO sicura -----------------
static char* slurp(const char* path, size_t* out_len) {
    FILE* f = fopen(path, "rb");
    if (!f) return NULL;
    fseek(f, 0, SEEK_END);
    long n = ftell(f);
    fseek(f, 0, SEEK_SET);
    if (n < 0) { fclose(f); return NULL; }
    char* buf = (char*)malloc((size_t)n + 1);
    if (!buf) { fclose(f); return NULL; }
    size_t rd = fread(buf, 1, (size_t)n, f);
    fclose(f);
    buf[rd] = '\0';
    if (out_len) *out_len = rd;
    return buf;
}

static int parse_msg_string(const char* s, int* u, int* v, int* e) {
    return (sscanf(s, "%d->%d in epoch %d", u, v, e) == 3);
}

static int parse_demand_key(const char* k, int* dst, int* chunk, int* src, int* E) {
    return (sscanf(k, "Demand at %d for chunk %d from %d met by epoch %d", dst, chunk, src, E) == 4);
}

// ----------------- mapping host <-> rank -----------------
static int* host_ids = NULL; // rank i => host_ids[i]
static int host_cap = 0, host_n = 0;

static void add_unique_host(int h) {
    for (int i = 0; i < host_n; i++) if (host_ids[i] == h) return;
    if (host_n == host_cap) {
        host_cap = host_cap ? host_cap * 2 : 16;
        host_ids = (int*)realloc(host_ids, (size_t)host_cap * sizeof(int));
        if (!host_ids) { fprintf(stderr, "realloc host_ids\n"); MPI_Abort(MPI_COMM_WORLD, 1); }
    }
    host_ids[host_n++] = h;
}

static int host_to_rank(int h) {
    for (int i = 0; i < host_n; i++) if (host_ids[i] == h) return i;
    fprintf(stderr, "Host %d non trovato nella mappa\n", h);
    MPI_Abort(MPI_COMM_WORLD, 1);
    return -1;
}

// ----------------- parsing config -----------------
static void parse_config_rank0(const char* conf, ConfigParams* cfg, int rank) {
    if (rank != 0) return;
    size_t len=0;
    char* txt = slurp(conf, &len);
    if (!txt) { fprintf(stderr, "Config open fail: %s\n", conf); MPI_Abort(MPI_COMM_WORLD, 1); }

    cJSON* root = cJSON_Parse(txt);
    if (!root) { fprintf(stderr, "Config JSON parse fail\n"); free(txt); MPI_Abort(MPI_COMM_WORLD, 1); }

    cJSON* inst = cJSON_GetObjectItemCaseSensitive(root, "InstanceParams");
    cJSON* top  = cJSON_GetObjectItemCaseSensitive(root, "TopologyParams");
    if (!inst || !top) { fprintf(stderr, "Config: manca InstanceParams/TopologyParams\n"); cJSON_Delete(root); free(txt); MPI_Abort(MPI_COMM_WORLD, 1); }

    cJSON* cj_chunks = cJSON_GetObjectItemCaseSensitive(inst, "num_chunks");
    cJSON* cj_epochs = cJSON_GetObjectItemCaseSensitive(inst, "num_epochs");
    if (!cj_chunks || !cj_epochs || !cJSON_IsNumber(cj_chunks) || !cJSON_IsNumber(cj_epochs)) {
        fprintf(stderr, "Config: num_chunks/num_epochs mancanti o non numerici\n");
        cJSON_Delete(root); free(txt); MPI_Abort(MPI_COMM_WORLD, 1);
    }
    cfg->num_chunks = (int)cj_chunks->valuedouble;
    cfg->num_epochs = (int)cj_epochs->valuedouble;

    cJSON* cj_bytes = cJSON_GetObjectItemCaseSensitive(top, "chunk_size_bytes");
    double chunk_bytes = -1.0;
    if (cj_bytes && cJSON_IsNumber(cj_bytes)) {
        chunk_bytes = cj_bytes->valuedouble;
    } else {
        cJSON* cj_csize = cJSON_GetObjectItemCaseSensitive(top, "chunk_size");
        if (!cj_csize || !cJSON_IsNumber(cj_csize)) {
            fprintf(stderr, "Config: manca 'chunk_size' o 'chunk_size_bytes'\n");
            cJSON_Delete(root); free(txt); MPI_Abort(MPI_COMM_WORLD, 1);
        }
        double v = cj_csize->valuedouble;
        chunk_bytes = (v < 1e6) ? v * 1e9 : v;
    }

    if (cfg->num_chunks <= 0 || chunk_bytes <= 0.0) {
        fprintf(stderr, "Config invalida: num_chunks=%d chunk_bytes=%.3f\n", cfg->num_chunks, chunk_bytes);
        cJSON_Delete(root); free(txt); MPI_Abort(MPI_COMM_WORLD, 1);
    }

    long long cb = (long long)(chunk_bytes + 0.5);
    cfg->chunk_size = (int)cb;

#ifdef DEBUG_SIM
    fprintf(stderr, "[CFG] num_chunks=%d num_epochs=%d chunk_size_bytes=%d\n",
            cfg->num_chunks, cfg->num_epochs, cfg->chunk_size);
#endif

    cJSON_Delete(root);
    free(txt);
}

// ----------------- comparatore per qsort -----------------
static int cmp_msg(const void* A, const void* B) {
    const Msg* x = (const Msg*)A;
    const Msg* y = (const Msg*)B;
    if (x->epoch != y->epoch) return (x->epoch < y->epoch) ? -1 : 1;
    if (x->seq   != y->seq  ) return (x->seq   < y->seq  ) ? -1 : 1;
    if (x->src   != y->src  ) return (x->src   < y->src  ) ? -1 : 1;
    if (x->dst   != y->dst  ) return (x->dst   < y->dst  ) ? -1 : 1;
    if (x->origin!= y->origin) return (x->origin< y->origin)?-1 : 1;
    if (x->chunk != y->chunk) return (x->chunk < y->chunk)?-1 : 1;
    return 0;
}

// ----------------- schedule → messaggi per rank -----------------
static void build_messages_rank0(const char* sched_path,
                                 Msg*** out_per_rank, int** out_cnt, int world_size,
                                 int* out_max_epoch)
{
    size_t len=0;
    char* txt = slurp(sched_path, &len);
    if (!txt) { fprintf(stderr, "Schedule open fail: %s\n", sched_path); MPI_Abort(MPI_COMM_WORLD, 1); }
    if (len == 0) { fprintf(stderr, "Schedule vuoto\n"); free(txt); MPI_Abort(MPI_COMM_WORLD, 1); }

    cJSON* root = cJSON_Parse(txt);
    if (!root) { fprintf(stderr, "Schedule JSON parse fail\n"); free(txt); MPI_Abort(MPI_COMM_WORLD, 1); }

    cJSON* paths = cJSON_GetObjectItemCaseSensitive(root, "8-Chunk paths");
    if (!paths || !cJSON_IsObject(paths)) {
        fprintf(stderr, "Campo '8-Chunk paths' mancante/errato\n");
        cJSON_Delete(root); free(txt); MPI_Abort(MPI_COMM_WORLD, 1);
    }

    host_ids = NULL; host_cap = 0; host_n = 0;
    for (cJSON* ent = paths->child; ent; ent = ent->next) {
        const char* key = ent->string;
        if (!key) continue;
        int dst_h, chunk, src_h, E;
        if (!parse_demand_key(key, &dst_h, &chunk, &src_h, &E)) {
            fprintf(stderr, "Chiave '8-Chunk paths' invalida: %s\n", key);
            cJSON_Delete(root); free(txt); MPI_Abort(MPI_COMM_WORLD, 1);
        }
        add_unique_host(dst_h);
        add_unique_host(src_h);

        int n = cJSON_GetArraySize(ent);
        for (int i = 0; i < n; i++) {
            cJSON* s = cJSON_GetArrayItem(ent, i);
            if (!cJSON_IsString(s)) continue;
            int u, v, e;
            if (!parse_msg_string(s->valuestring, &u, &v, &e)) {
                fprintf(stderr, "Path invalido: %s\n", s->valuestring);
                cJSON_Delete(root); free(txt); MPI_Abort(MPI_COMM_WORLD, 1);
            }
            add_unique_host(u);
            add_unique_host(v);
        }
    }

    if (world_size != host_n) {
        fprintf(stderr, "MPI np=%d ma host nello schedule=%d (devono coincidere)\n", world_size, host_n);
        cJSON_Delete(root); free(txt); MPI_Abort(MPI_COMM_WORLD, 1);
    }

    Msg** per_rank = (Msg**)calloc(world_size, sizeof(Msg*));
    int*  cnt      = (int*)calloc(world_size, sizeof(int));
    int*  cap      = (int*)calloc(world_size, sizeof(int));
    if (!per_rank || !cnt || !cap) { fprintf(stderr, "calloc per_rank\n"); MPI_Abort(MPI_COMM_WORLD, 1); }

    int seq_global = 0;
    int max_epoch  = 0;

    for (cJSON* ent = paths->child; ent; ent = ent->next) {
        const char* key = ent->string;
        int dst_h, chunk, src_h, E;
        parse_demand_key(key, &dst_h, &chunk, &src_h, &E);

        int origin_rank = host_to_rank(src_h);

        int n = cJSON_GetArraySize(ent);
        for (int i = 0; i < n; i++) {
            cJSON* s = cJSON_GetArrayItem(ent, i);
            if (!cJSON_IsString(s)) continue;
            int u_h, v_h, e;
            parse_msg_string(s->valuestring, &u_h, &v_h, &e);
            if (e > max_epoch) max_epoch = e;

            int u = host_to_rank(u_h);
            int v = host_to_rank(v_h);

            int seq = seq_global++;

            for (int t = 0; t < 2; t++) {
                int who = (t == 0) ? u : v;
                if (u == v && t == 1) break;

                if (cnt[who] == cap[who]) {
                    cap[who] = cap[who] ? cap[who] * 2 : 16;
                    per_rank[who] = (Msg*)realloc(per_rank[who], (size_t)cap[who]*sizeof(Msg));
                    if (!per_rank[who]) { fprintf(stderr, "realloc per_rank[%d]\n", who); MPI_Abort(MPI_COMM_WORLD, 1); }
                }
                Msg* m = &per_rank[who][cnt[who]++];
                m->src   = u;
                m->dst   = v;
                m->epoch = e;
                m->seq   = seq;
                m->origin= origin_rank;
                m->chunk = chunk;
            }
        }
    }

    for (int r = 0; r < world_size; r++) {
        if (cnt[r] > 1) qsort(per_rank[r], (size_t)cnt[r], sizeof(Msg), cmp_msg);
    }

#ifdef DEBUG_SIM
    fprintf(stderr, "[r0] Host map (%d):\n", host_n);
    for (int i = 0; i < host_n; i++) fprintf(stderr, "  rank %d <= host %d\n", i, host_ids[i]);
    for (int r = 0; r < world_size; r++) {
        fprintf(stderr, "[r0] Rank %d: %d msgs\n", r, cnt[r]);
        for (int i = 0; i < cnt[r]; i++) {
            Msg* m = &per_rank[r][i];
            fprintf(stderr, "    ep=%d seq=%d %d->%d origin=%d chunk=%d\n",
                    m->epoch, m->seq, m->src, m->dst, m->origin, m->chunk);
        }
    }
#endif

    *out_per_rank  = per_rank;
    *out_cnt       = cnt;
    *out_max_epoch = max_epoch;

    cJSON_Delete(root);
    free(txt);
}

// ----------------- serializzazione -----------------
static char* pack_msgs(const Msg* a, int n, int* out_sz) {
    int sz = (int)(sizeof(int) + n * (int)sizeof(Msg));
    char* buf = (char*)malloc((size_t)sz);
    if (!buf) { fprintf(stderr, "malloc pack\n"); MPI_Abort(MPI_COMM_WORLD, 1); }
    memcpy(buf, &n, sizeof(int));
    memcpy(buf + sizeof(int), a, (size_t)n * sizeof(Msg));
    *out_sz = sz;
    return buf;
}
static Msg* unpack_msgs(const char* buf, int* out_n) {
    int n; memcpy(&n, buf, sizeof(int));
    *out_n = n;
    if (n == 0) return NULL;
    Msg* a = (Msg*)malloc((size_t)n * sizeof(Msg));
    if (!a) { fprintf(stderr, "malloc unpack\n"); MPI_Abort(MPI_COMM_WORLD, 1); }
    memcpy(a, buf + sizeof(int), (size_t)n * sizeof(Msg));
    return a;
}

// ----------------- stampa -----------------
static void print_slice(const char* title, int proc, const int* arr, int offset, int len) {
    int to_print = (len < MAX_PRINT_ELEMS) ? len : MAX_PRINT_ELEMS;
    printf("%s [proc %d] (len=%d, showing %d): [", title, proc, len, to_print);
    for (int i = 0; i < to_print; i++) {
        if (i) printf(", ");
        printf("%d", arr[offset + i]);
    }
    if (to_print < len) printf(", ...");
    printf("]\n");
    fflush(stdout);
}

// ----------------- simulazione: per TUTTE le epoche -----------------
static void simulate_epochs(const Msg* msgs, int nmsgs,
                            int* global_buf, int data_size_per_host, int chunk_ints,
                            int max_epoch)
{
    for (int ep = 0; ep <= max_epoch; ep++) {
        // conta quante recv/send in questa epoca
        int n_recvs = 0, n_sends = 0;
        for (int i = 0; i < nmsgs; i++) {
            const Msg* m = &msgs[i];
            if (m->epoch != ep || m->src == m->dst) continue;
            if (my_rank == m->dst) n_recvs++;
            if (my_rank == m->src) n_sends++;
        }

        int n_reqs = n_recvs + n_sends;
        MPI_Request* reqs = NULL;
        MPI_Status*  stats = NULL;
        int r = 0;

        if (n_reqs > 0) {
            reqs  = (MPI_Request*)malloc((size_t)n_reqs * sizeof(MPI_Request));
            stats = (MPI_Status*) malloc((size_t)n_reqs * sizeof(MPI_Status));
            if (!reqs || !stats) { fprintf(stderr, "malloc reqs/stats\n"); MPI_Abort(MPI_COMM_WORLD, 1); }

            // prima tutte le Irecv
            for (int i = 0; i < nmsgs; i++) {
                const Msg* m = &msgs[i];
                if (m->epoch != ep || m->src == m->dst) continue;
                if (my_rank == m->dst) {
                    int* slot = global_buf + m->origin * data_size_per_host + m->chunk * chunk_ints;
                    MPI_Irecv(slot, chunk_ints, MPI_INT, m->src, m->seq, MPI_COMM_WORLD, &reqs[r++]);
#ifdef DEBUG_SIM
                    DBG("ep=%d Irecv from %d (seq=%d) -> origin=%d chunk=%d",
                        ep, m->src, m->seq, m->origin, m->chunk);
#endif
                }
            }

            // poi tutte le Isend
            for (int i = 0; i < nmsgs; i++) {
                const Msg* m = &msgs[i];
                if (m->epoch != ep || m->src == m->dst) continue;
                if (my_rank == m->src) {
                    int* slot = global_buf + m->origin * data_size_per_host + m->chunk * chunk_ints;
                    MPI_Isend(slot, chunk_ints, MPI_INT, m->dst, m->seq, MPI_COMM_WORLD, &reqs[r++]);
#ifdef DEBUG_SIM
                    DBG("ep=%d Isend to %d (seq=%d) <- origin=%d chunk=%d",
                        ep, m->dst, m->seq, m->origin, m->chunk);
#endif
                }
            }

            MPI_Waitall(n_reqs, reqs, stats);
            free(stats);
            free(reqs);
        }

        // Tutti i rank fanno una barrier per OGNI epoca
        MPI_Barrier(MPI_COMM_WORLD);
#ifdef DEBUG_SIM
        DBG("=== END EPOCH %d ===", ep);
#endif
    }
}

// ----------------- main -----------------
int main(int argc, char** argv) {
    MPI_Init(&argc, &argv);
    int world_size=1;
    MPI_Comm_rank(MPI_COMM_WORLD, &my_rank);
    MPI_Comm_size(MPI_COMM_WORLD, &world_size);

    if (argc != 3) {
        if (my_rank == 0) fprintf(stderr, "Usage: %s config.json schedule.json\n", argv[0]);
        MPI_Finalize(); return 99;
    }

    // 1) config
    ConfigParams cfg={0};
    parse_config_rank0(argv[1], &cfg, my_rank);
    MPI_Bcast(&cfg, sizeof(cfg), MPI_BYTE, 0, MPI_COMM_WORLD);

    // 2) parse schedule su rank0
    Msg** per_rank = NULL;
    int*  cnt = NULL;
    int   max_epoch = 0;
    if (my_rank == 0) {
        build_messages_rank0(argv[2], &per_rank, &cnt, world_size, &max_epoch);
    }

    // 3) broadcast host map e max_epoch
    int host_n_b = host_n;
    MPI_Bcast(&host_n_b, 1, MPI_INT, 0, MPI_COMM_WORLD);
    if (my_rank != 0) {
        host_ids = (int*)malloc((size_t)host_n_b * sizeof(int));
        host_n   = host_n_b; host_cap = host_n_b;
        if (!host_ids) { fprintf(stderr, "malloc host_ids\n"); MPI_Abort(MPI_COMM_WORLD, 1); }
    }
    MPI_Bcast(host_ids, host_n_b, MPI_INT, 0, MPI_COMM_WORLD);
    if (world_size != host_n) {
        if (my_rank == 0) fprintf(stderr, "MPI np (%d) != hosts (%d)\n", world_size, host_n);
        MPI_Abort(MPI_COMM_WORLD, 1);
    }
    MPI_Bcast(&max_epoch, 1, MPI_INT, 0, MPI_COMM_WORLD);

    // 4) distribuisci messaggi ai rank
    Msg* my_msgs = NULL;
    int  my_n    = 0;
    if (my_rank == 0) {
        for (int r = 1; r < world_size; r++) {
            int sz = 0; char* buf = pack_msgs(per_rank[r], cnt[r], &sz);
            MPI_Send(&sz, 1, MPI_INT, r, 440, MPI_COMM_WORLD);
            MPI_Send(buf, sz, MPI_BYTE, r, 441, MPI_COMM_WORLD); // <-- FIX: invia a r
            free(buf);
            free(per_rank[r]);
        }
        my_msgs = per_rank[0];
        my_n    = cnt[0];
        free(cnt);
        free(per_rank);
    } else {
        int sz = 0;
        MPI_Recv(&sz, 1, MPI_INT, 0, 440, MPI_COMM_WORLD, MPI_STATUS_IGNORE);
        char* buf = (char*)malloc((size_t)sz);
        if (!buf) { fprintf(stderr, "malloc rcv buf\n"); MPI_Abort(MPI_COMM_WORLD, 1); }
        MPI_Recv(buf, sz, MPI_BYTE, 0, 441, MPI_COMM_WORLD, MPI_STATUS_IGNORE);
        my_msgs = unpack_msgs(buf, &my_n);
        free(buf);
    }

#ifdef DEBUG_SIM
    DBG("Ricevuti %d messaggi. max_epoch=%d", my_n, max_epoch);
#endif

    // 5) dati
    int chunk_ints = cfg.chunk_size / (int)sizeof(int);
    if (chunk_ints <= 0) { fprintf(stderr, "chunk_size troppo piccolo\n"); MPI_Abort(MPI_COMM_WORLD, 1); }
    int data_per_host = cfg.num_chunks * chunk_ints;
    int total_ints    = data_per_host * world_size;

    int* local = (int*)malloc((size_t)data_per_host * sizeof(int));
    int* sim_global = (int*)malloc((size_t)total_ints * sizeof(int));
    if (!local || !sim_global) { fprintf(stderr, "malloc data buffers\n"); MPI_Abort(MPI_COMM_WORLD, 1); }

    srand((unsigned int)(time(NULL) + my_rank*1337));
    for (int i = 0; i < data_per_host; i++) local[i] = rand();

    memset(sim_global, 0, (size_t)total_ints * sizeof(int));
    memcpy(sim_global + my_rank * data_per_host, local, (size_t)data_per_host * sizeof(int));

    // ---- STAMPA 1: array locali ----
    for (int r = 0; r < world_size; r++) {
        MPI_Barrier(MPI_COMM_WORLD);
        if (my_rank == r) print_slice("[LOCAL]", my_rank, local, 0, data_per_host);
    }
    MPI_Barrier(MPI_COMM_WORLD);

    // 6) simulazione per epoche sincronizzate
    double t0 = MPI_Wtime();
    simulate_epochs(my_msgs, my_n, sim_global, data_per_host, chunk_ints, max_epoch);
    MPI_Barrier(MPI_COMM_WORLD);
    double t1 = MPI_Wtime();
    if (my_rank == 0) printf("[INFO] Simulazione completata in %.6f s\n", t1 - t0);

    // 7) MPI_Allgather di riferimento
    int* mpi_buf = (int*)malloc((size_t)total_ints * sizeof(int));
    if (!mpi_buf) { fprintf(stderr, "malloc mpi_buf\n"); MPI_Abort(MPI_COMM_WORLD, 1); }
    MPI_Allgather(local, data_per_host, MPI_INT,
                  mpi_buf, data_per_host, MPI_INT,
                  MPI_COMM_WORLD);

    // ---- STAMPA 2: Allgather (rank0) ----
    if (my_rank == 0) {
        for (int r = 0; r < world_size; r++) {
            print_slice("[ALLGATHER]", r, mpi_buf, r*data_per_host, data_per_host);
        }
    }
    MPI_Barrier(MPI_COMM_WORLD);

    // ---- STAMPA 3: confronto COMPLETO ----
    for (int r = 0; r < world_size; r++) {
        MPI_Barrier(MPI_COMM_WORLD);
        if (my_rank == r) {
            print_slice("[SIM_GLOBAL]", my_rank, sim_global, my_rank*data_per_host, data_per_host);

            int mismatch_idx = -1;
            for (int i = 0; i < total_ints; i++) {
                if (sim_global[i] != mpi_buf[i]) { mismatch_idx = i; break; }
            }

            if (mismatch_idx < 0) {
                printf("[COMPARE] proc %d: OK (sim_global COMPLETO == MPI_Allgather)\n", my_rank);
            } else {
                int who_slice = mismatch_idx / data_per_host;
                int pos_in_slice = mismatch_idx % data_per_host;
                printf("[COMPARE] proc %d: MISMATCH at global_i=%d (slice=%d, pos=%d) "
                       "(sim=%d, mpi=%d)\n",
                       my_rank, mismatch_idx, who_slice, pos_in_slice,
                       sim_global[mismatch_idx], mpi_buf[mismatch_idx]);
            }

            if (my_n == 0) {
                printf("[WARN] proc %d: nessun messaggio (my_n==0). "
                       "Schedule probabilmente non indirizza questo rank.\n", my_rank);
            }
            fflush(stdout);
        }
    }
    MPI_Barrier(MPI_COMM_WORLD);

    // ---- CHECK GLOBALE ----
    int local_ok = 1;
    for (int i = 0; i < total_ints; i++) {
        if (sim_global[i] != mpi_buf[i]) { local_ok = 0; break; }
    }
    int all_ok = 0;
    MPI_Allreduce(&local_ok, &all_ok, 1, MPI_INT, MPI_LAND, MPI_COMM_WORLD);
    if (my_rank == 0) {
        if (all_ok) printf("[RESULT] Tutti i rank hanno sim_global == MPI_Allgather \n");
        else        printf("[RESULT] Almeno un rank NON ha sim_global == MPI_Allgather \n");
    }

    free(mpi_buf);
    free(my_msgs);
    free(local);
    free(sim_global);
    free(host_ids);

    MPI_Finalize();
    return 0;
}
