#!/usr/bin/env python3
"""
3-tier-memory plugin: frontmatter seal.

Tier-3 files (sessions/, learnings/, plans/, research/, reference/) are authored by
agents following /checkpoint-3t and /save-learning instructions. Those instructions
TELL the agent to write a `---` frontmatter block, but nothing ENFORCES it — so over a
large corpus some files end up with no frontmatter at all, which silently degrades them
(recall defaults importance to 5; consolidate/audit can't read type/date). This script
is the deterministic guarantee: any typed file missing its frontmatter block gets a
minimal one prepended. It runs as the final step of checkpoint/save-learning (prevention
at the source) and inside /enrich-3t (repair of legacy corpora).

Single responsibility: STRUCTURE only. It adds `type` / `date` / `status` and never adds
`importance` — that is enrich's job (its heuristic + dry-run preview). So a sealed file is
left WITHOUT importance, and a subsequent enrich importance pass scores it properly instead
of being locked at a placeholder value.

Guarantees:
  - DRY-RUN by default; writes only with --apply. `--count` prints just the number missing.
  - Idempotent: only files that LACK a leading `---` block are touched. Re-runs are no-ops.
  - Never reorders or edits the body — the block is PREPENDED, the original content untouched.
  - Atomic per-file writes (tmp + pid + os.replace with retry), preserving the file's own
    line endings (`newline=""`).
  - Skips archived content (archive/, *.bak, *.zip, *.archived.md, *-archived-*.md).

Usage:
    ensure-frontmatter.py <MEMORY_DIR> [--apply] [--count]

Output: per-file lines (dry-run/apply) + a SUMMARY line; or just an integer with --count.
"""
# sella-huellas: no (escribe .md de sessions/ learnings/ plans/ research/ reference/, nunca un indice: verificado 2026-09-11 corriendolo sobre un _pendientes.md sin frontmatter -> frontmatter_sealed=0. A diferencia de scan-secrets.py, que si recorria todo)
import os
import re
import sys
from datetime import date
import time

# Windows consoles often default to a legacy codepage (e.g. cp1252) that can't
# encode the → character this script prints, raising UnicodeEncodeError.
# Force UTF-8 regardless of the calling shell's locale.
if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8")

EXCLUDE_NAME_RE = re.compile(r"(\.bak(-|$)|\.zip$|\.archived\.md$|(^|-)archived-)", re.IGNORECASE)
DATE_RE = re.compile(r"(\d{4}-\d{2}-\d{2})")

# Typed Tier-3 folders → fallback `type:` value if the folder has no example to copy.
FOLDERS = {
    "sessions": "session",
    "learnings": "learnings",
    "plans": "plan",
    "research": "research",
    "reference": "reference",
}


def is_excluded(path):
    parts = path.replace("\\", "/").split("/")
    if "archive" in parts:
        return True
    return bool(EXCLUDE_NAME_RE.search(os.path.basename(path)))


def has_frontmatter(content):
    # A leading frontmatter block: first non-BOM char is '---' on its own line,
    # with a closing '---' later. Markdown horizontal rules mid-file don't count.
    if not content.startswith("---"):
        return False
    return content.find("\n---", 3) != -1


def sample_folder_type(dpath, fallback):
    """Copy the dominant `type:` value already used in this folder, so the seal
    matches the corpus's own schema instead of imposing one."""
    type_re = re.compile(r"^\s*type\s*:\s*(\S+)", re.IGNORECASE | re.MULTILINE)
    counts = {}
    for fn in sorted(os.listdir(dpath))[:60]:  # sample is plenty
        if not fn.endswith(".md") or is_excluded(fn):
            continue
        try:
            with open(os.path.join(dpath, fn), encoding="utf-8") as f:
                head = f.read(400)
        except Exception:
            continue
        if head.startswith("---"):
            m = type_re.search(head[: head.find("\n---", 3) if head.find("\n---", 3) != -1 else 400])
            if m:
                counts[m.group(1)] = counts.get(m.group(1), 0) + 1
    return max(counts, key=counts.get) if counts else fallback


def derive_date(path, content):
    """date: from filename → first date in content → file mtime (never a future date)."""
    m = DATE_RE.search(os.path.basename(path))
    if m:
        return m.group(1)
    m = DATE_RE.search(content[:2000])
    if m:
        return m.group(1)
    try:
        import datetime

        return datetime.date.fromtimestamp(os.path.getmtime(path)).isoformat()
    except Exception:
        return date.today().isoformat()


