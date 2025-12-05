#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "../cJSON/cJSON.h"

// ====================
// Strutture dati di base
// ====================

typedef struct {
    int start_epoch;
    int src_host;
    int dst_host;
    int *switches;
    int switch_count;
    int end_epoch;
} ChunkPath;

typedef struct {
    int src;
    int dst;
    int chunk;
} TransmissionEntry;

// ====================
// Array dinamici generici per int
// ====================

typedef struct {
    int *data;      // puntatore all'array dinamico
    int count;      // numero di elementi validi
    int capacity;   // capacità massima allocata
} IntArray;

// Inizializza un IntArray con capacità iniziale di 10 elementi
void int_array_init(IntArray *arr) {
    arr->capacity = 10;
    arr->count = 0;
    arr->data = malloc(arr->capacity * sizeof(int));
    if (!arr->data) {
        fprintf(stderr, "Memory allocation failed for IntArray\n");
        exit(EXIT_FAILURE);
    }
}

// Inserisce un valore solo se non presente, riallocando se necessario
void int_array_append_unique(IntArray *arr, int val) {
    for (int i = 0; i < arr->count; i++) {
        if (arr->data[i] == val) return; // duplicato, esci
    }
    if (arr->count >= arr->capacity) {
        arr->capacity *= 2;
        int *tmp = realloc(arr->data, arr->capacity * sizeof(int));
        if (!tmp) {
            fprintf(stderr, "Memory allocation failed on realloc IntArray\n");
            exit(EXIT_FAILURE);
        }
        arr->data = tmp;
    }
    arr->data[arr->count++] = val;
}

void int_array_free(IntArray *arr) {
    free(arr->data);
    arr->data = NULL;
    arr->capacity = arr->count = 0;
}

// ====================
// Array dinamico per TransmissionEntry
// ====================

typedef struct {
    TransmissionEntry *data;
    int count;
    int capacity;
} TransmissionArray;

void transmission_array_init(TransmissionArray *arr) {
    arr->capacity = 100;
    arr->count = 0;
    arr->data = malloc(arr->capacity * sizeof(TransmissionEntry));
    if (!arr->data) {
        fprintf(stderr, "Memory allocation failed for TransmissionArray\n");
        exit(EXIT_FAILURE);
    }
}

void transmission_array_append(TransmissionArray *arr, TransmissionEntry val) {
    if (arr->count >= arr->capacity) {
        arr->capacity *= 2;
        TransmissionEntry *tmp = realloc(arr->data, arr->capacity * sizeof(TransmissionEntry));
        if (!tmp) {
            fprintf(stderr, "Memory allocation failed on realloc TransmissionArray\n");
            exit(EXIT_FAILURE);
        }
        arr->data = tmp;
    }
    arr->data[arr->count++] = val;
}

void transmission_array_free(TransmissionArray *arr) {
    free(arr->data);
    arr->data = NULL;
    arr->capacity = arr->count = 0;
}

// ====================
// Funzione di lettura file (binario/text)
// ====================

char *read_file(const char *filename) {
    FILE *f = fopen(filename, "rb");
    if (!f) {
        perror("Error opening file");
        return NULL;
    }
    fseek(f, 0, SEEK_END);
    long len = ftell(f);
    rewind(f);
    char *data = malloc(len + 1);
    if (!data) {
        fclose(f);
        fprintf(stderr, "Memory allocation failed while reading file\n");
        return NULL;
    }
    fread(data, 1, len, f);
    data[len] = '\0';
    fclose(f);
    return data;
}

// ====================
// Parsing della stringa di path in ChunkPath
// ====================

int parse_path_string(const char *str, ChunkPath *cp) {
    // Cerca la sottostringa " in epoch " per determinare i campi
    const char *in_epoch_pos = strstr(str, " in epoch ");
    if (!in_epoch_pos) return 0;

    // Estrae la parte prima di " in epoch "
    char host_part[50];
    int len_host = (int)(in_epoch_pos - str);
    if (len_host >= (int)sizeof(host_part)) len_host = (int)sizeof(host_part) - 1;
    strncpy(host_part, str, len_host);
    host_part[len_host] = '\0';

    // Estrae src e dst host
    if (sscanf(host_part, "%d->%d", &cp->src_host, &cp->dst_host) != 2) return 0;

    // Estrae l'epoch di inizio
    if (sscanf(in_epoch_pos, " in epoch %d", &cp->start_epoch) != 1) return 0;

    // Cerca la sottostringa "via switches "
    const char *via_switches = strstr(str, "via switches ");
    if (!via_switches) return 0;
    via_switches += strlen("via switches ");

    // Parsing dinamico dei switch (non più array fisso)
    int switches_capacity = 8;
    int *switches = malloc(switches_capacity * sizeof(int));
    if (!switches) {
        fprintf(stderr, "Memory allocation failed for switches\n");
        return 0;
    }
    int sw_count = 0;

    const char *p = via_switches;
    char *endptr;
    while (1) {
        int val = (int)strtol(p, &endptr, 10);
        if (p == endptr) break; // nessun valore trovato, fine parsing
        if (sw_count >= switches_capacity) {
            switches_capacity *= 2;
            int *tmp = realloc(switches, switches_capacity * sizeof(int));
            if (!tmp) {
                free(switches);
                fprintf(stderr, "Memory allocation failed realloc switches\n");
                return 0;
            }
            switches = tmp;
        }
        switches[sw_count++] = val;
        p = endptr;
        if (strncmp(p, " -> ", 4) == 0) {
            p += 4;
        } else {
            break;
        }
    }

    // Assegna allo struct, con switch_count aggiornato
    cp->switches = switches;
    cp->switch_count = sw_count;

    return 1;
}

