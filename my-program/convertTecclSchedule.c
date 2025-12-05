// convertTecclSchedule.c
// Step finale: legge topology.json, schedule.json e scrive una .cm per HTSIM.
// - Nodes = num_groups * leaf_routers * hosts_per_router
// - Connections = flussi unici (src,dst,epoch) da "7-Flows"
// - Triggers = numero di flussi che hanno almeno un successore in catena
// - size (bytes) = num_chunks * (chunk_size_GB * 1e9) * countAggregato
//
// Build:
//   gcc -O2 -Wall -Wextra -o convertTecclSchedule convertTecclSchedule.c ../cJSON/cJSON.c -I../cJSON
//
// Uso:
//   ./convertTecclSchedule path/topology.json path/schedule.json path/output.cm

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <ctype.h>

#include "../cJSON/cJSON.h"

typedef enum { ROLE_UNKNOWN=0, ROLE_NODIP=1, ROLE_FIRST=2, ROLE_MID=3, ROLE_LAST=4 } Role;

typedef struct {
    int src, dst, epoch;
} FlowKey;

typedef struct {
    FlowKey key;
    int count;                // occorrenze in "7-Flows"
    Role role;                // da "8-Chunk paths"
    int has_pred;             // se true, pred è valido (solo per MID/LAST)
    FlowKey pred;             // predecessore (con epoch)
    int has_succ;             // se true, ha successore (FIRST/MID)
    unsigned long long size_bytes; // calcolata
    int id;                   // assegnato dopo l'ordinamento
} FlowInfo;

typedef struct {
    FlowInfo* data;
    size_t size, cap;
} FlowVec;

/* ---------- util: vector ---------- */
static void vec_init(FlowVec* v){ v->data=NULL; v->size=0; v->cap=0; }
static void vec_free(FlowVec* v){ free(v->data); v->data=NULL; v->size=v->cap=0; }
static int  vec_grow(FlowVec* v){
    size_t nc = v->cap? v->cap*2 : 32;
    FlowInfo* nd = (FlowInfo*)realloc(v->data, nc*sizeof(FlowInfo));
    if(!nd) return -1;
    v->data=nd; v->cap=nc; return 0;
}
static FlowInfo* vec_add(FlowVec* v, FlowKey k){
    if(v->size==v->cap && vec_grow(v)!=0) return NULL;
    v->data[v->size].key = k;
    v->data[v->size].count = 0;
    v->data[v->size].role = ROLE_UNKNOWN;
    v->data[v->size].has_pred = 0;
    v->data[v->size].pred = (FlowKey){0,0,0};
    v->data[v->size].has_succ = 0;
    v->data[v->size].size_bytes = 0ULL;
    v->data[v->size].id = 0;
    return &v->data[v->size++];
}
static int key_eq(FlowKey a, FlowKey b){
    return a.src==b.src && a.dst==b.dst && a.epoch==b.epoch;
}
static FlowInfo* vec_find(FlowVec* v, FlowKey k){
    for(size_t i=0;i<v->size;++i) if(key_eq(v->data[i].key,k)) return &v->data[i];
    return NULL;
}

/* ---------- util: file ---------- */
static char* read_file_to_string(const char* path, long* out_len) {
    FILE* f = fopen(path, "rb");
    if (!f) { fprintf(stderr, "Errore: impossibile aprire '%s': %s\n", path, strerror(errno)); return NULL; }
    if (fseek(f, 0, SEEK_END) != 0) { fprintf(stderr, "Errore: fseek fallito su '%s'\n", path); fclose(f); return NULL; }
    long len = ftell(f);
    if (len < 0) { fprintf(stderr, "Errore: ftell fallito su '%s'\n", path); fclose(f); return NULL; }
    if (fseek(f, 0, SEEK_SET) != 0) { fprintf(stderr, "Errore: fseek(SET) fallito su '%s'\n", path); fclose(f); return NULL; }
    char* buf = (char*)malloc((size_t)len + 1);
    if (!buf) { fprintf(stderr, "Errore: memoria insufficiente per leggere '%s' (%ld byte)\n", path, len); fclose(f); return NULL; }
    size_t rd = fread(buf, 1, (size_t)len, f); fclose(f);
    if ((long)rd != len) { fprintf(stderr, "Errore: letti %zu/%ld byte da '%s'\n", rd, len, path); free(buf); return NULL; }
    buf[len] = '\0'; if (out_len) *out_len = len; return buf;
}

