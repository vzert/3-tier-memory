#!/usr/bin/env python3
"""
3-tier-memory plugin: wikilink integrity checker.

Walks the memory tree, extracts every [[target]] / [[target|alias]] / [[path#anchor]]
reference, and resolves each against the set of existing memory files. Emits the links
whose target file does not exist. Deterministic and fast — validating hundreds of links
by hand (or by agent) is slow and error-prone, so /audit-3t runs this instead.

Resolution: a target resolves if it matches an existing file either by its path relative
to memory/ (without .md) — e.g. `sessions/2026-06-21-foo`, `_pendientes`, `learnings/bar`
— or by bare basename — e.g. `[[2026-06-21-foo]]`. `#anchor` and `|alias` are stripped
before resolving (anchors point at a rule inside a file; we only verify the file exists).

Archived files (memory/archive/, *.bak, *.zip, *.archived.md, *-archived-*.md) are neither
scanned for links nor reported as broken targets.

Usage:
    check-wikilinks.py <MEMORY_DIR>

Output: one `BROKEN <source> -> [[target]]` line per broken link, then a SUMMARY line.
Exit 0 always.
"""
import os
import re
import sys

EXCLUDE_NAME_RE = re.compile(r"(\.bak(-|$)|\.zip$|\.archived\.md$|(^|-)archived-)", re.IGNORECASE)
LINK_RE = re.compile(r"\[\[([^\]]+)\]\]")


def is_excluded(path):
    parts = path.replace("\\", "/").split("/")
    if "archive" in parts:
        return True
    return bool(EXCLUDE_NAME_RE.search(os.path.basename(path)))


def walk_md(memory_dir):
    for root, dirs, files in os.walk(memory_dir):
        dirs[:] = [d for d in dirs if d != "archive"]
        for fn in files:
            if not fn.endswith(".md") or is_excluded(fn):
                continue
            yield os.path.join(root, fn)


def normalize(target):
    """Strip alias and anchor; drop a trailing .md; normalize slashes.

    Handles `\\|` — wikilinks inside markdown tables escape the alias pipe — so the
    path part doesn't keep a trailing backslash. Returns "" for non-link noise
    (e.g. POSIX classes like [[:space:]]) so callers can skip it.
    """
    t = target.replace("\\|", "|").split("|")[0].split("#")[0].strip().rstrip("\\")
    # Skip non-link noise: POSIX classes ([[:space:]]), absolute paths (external
    # references, not memory wikilinks), template placeholders ({slug}), and
    # ellipsis examples ([[...]]) found in docs/templates.
    if not t or ":" in t or t.startswith("/") or "{" in t or "}" in t or set(t) == {"."}:
        return ""
    if t.endswith(".md"):
        t = t[:-3]
    return t.replace("\\", "/")


def main():
    if len(sys.argv) < 2:
        sys.exit("usage: check-wikilinks.py <MEMORY_DIR>")
    memory_dir = sys.argv[1]
    if not os.path.isdir(memory_dir):
        sys.exit(f"not a directory: {memory_dir}")

    # Build the resolvable name sets: relative-path-without-ext and bare basename.
    rel_paths, basenames = set(), set()
    for path in walk_md(memory_dir):
        rel = os.path.relpath(path, memory_dir).replace("\\", "/")
        rel_paths.add(rel[:-3] if rel.endswith(".md") else rel)
        basenames.add(os.path.splitext(os.path.basename(path))[0])

    broken = []
    seen = set()
    for path in walk_md(memory_dir):
        src = os.path.relpath(path, memory_dir).replace("\\", "/")
        try:
            with open(path, encoding="utf-8") as f:
                content = f.read()
        except Exception:
            continue
        for m in LINK_RE.finditer(content):
            target = normalize(m.group(1))
            if not target:
                continue
            if target in rel_paths or os.path.basename(target) in basenames:
                continue
            key = (src, target)
            if key in seen:
                continue
            seen.add(key)
            broken.append((src, m.group(1)))

    for src, raw in broken:
        print(f"BROKEN {src} -> [[{raw}]]")
    print(f"SUMMARY broken_links={len(broken)} files_scanned={len(rel_paths)}")


if __name__ == "__main__":
    main()
