#!/usr/bin/env python3
"""
3-tier-memory plugin: one-time enrichment of EXISTING memory files.

v2.8.0 added two recall/decay signals that only get written to NEWLY created files:
  - `importance: 0-10` frontmatter on learnings/sessions (drives recall salience)
  - `_creado: YYYY-MM-DD` on pendientes (drives Fase C staleness/decay)
On a pre-existing corpus these fields are absent, so recall runs degraded (every unit
defaults to importance 5) and staleness never fires (no `_creado` → no age). This script
backfills those fields into existing files, deterministically and idempotently.

v2.12.0 added a third one, `_id: p-<10 hex>_` on pendientes: the identity the journal
compactor (journal-compact.py) uses to resolve a line without editing the index by hand.
Same hash as journal-emit.py (sha1 of normalized text + creado + origen), loaded from that
script so the two can never drift. Lines without `_creado` are skipped for ids until the
creado pass has run (in one `--apply` run creado goes first, so both land together).

It MUTATES the live memory tree, so it is conservative by construction:
  - DRY-RUN by default; writes only with --apply.
  - Idempotent: only touches lines/files that LACK the field. Re-runs are no-ops.
  - Never reorders, reflows, or edits rule/pendiente TEXT — only appends/inserts a field.
  - Atomic per-file writes (tmp + os.replace) — a crash never leaves a half-written file.
  - Skips archived content (memory/archive/, *.bak, *.zip, *.archived.md, *-archived-*.md).
  - Files without frontmatter are FLAGGED, never auto-rewritten.

Usage:
    enrich-memory.py <MEMORY_DIR> [--apply] [--only creado|importance|id[,...]]

Output: a human-readable preview/report to stdout, ending with a one-line machine summary
(`SUMMARY creado_added=.. importance_added=.. skipped_no_frontmatter=..`).
"""
import os
import re
import sys
from datetime import date

# Windows consoles often default to a legacy codepage (e.g. cp1252) that can't
# encode the →/—/… characters this script prints, raising UnicodeEncodeError.
# Force UTF-8 regardless of the calling shell's locale.
if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8")

EXCLUDE_NAME_RE = re.compile(r"(\.bak(-|$)|\.zip$|\.archived\.md$|(^|-)archived-)", re.IGNORECASE)
DATE_RE = re.compile(r"(\d{4}-\d{2}-\d{2})")
ORIGEN_RE = re.compile(r"(_origen:\s*\[\[[^\]]+\]\]_)")
CREADO_RE = re.compile(r"_creado:\s*\d{4}-\d{2}-\d{2}")
IMPORTANCE_FM_RE = re.compile(r"^\s*importance\s*:", re.IGNORECASE | re.MULTILINE)

# Imperative / criticality markers → higher learning salience. Kept deliberately
# STRONG/specific: generic words like "gate"/"must" were dropped because they appear
# in nearly every file of a governance-heavy corpus and flatten the signal.
HIGH_MARKERS = re.compile(
    r"\b(cr[ií]tico|critical|nunca|never|siempre|always|cuidado|obligatori|blocking)\b",
    re.IGNORECASE,
)


def is_excluded(path):
    parts = path.replace("\\", "/").split("/")
    if "archive" in parts:
        return True
    return bool(EXCLUDE_NAME_RE.search(os.path.basename(path)))


def atomic_write(path, content):
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        f.write(content)
    os.replace(tmp, path)


def mtime_date(path):
    try:
        import datetime

        return datetime.date.fromtimestamp(os.path.getmtime(path)).isoformat()
    except Exception:
        return date.today().isoformat()


FM_DATE_RE = re.compile(r"^\s*date\s*:\s*(\d{4}-\d{2}-\d{2})", re.IGNORECASE | re.MULTILINE)
LINK_RE = re.compile(r"\[\[([^\]]+)\]\]")


def linked_file_date(memory_dir, origen_text):
    """Resolve a creation date from the file a pendiente's _origen links to.

    Used when the wikilink slug carries no date (e.g. _origen: [[learnings/foo]]).
    Reads the linked file's frontmatter `date:`. Returns None if unresolvable.
    """
    m = LINK_RE.search(origen_text)
    if not m:
        return None
    target = m.group(1).split("#")[0].strip()  # drop any #anchor
    fp = os.path.join(memory_dir, target + ".md")
    if not os.path.isfile(fp):
        return None
    try:
        with open(fp, encoding="utf-8") as f:
            head = f.read(600)
    except Exception:
        return None
    dm = FM_DATE_RE.search(head)
    return dm.group(1) if dm else None


