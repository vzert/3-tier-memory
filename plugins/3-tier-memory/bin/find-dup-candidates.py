#!/usr/bin/env python3
"""
3-tier-memory plugin: duplicate-candidate generator.

Reads the derived recall index (.recall-index.jsonl, built by build-recall-index.py)
and emits ranked near-duplicate PAIRS using set-overlap (Jaccard) on the per-unit
`keywords` token sets. This is a cheap, deterministic PRE-FILTER for /consolidate-3t:
instead of an O(n²) blind semantic scan by an agent, the agent judges only the small
candidate set this script surfaces. If nothing crosses the threshold, consolidate can
early-exit ("corpus clean") without spawning a single agent.

Why Jaccard on keywords: the index stores a DEDUPED unique-token set per unit (no
frequencies), so set overlap is the right metric — frequency-weighted cosine would
need data the index does not keep.

Usage:
    find-dup-candidates.py <INDEX_PATH> [--tipo learning] [--limit N]

Env:
    DUP_JACCARD_THRESHOLD   strong-candidate cutoff (default 0.5)

Output (stdout): a single JSON object
    {
      "threshold": 0.5,
      "tipo": "learning",
      "n_units": 312,
      "candidates":  [ {a:{path,texto,id}, b:{...}, jaccard, shared:[...]}, ... ],
      "borderline":  [ ... up to 5, jaccard in [0.35, threshold) ... ]
    }
Exit 0 always (empty arrays when index missing/empty) so callers never crash.
"""
# sella-huellas: no (solo lee y reporta candidatos a duplicado)
import json
import os
import sys
from itertools import combinations

# UTF-8 en stdout Y EN STDERR. La guarda anterior solo cubria stdout, asi que un mensaje de error
# con un caracter no-ASCII —el nombre de un directorio, por ejemplo— seguia saliendo mutilado:
# `no existe /…/memoria\u2014x/_pendientes.md`. Por stdout con una pagina OEM el proceso MUERE;
# por stderr DEGRADA a la forma escapada. Menos grave, igual de falso. Lo encontro un adversario
# externo el 2026-09-12 y se reprodujo aqui.
#
# Se pone en TODOS los .py de bin/, no solo en los que "parecen" imprimir no-ASCII: eso ultimo no
# se puede decidir leyendo el fuente —una variable, un f-string armado antes, una ruta, el mensaje
# de una excepcion— y el detector que lo intentaba fue justo lo que dejo pasar este hueco.
for _flujo in (sys.stdout, sys.stderr):
    if hasattr(_flujo, "reconfigure"):
        _flujo.reconfigure(encoding="utf-8")

STRONG = float(os.environ.get("DUP_JACCARD_THRESHOLD", "0.5"))
BORDER_LO = 0.35          # borderline bucket floor
MIN_SHARED = 2            # absolute floor: tiny sets sharing one generic token ≠ dup
BORDER_MAX = 5            # how many borderline pairs to surface


def load_units(index_path, tipo):
    """Load units of the requested tipo, skipping Quick Reference projections.

    Quick Reference bullets (path == memory/_learnings.md) are a dual-write
    PROJECTION of canonical rules — they intentionally restate them and would
    flood the output with false "duplicates". Exclude them from candidacy.
    """
    units = []
    if not index_path or not os.path.isfile(index_path):
        return units
    with open(index_path, encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                u = json.loads(line)
            except ValueError:
                continue
            if u.get("tipo") != tipo:
                continue
            if u.get("path") == "memory/_learnings.md":
                continue
            kws = u.get("keywords") or []
            if len(kws) < MIN_SHARED:
                continue  # too few tokens to ever clear the MIN_SHARED gate
            u["_kw"] = set(kws)
            units.append(u)
    return units


def candidate_pairs(units):
    """Generate (i, j) pairs that share ≥1 token, via an inverted index.

    Avoids the full n² product: only units co-occurring in some token's bucket
    are ever compared. Pairs are de-duplicated across buckets.
    """
    inverted = {}
    for idx, u in enumerate(units):
        for tok in u["_kw"]:
            inverted.setdefault(tok, []).append(idx)
    seen = set()
    for bucket in inverted.values():
        if len(bucket) < 2:
            continue
        for i, j in combinations(bucket, 2):
            key = (i, j) if i < j else (j, i)
            seen.add(key)
    return seen


def score(units, pairs):
    strong, border = [], []
    for i, j in pairs:
        a, b = units[i], units[j]
        ka, kb = a["_kw"], b["_kw"]
        shared = ka & kb
        if len(shared) < MIN_SHARED:
            continue
        jac = len(shared) / len(ka | kb)
        rec = {
            "a": {"path": a.get("path"), "texto": a.get("texto"), "id": a.get("id")},
            "b": {"path": b.get("path"), "texto": b.get("texto"), "id": b.get("id")},
            "jaccard": round(jac, 3),
            "shared": sorted(shared),
        }
        if jac >= STRONG:
            strong.append(rec)
        elif jac >= BORDER_LO:
            border.append(rec)
    strong.sort(key=lambda r: r["jaccard"], reverse=True)
    border.sort(key=lambda r: r["jaccard"], reverse=True)
    return strong, border[:BORDER_MAX]


def main():
    args = sys.argv[1:]
    tipo = "learning"
    index_path = None
    i = 0
    while i < len(args):
        if args[i] == "--tipo" and i + 1 < len(args):
            tipo = args[i + 1]
            i += 2
        elif args[i] == "--limit" and i + 1 < len(args):
            i += 2  # reserved; output is already small
        else:
            index_path = args[i]
            i += 1

    units = load_units(index_path, tipo)
    strong, border = score(units, candidate_pairs(units)) if units else ([], [])
    json.dump(
        {
            "threshold": STRONG,
            "tipo": tipo,
            "n_units": len(units),
            "candidates": strong,
            "borderline": border,
        },
        sys.stdout,
        ensure_ascii=False,
        indent=2,
    )
    sys.stdout.write("\n")


if __name__ == "__main__":
    main()