def build_block(tipo, fecha):
    return f"---\ntype: {tipo}\ndate: {fecha}\nstatus: active\n---\n\n"


REPLACE_RETRIES = 5   # Windows: antivirus/indexador pueden tener el .md abierto un instante


def escribir_preservando(path, content):
    """Escribe `content` con tmp+replace, sin convertir el salto de linea del fichero.

    Cuarta y quinta copias de este patron en el plugin (journal-compact.py, enrich-memory.py y
    normalize-pendientes.py son las otras). Las tres arrastraban los mismos defectos y la ronda 5
    del adversario encontro que este barrido nunca las habia buscado todas:

    1. `path + ".tmp"` fijo: dos procesos a la vez escriben el MISMO temporal y uno pisa al otro.
       El pid los separa.
    2. Modo texto por defecto: Python traduce "\n" al salto del sistema, asi que el fichero salia
       LF en macOS y CRLF en Windows. `newline=""` lo apaga; el contenido manda.
    3. `os.replace` pelado: en Windows un PermissionError transitorio tiraba la pasada entera.

    Y `newline=""` solo no basta: la lectura universal ya se llevo el "\r" antes. Hay que mirar el
    fichero en binario para saber que salto usaba. (Mismo error cometido y corregido aqui mismo.)
    """
    # El sniff va ANTES de escribir, sobre el fichero que todavia tiene el contenido viejo.
    # Hace falta porque la LECTURA es universal (`open(p, encoding="utf-8")` traduce "\r\n" a
    # "\n"), asi que para cuando el contenido llega aqui ya no queda ningun "\r" que respetar:
    # `newline=""` solo evita anadir traduccion, no devuelve la que la lectura se llevo.
    try:
        with open(path, "rb") as f:
            eol = "\r\n" if b"\r\n" in f.read() else "\n"
    except OSError:
        eol = "\n"
    if eol != "\n":
        content = content.replace("\r\n", "\n").replace("\n", eol)
    tmp = f"{path}.{os.getpid()}.tmp"
    with open(tmp, "w", encoding="utf-8", newline="") as f:
        f.write(content)
    for intento in range(REPLACE_RETRIES):
        try:
            os.replace(tmp, path)
            return
        except PermissionError:
            if intento == REPLACE_RETRIES - 1:
                raise
            time.sleep(0.05 * (intento + 1))


def main():
    args = sys.argv[1:]
    if not args:
        sys.exit("usage: ensure-frontmatter.py <MEMORY_DIR> [--apply] [--count]")
    memory_dir = args[0]
    apply = "--apply" in args
    count_only = "--count" in args
    if not os.path.isdir(memory_dir):
        sys.exit(f"not a directory: {memory_dir}")

    sealed, samples = 0, []
    for sub, fallback in FOLDERS.items():
        dpath = os.path.join(memory_dir, sub)
        if not os.path.isdir(dpath):
            continue
        tipo = sample_folder_type(dpath, fallback)
        # Top-level only — mirrors build-recall-index.py's scope. Nested .md
        # (snapshots, attachments, backups in subfolders) are NOT recall units,
        # so they are intentionally left alone.
        for fn in sorted(os.listdir(dpath)):
            if not fn.endswith(".md") or is_excluded(fn):
                continue
            p = os.path.join(dpath, fn)
            try:
                with open(p, encoding="utf-8") as f:
                    content = f.read()
            except Exception:
                continue
            if has_frontmatter(content):
                continue
            sealed += 1
            fecha = derive_date(p, content)
            if len(samples) < 10:
                samples.append((os.path.join(sub, fn), tipo, fecha))
            if apply:
                escribir_preservando(p, build_block(tipo, fecha) + content)

    if count_only:
        print(sealed)
        return

    mode = "APPLY (writing)" if apply else "DRY-RUN (no writes)"
    print(f"== ensure-frontmatter: {mode} — {memory_dir} ==")
    print(f"[frontmatter] files missing a block: {sealed}")
    for name, tipo, fecha in samples:
        print(f"   + {name} → ---\\ntype: {tipo}\\ndate: {fecha}\\nstatus: active\\n--- (importance left to /enrich-3t)")
    if not apply and sealed:
        print("DRY-RUN only — re-run with --apply to prepend these blocks.")
    print(f"SUMMARY frontmatter_sealed={sealed}")


if __name__ == "__main__":
    main()