# ----------------------------------------------------------------------------- pendientes
def enrich_pendientes(memory_dir, apply):
    path = os.path.join(memory_dir, "_pendientes.md")
    if not os.path.isfile(path):
        return {"creado_added": 0, "samples": [], "fallback_mtime": 0}
    with open(path, encoding="utf-8") as f:
        lines = f.read().split("\n")
    fallback = mtime_date(path)
    added, mtime_used, samples = 0, 0, []
    out = []
    for line in lines:
        if not re.match(r"^- \[ \]", line) or CREADO_RE.search(line):
            out.append(line)
            continue
        # Derive the date, in priority order:
        #   1) date embedded in the _origen wikilink slug (sessions/YYYY-MM-DD-…)
        #   2) frontmatter `date:` of the file _origen links to (e.g. learnings/…)
        #   3) file mtime of _pendientes.md (coarse last resort; never a future date)
        origen = ORIGEN_RE.search(line)
        derived = None
        if origen:
            md = DATE_RE.search(origen.group(1))
            derived = md.group(1) if md else linked_file_date(memory_dir, origen.group(1))
        created = derived or fallback
        if not derived:
            mtime_used += 1
        field = f" — _creado: {created}_"
        if origen:
            # Insert right after the _origen token (canonical checkpoint order).
            newline = line[: origen.end()] + field + line[origen.end():]
        else:
            newline = line + field  # no origen → append at end of line
        added += 1
        if len(samples) < 4:
            samples.append((line, newline))
        out.append(newline)
    if apply and added:
        atomic_write(path, "\n".join(out))
    return {"creado_added": added, "samples": samples, "fallback_mtime": mtime_used}


# ----------------------------------------------------------------------------- _id (journal)
ID_RE = re.compile(r"_id:\s*p-[0-9a-f]{10}_")


def load_pendiente_id():
    """journal-emit.pendiente_id, importado del script vecino: una sola definicion del hash."""
    import importlib.util

    path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "journal-emit.py")
    spec = importlib.util.spec_from_file_location("journal_emit", path)
    if spec is None or spec.loader is None:
        return None
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod.pendiente_id


def enrich_ids(memory_dir, apply):
    path = os.path.join(memory_dir, "_pendientes.md")
    stats = {"id_added": 0, "id_skipped_no_creado": 0, "samples": []}
    if not os.path.isfile(path):
        return stats
    pendiente_id = load_pendiente_id()
    if pendiente_id is None:
        print("   ! journal-emit.py no encontrado junto a este script — ids omitidos")
        return stats
    with open(path, encoding="utf-8") as f:
        lines = f.read().split("\n")
    out = []
    for line in lines:
        if not re.match(r"^- \[ \]", line) or ID_RE.search(line):
            out.append(line)
            continue
        creado = re.search(r"_creado:\s*(\d{4}-\d{2}-\d{2})", line)
        if not creado:
            stats["id_skipped_no_creado"] += 1
            out.append(line)
            continue
        origen = ORIGEN_RE.search(line)
        origen_txt = re.search(r"\[\[[^\]]+\]\]", origen.group(1)).group(0) if origen else ""
        text = re.sub(r"\s*—\s*_(origen|creado):[^—]*", "", line[5:]).strip()
        pid = pendiente_id(text, creado.group(1), origen_txt)
        newline = line.rstrip() + f" — _id: {pid}_"
        stats["id_added"] += 1
        if len(stats["samples"]) < 4:
            stats["samples"].append((line, newline))
        out.append(newline)
    if apply and stats["id_added"]:
        atomic_write(path, "\n".join(out))
    return stats


# ----------------------------------------------------------------------------- importance
def split_frontmatter(content):
    """Return (fm, rest, has_fm). fm excludes the fences; rest is the body incl. fences boundary."""
    if not content.startswith("---"):
        return None, content, False
    end = content.find("\n---", 3)
    if end == -1:
        return None, content, False
    return content[3:end], content[end:], True


def score_learning(content):
    hits = len(set(m.group(0).lower() for m in HIGH_MARKERS.finditer(content)))
    if hits >= 2:
        return 8
    if hits == 1:
        return 7
    return 5


def _section_has_content(content, name):
    m = re.search(r"## " + name + r"(.*?)(\n## |\Z)", content, re.DOTALL)
    if not m:
        return False
    t = m.group(1).strip().lower()
    return len(t) > 15 and "ninguno" not in t and "n/a" not in t


def score_session(content, fm):
    """Sessions: only DEMOTE the clearly trivial; leave substantive ones NEUTRAL.

    Returns None for the neutral case → no field written (recall uses its default 5).
    A uniform high score across a corpus of substantive sessions is a no-op for
    ranking (importance scales relevance uniformly), so we don't fake precision.
    Importance does its real work on learnings; for sessions it just suppresses noise.
    """
    if "backfilled" in (fm or "").lower() and len(content) < 800:
        return 3
    produced = _section_has_content(content, "Learnings generados") or _section_has_content(
        content, "Plans?"
    )
    if not produced:
        return 4  # session that yielded no durable artifact → lower salience
    return None  # substantive → neutral (no write)


