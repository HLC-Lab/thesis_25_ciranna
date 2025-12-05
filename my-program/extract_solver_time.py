#!/usr/bin/env python3
import json
import sys
import os

def main():
    if len(sys.argv) != 3:
        print(f"Uso: {sys.argv[0]} <input.json> <output.txt>")
        sys.exit(1)

    input_path = sys.argv[1]
    output_path = sys.argv[2]

    if not os.path.isfile(input_path):
        print(f"[ERRORE] File JSON non trovato: {input_path}")
        sys.exit(1)

    try:
        with open(input_path, "r") as f:
            data = json.load(f)
    except json.JSONDecodeError as e:
        print(f"[ERRORE] JSON non valido in {input_path}: {e}")
        sys.exit(1)

    if "Solver_Time" not in data:
        print(f"[ERRORE] Chiave 'Solver_Time' mancante nel file {input_path}")
        sys.exit(1)

    solver_time = data["Solver_Time"]

    # Scrive solo il valore numerico nel file di output
    with open(output_path, "w") as f:
        f.write(f"{solver_time}\n")

    print(f"[OK] Solver_Time={solver_time} scritto in {output_path}")

if __name__ == "__main__":
    main()
