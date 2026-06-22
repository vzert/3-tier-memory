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
  - Atomic per-file writes (tmp + os.replace).
  - Skips archived content (archive/, *.bak, *.zip, *.archived.md, *-archived-*.md).

Usage:
    ensure-frontmatter.py <MEMORY_DIR> [--apply] [--count]

Output: per-file lines (dry-run/apply) + a SUMMARY line; or just an integer with --count.
"""
import os
import re
import sys
from datetime import date

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
                tmp = p + ".tmp"
                with open(tmp, "w", encoding="utf-8") as f:
                    f.write(build_block(tipo, fecha) + content)
                os.replace(tmp, p)

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