def enrich_importance(memory_dir, apply):
    stats = {"importance_added": 0, "left_neutral": 0, "skipped_no_frontmatter": [], "samples": []}
    for sub, scorer in (("learnings", score_learning), ("sessions", score_session)):
        d = os.path.join(memory_dir, sub)
        if not os.path.isdir(d):
            continue
        for fn in sorted(os.listdir(d)):
            if not fn.endswith(".md") or is_excluded(fn):
                continue
            p = os.path.join(d, fn)
            with open(p, encoding="utf-8") as f:
                content = f.read()
            fm, rest, has_fm = split_frontmatter(content)
            if not has_fm:
                stats["skipped_no_frontmatter"].append(os.path.join(sub, fn))
                continue
            if IMPORTANCE_FM_RE.search(fm):
                continue  # idempotent: already scored (incl. hand-tuned)
            score = scorer(content, fm) if sub == "sessions" else scorer(content)
            if score is None:
                stats["left_neutral"] += 1  # substantive session → keep recall default
                continue
            new_content = "---" + fm.rstrip("\n") + f"\nimportance: {score}" + rest
            stats["importance_added"] += 1
            if len(stats["samples"]) < 8:
                stats["samples"].append((os.path.join(sub, fn), score))
            if apply:
                atomic_write(p, new_content)
    return stats


def main():
    args = sys.argv[1:]
    if not args:
        sys.exit("usage: enrich-memory.py <MEMORY_DIR> [--apply] [--only creado|importance]")
    memory_dir = args[0]
    apply = "--apply" in args
    # --only acepta una lista: `--only creado,id` es lo que corre /checkpoint-3t Step 3-pre
    # (creado primero, porque el id se calcula con esa fecha).
    only = None
    if "--only" in args:
        i = args.index("--only")
        if i + 1 < len(args):
            only = set(p.strip() for p in args[i + 1].split(",") if p.strip())

    def wants(kind):
        return only is None or kind in only
    if not os.path.isdir(memory_dir):
        sys.exit(f"not a directory: {memory_dir}")

    mode = "APPLY (writing)" if apply else "DRY-RUN (no writes)"
    print(f"== enrich-memory: {mode} — {memory_dir} ==\n")

    p_stats = {"creado_added": 0, "samples": [], "fallback_mtime": 0}
    i_stats = {"importance_added": 0, "left_neutral": 0, "skipped_no_frontmatter": [], "samples": []}

    if wants("creado"):
        p_stats = enrich_pendientes(memory_dir, apply)
        print(f"[_creado] pendientes to enrich: {p_stats['creado_added']} "
              f"({p_stats['fallback_mtime']} via file mtime, rest from _origen slug)")
        for old, new in p_stats["samples"]:
            tail = new[len(os.path.commonprefix([old, new])):]
            print(f"   + …{tail.strip()[:70]}")
        print()

    id_stats = {"id_added": 0, "id_skipped_no_creado": 0, "samples": []}
    if wants("id"):
        id_stats = enrich_ids(memory_dir, apply)
        print(f"[_id] pendientes to enrich: {id_stats['id_added']} "
              f"({id_stats['id_skipped_no_creado']} skipped: no _creado yet)")
        for old, new in id_stats["samples"]:
            tail = new[len(os.path.commonprefix([old, new])):]
            print(f"   + …{tail.strip()[:70]}")
        print()

    if wants("importance"):
        i_stats = enrich_importance(memory_dir, apply)
        print(f"[importance] files to enrich: {i_stats['importance_added']} "
              f"({i_stats['left_neutral']} substantive sessions left neutral=5)")
        for name, score in i_stats["samples"]:
            print(f"   + {name} → importance: {score}")
        if i_stats["skipped_no_frontmatter"]:
            print(f"   ! {len(i_stats['skipped_no_frontmatter'])} file(s) FLAGGED — no frontmatter, "
                  f"left untouched (handle manually):")
            for name in i_stats["skipped_no_frontmatter"][:8]:
                print(f"       {name}")
        print()

    if not apply:
        print("DRY-RUN only — re-run with --apply to write these changes.")
    print(f"SUMMARY creado_added={p_stats['creado_added']} "
          f"id_added={id_stats['id_added']} "
          f"importance_added={i_stats['importance_added']} "
          f"skipped_no_frontmatter={len(i_stats['skipped_no_frontmatter'])}")


if __name__ == "__main__":
    main()