// ====================
// Stampa formattata del ChunkPath
// ====================

void print_chunk_path(const ChunkPath *cp) {
    printf("Path: src_host=%d, dst_host=%d, start_epoch=%d, end_epoch=%d, switches=[",
           cp->src_host, cp->dst_host, cp->start_epoch, cp->end_epoch);

    for (int i = 0; i < cp->switch_count; i++) {
        printf("%d", cp->switches[i]);
        if (i < cp->switch_count - 1) printf(", ");
    }
    printf("]\n");
}

// ====================
// Estrazione del numero totale di chunk dal file config JSON
// ====================

int read_num_chunks_from_config(const char *config_filename) {
    char *config_data = read_file(config_filename);
    if (!config_data) {
        fprintf(stderr, "Failed to load config file: %s\n", config_filename);
        return -1;
    }

    cJSON *config_json = cJSON_Parse(config_data);
    free(config_data);
    if (!config_json) {
        fprintf(stderr, "Failed to parse config JSON\n");
        return -1;
    }

    cJSON *instance_params = cJSON_GetObjectItem(config_json, "InstanceParams");
    if (!instance_params) {
        fprintf(stderr, "\"InstanceParams\" section missing\n");
        cJSON_Delete(config_json);
        return -1;
    }

    cJSON *num_chunks_json = cJSON_GetObjectItem(instance_params, "num_chunks");
    if (!num_chunks_json || !cJSON_IsNumber(num_chunks_json)) {
        fprintf(stderr, "\"num_chunks\" missing or not a number\n");
        cJSON_Delete(config_json);
        return -1;
    }

    int num_chunks = num_chunks_json->valueint;
    cJSON_Delete(config_json);

    if (num_chunks <= 0) {
        fprintf(stderr, "Invalid num_chunks value %d\n", num_chunks);
        return -1;
    }
    return num_chunks;
}

// ====================
// Ricerca indice host in IntArray (hosts)
// ====================

int find_host_index(const IntArray *hosts, int host) {
    for (int i = 0; i < hosts->count; i++) {
        if (hosts->data[i] == host) return i;
    }
    return -1;
}

// ====================
// Parsing e processo di tutte le entry in "8-Chunk paths"
// ====================

void process_chunk_paths(cJSON *chunk_paths, IntArray *hosts, IntArray *switches,
                         TransmissionArray *transmissions) {

    cJSON *entry = NULL;
    cJSON_ArrayForEach(entry, chunk_paths) {
        const char *key = entry->string;
        if (!key) continue;

        int dst, chunk, src, end_epoch;
        // Parsing formato chiave
        if (sscanf(key, "Demand at %d for chunk %d from %d met by epoch %d", &dst, &chunk, &src, &end_epoch) != 4) {
            fprintf(stderr, "Failed to parse key: %s\n", key);
            continue;
        }

        int n_paths = cJSON_GetArraySize(entry);
        for (int i = 0; i < n_paths; i++) {
            cJSON *path_item = cJSON_GetArrayItem(entry, i);
            if (!cJSON_IsString(path_item)) continue;
            const char *path_str = path_item->valuestring;

            ChunkPath cp;
            memset(&cp, 0, sizeof(ChunkPath));

            if (!parse_path_string(path_str, &cp)) {
                fprintf(stderr, "Failed to parse path string: %s\n", path_str);
                continue;
            }
            cp.end_epoch = end_epoch;

            print_chunk_path(&cp);

            // Aggiungi hosts a lista, senza duplicati
            int_array_append_unique(hosts, cp.src_host);
            int_array_append_unique(hosts, cp.dst_host);

            // Aggiungi switches a lista
            for (int sw_i = 0; sw_i < cp.switch_count; sw_i++) {
                int_array_append_unique(switches, cp.switches[sw_i]);
            }

            // Registra la trasmissione (src, dst, chunk)
            transmission_array_append(transmissions, (TransmissionEntry){.src = src, .dst = dst, .chunk = chunk});

            // Libera mem switches allocati in parse_path_string
            free(cp.switches);
        }
    }
}