/* ---------- util: json numbers ---------- */
static int get_number_int(const cJSON* obj, const char* key, int* out) {
    const cJSON* it = cJSON_GetObjectItemCaseSensitive(obj, key);
    if (!it || !cJSON_IsNumber(it)) { fprintf(stderr, "Errore: campo numerico mancante o non numerico: '%s'\n", key); return -1; }
    *out = (int)(it->valuedouble); return 0;
}
static int get_number_double(const cJSON* obj, const char* key, double* out) {
    const cJSON* it = cJSON_GetObjectItemCaseSensitive(obj, key);
    if (!it || !cJSON_IsNumber(it)) { fprintf(stderr, "Errore: campo numerico mancante o non numerico: '%s'\n", key); return -1; }
    *out = it->valuedouble; return 0;
}

/* ---------- parser edge/epoch ---------- */
// Sottostringa che inizia con "A->B ...": estrae A,B,epoch
static int parse_edge_epoch(const char* s, int* out_src, int* out_dst, int* out_epoch){
    const char* key_epoch=" in epoch ";
    const char* p_epoch=strstr(s,key_epoch);
    if(!p_epoch) return -1;
    size_t len=(size_t)(p_epoch - s);
    char tmp[256]; if(len>=sizeof(tmp)) len=sizeof(tmp)-1; memcpy(tmp,s,len); tmp[len]='\0';
    int src=-1,dst=-1; if(sscanf(tmp," %d->%d",&src,&dst)!=2) return -2;
    int epoch=-1;
    if(sscanf(p_epoch," in epoch %d",&epoch)!=1){
        const char* q=strstr(p_epoch,"epoch"); if(!q) return -3;
        q+=5; while(*q && !isdigit((unsigned char)*q) && *q!='-') q++;
        if(sscanf(q,"%d",&epoch)!=1) return -3;
    }
    *out_src=src; *out_dst=dst; *out_epoch=epoch; return 0;
}
// Per "7-Flows": salta a "traveled over "
static int parse_flow_line_7(const char* s, int* out_src, int* out_dst, int* out_epoch){
    const char* key="traveled over ";
    const char* p=strstr(s,key);
    if(!p) return -10;
    p += (int)strlen(key);
    return parse_edge_epoch(p,out_src,out_dst,out_epoch);
}

/* ---------- Step 1: topology ---------- */
typedef struct {
    int num_groups;
    int leaf_routers;
    int hosts_per_router;
    double chunk_size_gb;
    int num_chunks;
} TopoCfg;

/* ---------- Step 2: parse 7-Flows ---------- */
static int parse_7_flows_into_vec(const cJSON* root, FlowVec* fv){
    const cJSON* flows=cJSON_GetObjectItemCaseSensitive(root,"7-Flows");
    if(!flows || !cJSON_IsArray(flows)){
        fprintf(stderr,"Avviso: '7-Flows' mancante o non array.\n");
        return 0; // non fatale
    }
    cJSON* it=NULL;
    cJSON_ArrayForEach(it,flows){
        if(!cJSON_IsString(it) || !it->valuestring) continue;
        int s=-1,d=-1,e=-1; int rc=parse_flow_line_7(it->valuestring,&s,&d,&e);
        if(rc!=0){
            fprintf(stderr,"Avviso: non riesco a parsare '7-Flows': \"%s\" (rc=%d)\n", it->valuestring, rc);
            continue;
        }
        FlowKey k={s,d,e};
        FlowInfo* fi = vec_find(fv,k);
        if(!fi){
            fi = vec_add(fv,k);
            if(!fi){ fprintf(stderr,"Errore: memoria flussi.\n"); return -1; }
        }
        fi->count += 1;
    }
    return 0;
}

