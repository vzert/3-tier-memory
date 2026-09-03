#!/usr/bin/env python3
"""
3-tier-memory plugin: recall index builder.

Flattens the project memory into "recallable units" and writes them as JSONL.
This is a DERIVED cache — regenerable at any time, never the source of truth.
It is consumed by recall.sh (UserPromptSubmit hook) to surface memory relevant
to the user's prompt, using lexical (BM25-lite) scoring × recency × importance.

Usage:
    build-recall-index.py <MEMORY_DIR> <OUTPUT_PATH>

Output: one JSON object per line, each with:
    id, tipo, texto, path, fecha (YYYY-MM-DD|""), importance (0-10), keywords[]

Zero third-party dependencies. Tolerant of legacy files missing new fields.
"""
import json
import os
import re
import sys

# Stopwords ES + EN — kept small and high-value; recall is lexical so we only
# need to drop the highest-frequency noise that would pollute IDF.
STOPWORDS = set("""
a al algo alguna algunas alguno algunos ante antes como con contra cual cuando
de del desde donde dos el ella ellas ellos en entre era eran es esa esas ese eso
esos esta estaba estado estar estas este esto estos fue fueron ha hace hacer han
hasta hay la las le les lo los mas me mi mis mucho muy no nos o os otra otras otro
otros para pero poco por porque que quien se sea ser si sin sobre solo son su sus
tan te tiene todo todos tu tus un una uno unos y ya
the a an and or but if then else for to of in on at by with from into is are was
were be been being this that these those it its as not no do does did have has had
will would can could should may might must about over under more most some any all
you your we our they them he she his her how what when where which who why
""".split())

# Tokens of length ≥3, OR length-2 tokens containing a digit (captures
# identifiers like "3t", "v2", version/issue numbers — high-signal).
WORD_RE = re.compile(r"[a-záéíóúüñ0-9]{2,}", re.IGNORECASE)
DATE_RE = re.compile(r"(\d{4}-\d{2}-\d{2})")
IMPORTANCE_RE = re.compile(r"^\s*importance\s*:\s*(\d+)", re.IGNORECASE | re.MULTILINE)

# Archived content is excluded from the recall index (and skipped by
# consolidate/audit too). Convention: anything under an `archive/` subtree, or
# files named *.bak / *.bak-* / *.zip / *.archived.md / archived-*.md.
EXCLUDE_NAME_RE = re.compile(r"(\.bak(-|$)|\.zip$|\.archived\.md$|(^|-)archived-)", re.IGNORECASE)


def is_excluded(path):
    """True if a memory file should be ignored (archived / backup / zip)."""
    parts = path.replace("\\", "/").split("/")
    if "archive" in parts:
        return True
    return bool(EXCLUDE_NAME_RE.search(os.path.basename(path)))


def tokenize(text):
    """Lowercase, strip accents-insensitive isn't needed; keep ES letters."""
    toks = []
    seen = set()
    for m in WORD_RE.findall(text.lower()):
        if m in seen or m in STOPWORDS:
            continue
        if len(m) < 3 and not any(c.isdigit() for c in m):
            continue
        seen.add(m)
        toks.append(m)
    return toks


def read(path):
    try:
        with open(path, encoding="utf-8") as f:
            return f.read()
    except Exception:
        return ""


def frontmatter_importance(content, default=5):
    # Frontmatter is between the first two '---' lines.
    if content.startswith("---"):
        end = content.find("\n---", 3)
        if end != -1:
            fm = content[:end]
            m = IMPORTANCE_RE.search(fm)
            if m:
                try:
                    return max(0, min(10, int(m.group(1))))
                except ValueError:
                    pass
    return default


def truncate(text, n=240):
    text = " ".join(text.split())
    return text if len(text) <= n else text[: n - 1].rstrip() + "…"


def add_unit(units, tipo, texto, path, fecha, importance):
    texto = truncate(texto)
    if not texto:
        return
    kws = tokenize(texto)
    if not kws:
        return
    units.append(
        {
            "id": f"{tipo}:{len(units)}",
            "tipo": tipo,
            "texto": texto,
            "path": path,
            "fecha": fecha or "",
            "importance": importance,
            "keywords": kws,
        }
    )