// ====================
// Funzione principale
// ====================

int main(int argc, char *argv[]) {
    if (argc < 3) {
        fprintf(stderr, "Usage: %s config.json schedule.json\n", argv[0]);
        return 1;
    }

    const char *config_file = argv[1];
    const char *schedule_file = argv[2];

    // Legge il numero totale di chunk dal file di configurazione
    int total_chunks = read_num_chunks_from_config(config_file);
    if (total_chunks < 0) {
        return 1;
    }
    printf("Read total_chunks = %d from config file %s\n", total_chunks, config_file);

    // Legge lo schedule JSON
    char *json_data = read_file(schedule_file);
    if (!json_data) return 1;

    cJSON *json = cJSON_Parse(json_data);
    free(json_data);
    if (!json) {
        fprintf(stderr, "Error parsing JSON schedule\n");
        return 1;
    }

    cJSON *chunk_paths = cJSON_GetObjectItem(json, "8-Chunk paths");
    if (!chunk_paths) {
        fprintf(stderr, "\"8-Chunk paths\" not found in schedule JSON\n");
        cJSON_Delete(json);
        return 1;
    }

    // Inizializza array dinamici per hosts, switches e transmissions
    IntArray hosts, switches;
    int_array_init(&hosts);
    int_array_init(&switches);

    TransmissionArray transmissions;
    transmission_array_init(&transmissions);

    // Processa tutte le chunk_paths salvando hosts, switches, transmissions
    process_chunk_paths(chunk_paths, &hosts, &switches, &transmissions);

    // Stampa hosts unici
    printf("Hosts unici trovati: ");
    for (int i = 0; i < hosts.count; i++) {
        printf("%d ", hosts.data[i]);
    }
    printf("\n");

    // Stampa switches unici
    printf("Switches unici trovati: ");
    for (int i = 0; i < switches.count; i++) {
        printf("%d ", switches.data[i]);
    }
    printf("\n");

    // Allocazione matrice 3D piatta: host_count * host_count * total_chunks
    int host_count = hosts.count;
    int *chunk_matrix = calloc(host_count * host_count * total_chunks, sizeof(int));
    if (!chunk_matrix) {
        fprintf(stderr, "Memory allocation failed for chunk_matrix\n");
        transmission_array_free(&transmissions);
        int_array_free(&hosts);
        int_array_free(&switches);
        cJSON_Delete(json);
        return 1;
    }

    // Helper macro per indicizzazione matrice 3D piatta
    #define IDX(src, dst, chunk) ((src) * host_count * total_chunks + (dst) * total_chunks + (chunk))

    // Popola matrice chunk_matrix con le trasmissioni
    for (int i = 0; i < transmissions.count; i++) {
        TransmissionEntry t = transmissions.data[i];
        int src_idx = find_host_index(&hosts, t.src);
        int dst_idx = find_host_index(&hosts, t.dst);

        if (src_idx == -1 || dst_idx == -1) {
            fprintf(stderr, "Unknown host in transmission: src=%d dst=%d\n", t.src, t.dst);
            continue;
        }

        if (t.chunk < 0 || t.chunk >= total_chunks) {
            fprintf(stderr, "Chunk out of range: %d (total_chunks=%d)\n", t.chunk, total_chunks);
            continue;
        }

        chunk_matrix[IDX(src_idx, dst_idx, t.chunk)] = 1;
    }

    // Verifica la condizione allgather: ogni src deve inviare tutti chunk a ogni dst diverso
    int allgather = 1;
    for (int src = 0; src < host_count; src++) {
        for (int dst = 0; dst < host_count; dst++) {
            if (src == dst) continue;
            for (int c = 0; c < total_chunks; c++) {
                if (chunk_matrix[IDX(src, dst, c)] == 0) {
                    printf("Missing chunk %d from src %d to dst %d\n", c, hosts.data[src], hosts.data[dst]);
                    allgather = 0;
                }
            }
        }
    }

    if (allgather) {
        printf("The schedule corresponds to a valid allgather\n");
    } else {
        printf("The schedule is NOT a valid allgather\n");
    }

    // Cleanup generale
    free(chunk_matrix);
    transmission_array_free(&transmissions);
    int_array_free(&hosts);
    int_array_free(&switches);
    cJSON_Delete(json);

    return 0;
}
#undef IDX