/* ---------- Step 3: parse 8-Chunk paths e annota ---------- */
static int annotate_8_chunk_paths(const cJSON* root, FlowVec* fv){
    const cJSON* cp=cJSON_GetObjectItemCaseSensitive(root,"8-Chunk paths");
    if(!cp || !cJSON_IsObject(cp)){
        fprintf(stderr,"Avviso: '8-Chunk paths' mancante o non oggetto.\n");
        return 0; // non fatale
    }

    typedef struct { int s,d,e; } Step;
    cJSON* demand_entry=NULL;
    cJSON_ArrayForEach(demand_entry, cp){
        if(!cJSON_IsArray(demand_entry)) continue;
        Step steps[512]; int k=0;

        cJSON* line=NULL;
        cJSON_ArrayForEach(line, demand_entry){
            if(!cJSON_IsString(line) || !line->valuestring) continue;
            int s=-1,d=-1,e=-1; int rc=parse_edge_epoch(line->valuestring,&s,&d,&e);
            if(rc!=0){
                fprintf(stderr,"Avviso: non riesco a parsare '8-Chunk paths': \"%s\" (rc=%d)\n",
                        line->valuestring, rc);
                continue;
            }
            if(k<(int)(sizeof(steps)/sizeof(steps[0]))){ steps[k].s=s; steps[k].d=d; steps[k].e=e; k++; }
            else { fprintf(stderr,"Avviso: troppi step in una catena, troncati.\n"); break; }
        }
        if(k<=0) continue;

        if(k==1){
            FlowKey a={steps[0].s,steps[0].d,steps[0].e};
            FlowInfo* fa=vec_find(fv,a);
            if(!fa){ fprintf(stderr,"Avviso: arco singolo non presente in 7-Flows: %d->%d (epoch %d)\n", a.src,a.dst,a.epoch); continue; }
            if(fa->role==ROLE_UNKNOWN) fa->role=ROLE_NODIP;
            continue;
        }

        // Primo
        {
            FlowKey a={steps[0].s,steps[0].d,steps[0].e};
            FlowInfo* fa=vec_find(fv,a);
            if(!fa){ fprintf(stderr,"Avviso: first non presente in 7-Flows: %d->%d (epoch %d)\n", a.src,a.dst,a.epoch); }
            else {
                fa->has_succ = 1;
                if(fa->role==ROLE_UNKNOWN || fa->role==ROLE_NODIP) fa->role=ROLE_FIRST;
                else if(fa->role!=ROLE_FIRST){
                    if(!fa->has_pred) fa->role=ROLE_FIRST;
                }
            }
        }
        // Intermedi
        for(int i=1;i<=k-2;++i){
            FlowKey a={steps[i].s,steps[i].d,steps[i].e};
            FlowKey p={steps[i-1].s,steps[i-1].d,steps[i-1].e};
            FlowInfo* fa=vec_find(fv,a);
            if(!fa){ fprintf(stderr,"Avviso: mid non presente in 7-Flows: %d->%d (epoch %d)\n", a.src,a.dst,a.epoch); continue; }
            fa->has_pred = 1; fa->pred = p;
            fa->has_succ = 1;
            fa->role = ROLE_MID;
        }
        // Ultimo
        {
            FlowKey a={steps[k-1].s,steps[k-1].d,steps[k-1].e};
            FlowKey p={steps[k-2].s,steps[k-2].d,steps[k-2].e};
            FlowInfo* fa=vec_find(fv,a);
            if(!fa){ fprintf(stderr,"Avviso: last non presente in 7-Flows: %d->%d (epoch %d)\n", a.src,a.dst,a.epoch); }
            else {
                fa->has_pred=1; fa->pred=p;
                if(!fa->has_succ) fa->role=ROLE_LAST;
                else fa->role=ROLE_MID; // se ha pred e succ è mid
            }
        }
    }
    return 0;
}

/* ---------- ordinamento e assegnazione ID ---------- */
static int cmp_flow(const void* a, const void* b){
    const FlowInfo* x=(const FlowInfo*)a;
    const FlowInfo* y=(const FlowInfo*)b;
    if(x->key.epoch != y->key.epoch) return (x->key.epoch < y->key.epoch)? -1: 1;
    if(x->key.src   != y->key.src)   return (x->key.src   < y->key.src)  ? -1: 1;
    if(x->key.dst   != y->key.dst)   return (x->key.dst   < y->key.dst)  ? -1: 1;
    return 0;
}
static void assign_ids_sorted(FlowVec* fv){
    qsort(fv->data, fv->size, sizeof(FlowInfo), cmp_flow);
    for(size_t i=0;i<fv->size;++i) fv->data[i].id = (int)(i+1);
}
static FlowInfo* find_by_key_linear(const FlowVec* fv, FlowKey k){
    for(size_t i=0;i<fv->size;++i) if(key_eq(fv->data[i].key,k)) return &fv->data[i];
    return NULL;
}