def parse_learnings(memory_dir, units):
    """Each numbered rule in learnings/*.md is a unit (high-signal, atomic).
    Falls back to Quick Reference bullets in _learnings.md."""
    ldir = os.path.join(memory_dir, "learnings")
    rule_re = re.compile(r"^\s*\d+\.\s+(.*)")
    if os.path.isdir(ldir):
        for fn in sorted(os.listdir(ldir)):
            if not fn.endswith(".md") or is_excluded(fn):
                continue
            path = os.path.join(ldir, fn)
            content = read(path)
            imp = frontmatter_importance(content)
            rel = os.path.join("memory", "learnings", fn)
            found = False
            for line in content.splitlines():
                m = rule_re.match(line)
                if m:
                    found = True
                    add_unit(units, "learning", m.group(1), rel, "", imp)
            if not found:
                # whole-file fallback (strip frontmatter + headers)
                body = re.sub(r"^---.*?---", "", content, count=1, flags=re.DOTALL)
                add_unit(units, "learning", body, rel, "", imp)

    # Quick Reference bullets in _learnings.md (critical rules, may overlap)
    qref = read(os.path.join(memory_dir, "_learnings.md"))
    section = re.search(r"## Quick Reference(.*?)(\n## |\Z)", qref, re.DOTALL)
    if section:
        for line in section.group(1).splitlines():
            s = line.strip()
            if s.startswith("- "):
                add_unit(units, "learning", s[2:], "memory/_learnings.md", "", 8)


def parse_sessions(memory_dir, units):
    """Session index rows (resumen) + Contexto block of each session file."""
    idx = read(os.path.join(memory_dir, "_session-index.md"))
    for line in idx.splitlines():
        if line.strip().startswith("|") and "[[" in line:
            cells = [c.strip() for c in line.strip().strip("|").split("|")]
            d = ""
            for c in cells:
                md = DATE_RE.search(c)
                if md:
                    d = md.group(1)
                    break
            # longest cell is usually the resumen
            resumen = max(cells, key=len) if cells else ""
            add_unit(units, "session", resumen, "memory/_session-index.md", d, 5)

    sdir = os.path.join(memory_dir, "sessions")
    if os.path.isdir(sdir):
        for fn in sorted(os.listdir(sdir)):
            if not fn.endswith(".md") or is_excluded(fn):
                continue
            content = read(os.path.join(sdir, fn))
            md = DATE_RE.search(fn)
            d = md.group(1) if md else ""
            imp = frontmatter_importance(content)
            ctx = re.search(r"## Contexto(.*?)(\n## |\Z)", content, re.DOTALL)
            title = re.search(r"^#\s+(.*)", content, re.MULTILINE)
            text = (title.group(1) + ". " if title else "") + (
                ctx.group(1).strip() if ctx else ""
            )
            add_unit(units, "session", text, os.path.join("memory", "sessions", fn), d, imp)


def parse_pendientes(memory_dir, units):
    content = read(os.path.join(memory_dir, "_pendientes.md"))
    prio_imp = {"alta": 9, "media": 5, "baja": 2}
    current = "media"
    for line in content.splitlines():
        s = line.strip()
        low = s.lower()
        if low.startswith("## alta"):
            current = "alta"
        elif low.startswith("## media"):
            current = "media"
        elif low.startswith("## baja"):
            current = "baja"
        elif low.startswith("## "):
            current = "media"
        elif re.match(r"^- \[ \]", s):
            md = DATE_RE.search(s)
            d = md.group(1) if md else ""
            text = re.sub(r"\s*—\s*_(origen|creado|id):[^—]*", "", s[6:]).strip()
            add_unit(units, "pendiente", text, "memory/_pendientes.md", d, prio_imp[current])


def parse_index_rows(memory_dir, fname, tipo, units):
    content = read(os.path.join(memory_dir, fname))
    rel = os.path.join("memory", fname)
    for line in content.splitlines():
        s = line.strip()
        if s.startswith("|") and "[[" in s and "---" not in s:
            cells = [c.strip() for c in s.strip("|").split("|")]
            d = ""
            for c in cells:
                md = DATE_RE.search(c)
                if md:
                    d = md.group(1)
                    break
            text = " ".join(c for c in cells if c)
            add_unit(units, tipo, text, rel, d, 5)


def main():
    if len(sys.argv) < 3:
        sys.exit("usage: build-recall-index.py <MEMORY_DIR> <OUTPUT_PATH>")
    memory_dir, out_path = sys.argv[1], sys.argv[2]
    if not os.path.isdir(memory_dir):
        sys.exit(0)

    units = []
    parse_learnings(memory_dir, units)
    parse_sessions(memory_dir, units)
    parse_pendientes(memory_dir, units)
    parse_index_rows(memory_dir, "_plans-index.md", "plan", units)
    parse_index_rows(memory_dir, "_research-index.md", "research", units)

    tmp = out_path + ".tmp"
    os.makedirs(os.path.dirname(out_path), exist_ok=True)
    with open(tmp, "w", encoding="utf-8") as f:
        for u in units:
            f.write(json.dumps(u, ensure_ascii=False) + "\n")
    os.replace(tmp, out_path)
    print(len(units))


if __name__ == "__main__":
    main()