/* ---------- MAIN ---------- */
int main(int argc, char** argv){
    if(argc != 4){
        fprintf(stderr,"Uso: %s path/topology.json path/schedule.json path/output.cm\n", argv[0]);
        return 1;
    }
    const char* topo_path = argv[1];
    const char* sched_path= argv[2];
    const char* out_path  = argv[3];

    /* ---- Step 1: topology ---- */
    long tlen=0; char* ttext = read_file_to_string(topo_path,&tlen);
    if(!ttext) return 2;
    cJSON* troot = cJSON_Parse(ttext);
    if(!troot){
        const char* err=cJSON_GetErrorPtr();
        fprintf(stderr,"Errore: JSON non valido in '%s'%s%s\n", topo_path, err? " vicino a: ":"", err? err:"");
        free(ttext); return 3;
    }
    const cJSON* topology=cJSON_GetObjectItemCaseSensitive(troot,"TopologyParams");
    const cJSON* instance=cJSON_GetObjectItemCaseSensitive(troot,"InstanceParams");
    if(!topology || !cJSON_IsObject(topology)){ fprintf(stderr,"Errore: 'TopologyParams' mancante o non valido.\n"); cJSON_Delete(troot); free(ttext); return 4; }
    if(!instance || !cJSON_IsObject(instance)){ fprintf(stderr,"Errore: 'InstanceParams' mancante o non valido.\n"); cJSON_Delete(troot); free(ttext); return 5; }

    int num_groups=0, leaf_routers=0, hosts_per_router=0, num_chunks=0; double chunk_size_gb=0.0;
    if(get_number_int(topology,"num_groups",&num_groups)<0){ cJSON_Delete(troot); free(ttext); return 6; }
    if(get_number_int(topology,"leaf_routers",&leaf_routers)<0){ cJSON_Delete(troot); free(ttext); return 7; }
    if(get_number_int(topology,"hosts_per_router",&hosts_per_router)<0){ cJSON_Delete(troot); free(ttext); return 8; }
    if(get_number_double(topology,"chunk_size",&chunk_size_gb)<0){ cJSON_Delete(troot); free(ttext); return 9; }
    if(get_number_int(instance,"num_chunks",&num_chunks)<0){ cJSON_Delete(troot); free(ttext); return 10; }

    int nodes = num_groups * leaf_routers * hosts_per_router;

    cJSON_Delete(troot); free(ttext);

    /* ---- Step 2&3: schedule ---- */
    long slen=0; char* stext = read_file_to_string(sched_path,&slen);
    if(!stext) return 20;
    cJSON* sroot = cJSON_Parse(stext);
    if(!sroot){
        const char* err=cJSON_GetErrorPtr();
        fprintf(stderr,"Errore: JSON non valido in '%s'%s%s\n", sched_path, err? " vicino a: ":"", err? err:"");
        free(stext); return 21;
    }

    FlowVec flows; vec_init(&flows);
    if(parse_7_flows_into_vec(sroot,&flows)!=0){ cJSON_Delete(sroot); free(stext); vec_free(&flows); return 22; }
    if(annotate_8_chunk_paths(sroot,&flows)!=0){ cJSON_Delete(sroot); free(stext); vec_free(&flows); return 23; }

    cJSON_Delete(sroot); free(stext);

    /* ---- Assegna ID ordinando per epoch,src,dst ---- */
    assign_ids_sorted(&flows);

    /* ---- Calcola size bytes per ogni flusso ---- */
    // chunk_size in GB decimali → * 1e9 (evitiamo scientifica stampando %llu)
    unsigned long long bytes_per_chunk = (unsigned long long)(chunk_size_gb * 1e9 + 0.5);
    for(size_t i=0;i<flows.size;++i){
        unsigned long long c = (unsigned long long)flows.data[i].count;
        unsigned long long nc= (unsigned long long)num_chunks;
        flows.data[i].size_bytes = c * nc * bytes_per_chunk;
    }

    /* ---- succ_count: numero di target per ogni trigger (per ID) ---- */
    int* succ_count = (int*)calloc(flows.size, sizeof(int));
    if(!succ_count){ fprintf(stderr,"Errore: memoria succ_count\n"); vec_free(&flows); return 40; }

    // Per ogni flow con un predecessore valido, incrementa il contatore del predecessore
    for(size_t i=0;i<flows.size;++i){
        FlowInfo* f = &flows.data[i];
        if(f->has_pred){
            FlowInfo* p = find_by_key_linear(&flows, f->pred);
            if(p){
                succ_count[p->id - 1] += 1;
            } else {
                fprintf(stderr,
                    "Avviso: predecessore non trovato (catena): %d->%d (ep %d) prev=%d->%d (ep %d)\n",
                    f->key.src, f->key.dst, f->key.epoch,
                    f->pred.src, f->pred.dst, f->pred.epoch);
            }
        }
    }

    /* ---- Conta header ---- */
    int connections = (int)flows.size;
    int triggers = 0;
    for(size_t i=0;i<flows.size;++i){
        if(succ_count[flows.data[i].id - 1] > 0) triggers++;
    }

    /* ---- Scrivi file .cm ---- */
    FILE* out = fopen(out_path,"w");
    if(!out){ fprintf(stderr,"Errore: non posso aprire in scrittura '%s': %s\n", out_path, strerror(errno)); free(succ_count); vec_free(&flows); return 30; }

    fprintf(out, "Nodes %d\n", nodes);
    fprintf(out, "Connections %d\n", connections);
    fprintf(out, "Triggers %d\n", triggers);

    // Stampa righe Connections con pattern richiesti
    for(size_t i=0;i<flows.size;++i){
        FlowInfo* f = &flows.data[i];
        int myid = f->id;
        int my_succs = succ_count[myid - 1];  // quante righe hanno trigger <myid>

        // risolvo id_predecessore se necessario
        int pred_id = 0;
        if(f->has_pred){
            FlowInfo* p = find_by_key_linear(&flows, f->pred);
            if(!p){
                fprintf(stderr,"Avviso: predecessore non trovato per %d->%d (epoch %d): %d->%d (epoch %d)\n",
                        f->key.src,f->key.dst,f->key.epoch, f->pred.src,f->pred.dst,f->pred.epoch);
            } else pred_id = p->id;
        }

        if(f->role==ROLE_NODIP || f->role==ROLE_UNKNOWN){
            // catena singola o non presente in 8-Chunk paths → start 0
            fprintf(out, "%d->%d id %d start 0 size %llu\n",
                    f->key.src, f->key.dst, myid, (unsigned long long)f->size_bytes);

        } else if(f->role==ROLE_FIRST){
            // primo: start 0 (+ send_done_trigger solo se qualcuno lo ascolta)
            if (my_succs > 0) {
                fprintf(out, "%d->%d id %d start 0 size %llu send_done_trigger %d\n",
                        f->key.src, f->key.dst, myid, (unsigned long long)f->size_bytes, myid);
            } else {
                fprintf(out, "%d->%d id %d start 0 size %llu\n",
                        f->key.src, f->key.dst, myid, (unsigned long long)f->size_bytes);
            }

        } else if(f->role==ROLE_MID){
            // in mezzo: trigger pred (+ send_done_trigger se ha successori)
            if(pred_id==0){
                fprintf(stderr,"Avviso: MID senza pred valido: %d->%d (ep %d). Uso start 0.\n",
                        f->key.src, f->key.dst, f->key.epoch);
                if (my_succs > 0) {
                    fprintf(out, "%d->%d id %d start 0 size %llu send_done_trigger %d\n",
                            f->key.src, f->key.dst, myid, (unsigned long long)f->size_bytes, myid);
                } else {
                    fprintf(out, "%d->%d id %d start 0 size %llu\n",
                            f->key.src, f->key.dst, myid, (unsigned long long)f->size_bytes);
                }
            } else {
                if (my_succs > 0) {
                    fprintf(out, "%d->%d id %d trigger %d size %llu send_done_trigger %d\n",
                            f->key.src, f->key.dst, myid, pred_id, (unsigned long long)f->size_bytes, myid);
                } else {
                    fprintf(out, "%d->%d id %d trigger %d size %llu\n",
                            f->key.src, f->key.dst, myid, pred_id, (unsigned long long)f->size_bytes);
                }
            }

        } else if(f->role==ROLE_LAST){
            // ultimo: solo trigger pred (mai send_done_trigger)
            if(pred_id==0){
                fprintf(stderr,"Avviso: LAST senza pred valido: %d->%d (ep %d). Uso start 0.\n",
                        f->key.src, f->key.dst, f->key.epoch);
                fprintf(out, "%d->%d id %d start 0 size %llu\n",
                        f->key.src, f->key.dst, myid, (unsigned long long)f->size_bytes);
            } else {
                fprintf(out, "%d->%d id %d trigger %d size %llu\n",
                        f->key.src, f->key.dst, myid, pred_id, (unsigned long long)f->size_bytes);
            }

        } else {
            // default di sicurezza
            fprintf(out, "%d->%d id %d start 0 size %llu\n",
                    f->key.src, f->key.dst, myid, (unsigned long long)f->size_bytes);
        }
    }

    // Sezione triggers: SOLO per ID che hanno almeno un target
    for(size_t i=0;i<flows.size;++i){
        int myid = flows.data[i].id;
        if(succ_count[myid - 1] > 0){
            fprintf(out, "trigger id %d oneshot\n", myid);
        }
    }

    fclose(out);
    free(succ_count);
    vec_free(&flows);

    // log riassuntivo
    fprintf(stderr,"[OK] CM scritta in '%s'\n", out_path);
    fprintf(stderr,"[INFO] Nodes=%d Connections=%d Triggers=%d bytes/chunk=%llu (num_chunks=%d)\n",
            nodes, connections, triggers,
            (unsigned long long)(bytes_per_chunk), num_chunks);

    return 0;
}
