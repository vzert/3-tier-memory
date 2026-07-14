#!/usr/bin/env python3
"""
3-tier-memory plugin: secret scanner + redactor.

Memory artifacts (sessions/, plans/, research/, reference/) are authored by agents
summarizing real work — and that work sometimes includes real API keys, tokens, or
private keys pasted verbatim into the digest. /checkpoint-3t Step 6 runs `git add
memory/` and commits, so in any project where `memory/` is NOT gitignored, those
secrets get committed and (on push) leak to the remote. A redaction RULE in the
checkpoint instructions is not enough — the agent eventually forgets it. This script
is the deterministic guarantee, same philosophy as ensure-frontmatter.py.

Two responsibilities, one pass:
  - DETECT (default / --count): report secret-shaped strings, never failing, never
    echoing the secret itself (matches are masked in output).
  - REDACT (--apply): replace each detected secret VALUE with <REDACTED> in place.
    Used as the gate in /checkpoint-3t Step 6 (redact-then-commit) so a leak is
    prevented, not just reported after the fact.

Detection favours HIGH-CONFIDENCE shapes (known key prefixes, private-key blocks,
JWTs) plus a context-gated generic `key = value` rule that only fires on mixed
alphanumeric values, so plain-English prose isn't shredded. Placeholders already in
the safe form ($VAR, ${VAR}, <REDACTED>, your-key-here, ...) are never touched, which
also makes the script idempotent: re-running --apply is a no-op.

Guarantees:
  - DRY-RUN by default; writes only with --apply. `--count` prints just the number found.
  - Idempotent: <REDACTED> / $VAR / placeholder values are skipped, so re-runs are no-ops.
  - Atomic per-file writes (tmp + os.replace). Body is otherwise byte-identical.
  - Never prints a secret value — only its type, line number, and a masked fragment.
  - Skips archived content (archive/, *.bak, *.zip, *.archived.md, *-archived-*.md).

Usage:
    scan-secrets.py <MEMORY_DIR> [--apply] [--count]

Output: per-finding masked lines + a SUMMARY line; or just an integer with --count.
Exit code 0 always (detection is advisory; the gate reads the SUMMARY/count).
"""
import os
import re
import sys

# Windows consoles often default to a legacy codepage (e.g. cp1252) that can't
# encode the —/… characters this script prints, raising UnicodeEncodeError.
# Force UTF-8 regardless of the calling shell's locale.
if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8")

EXCLUDE_NAME_RE = re.compile(r"(\.bak(-|$)|\.zip$|\.archived\.md$|(^|-)archived-)", re.IGNORECASE)

# Each entry: (label, compiled_regex, value_group).
# value_group None  -> the whole match is the secret (redact all of it).
# value_group name  -> only that named group is the secret (keep the `key =` prefix).
_RAW = [
    ("AWS access key id",      r"\bAKIA[0-9A-Z]{16}\b", None),
    ("GitHub token",           r"\bgh[pousr]_[A-Za-z0-9]{36,}\b", None),
    ("GitHub fine-grained PAT", r"\bgithub_pat_[A-Za-z0-9_]{22,}\b", None),
    ("OpenAI/Anthropic key",   r"\bsk-(?:ant-|proj-|live_)?[A-Za-z0-9_-]{20,}\b", None),
    ("Google API key",         r"\bAIza[0-9A-Za-z_-]{35,}\b", None),
    ("Slack token",            r"\bxox[baprs]-[0-9A-Za-z-]{10,}\b", None),
    ("Stripe secret key",      r"\b[sr]k_live_[0-9A-Za-z]{20,}\b", None),
    ("Twilio API key",         r"\bSK[0-9a-fA-F]{32}\b", None),
    ("Private key block",      r"-----BEGIN (?:RSA |EC |DSA |OPENSSH |PGP )?PRIVATE KEY-----", None),
    ("JWT",                    r"\beyJ[A-Za-z0-9_-]{10,}\.eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\b", None),
    # Context-gated generic assignment: `password: <value>`, `api_key = "<value>"`.
    ("Generic credential",
     r"(?i)\b(?:api[_-]?key|secret(?:[_-]?key)?|access[_-]?token|auth[_-]?token|"
     r"client[_-]?secret|password|passwd|bearer)\b[\"']?\s*[:=]\s*[\"']?"
     r"(?P<val>[A-Za-z0-9_\-+/=.]{16,})",
     "val"),
]
PATTERNS = [(label, re.compile(rx), grp) for label, rx, grp in _RAW]

_PLACEHOLDER_PREFIXES = (
    "your", "example", "changeme", "change-me", "placeholder", "dummy",
    "sample", "fake", "todo", "none", "null", "redacted", "xxxx",
)


def is_excluded(path):
    parts = path.replace("\\", "/").split("/")
    if "archive" in parts:
        return True
    return bool(EXCLUDE_NAME_RE.search(os.path.basename(path)))


def is_placeholder(val):
    """A value that is already safe (env ref, redaction marker, obvious dummy)."""
    v = val.strip().strip("'\"")
    if not v:
        return True
    if v[0] in "$<%{":           # $VAR, ${VAR}, <REDACTED>, %VAR%, {{var}}
        return True
    low = v.lower()
    if "redacted" in low:
        return True
    if any(low == p or low.startswith(p) for p in _PLACEHOLDER_PREFIXES):
        return True
    if set(v) <= set("x*.-_"):   # all-masking strings: xxxxxxxx, ********
        return True
    return False


def looks_like_secret(val, generic):
    """Mixed alphanumeric gate — only enforced for the generic rule, so prose like
    `password: please-rotate-this` (all letters) doesn't get shredded, but real keys
    (mixed alnum) do. Prefix-anchored patterns are already high-confidence."""
    if is_placeholder(val):
        return False
    if not generic:
        return True
    return bool(re.search(r"[A-Za-z]", val)) and bool(re.search(r"\d", val))


def mask(val):
    v = val.strip().strip("'\"")
    return f"{v[:3]}…({len(v)} chars)" if len(v) > 4 else "…"


def scan_line(line):
    """Return (new_line, [(label, masked), ...]) — redacting every real secret."""
    found = []

    def make_repl(label, grp):
        generic = grp is not None

        def repl(m):
            val = m.group(grp) if generic else m.group(0)
            if not looks_like_secret(val, generic):
                return m.group(0)
            found.append((label, mask(val)))
            if generic:
                start, end = m.span(grp)
                return m.group(0)[: start - m.start()] + "<REDACTED>" + m.group(0)[end - m.start():]
            return "<REDACTED>"

        return repl

    new = line
    for label, rx, grp in PATTERNS:
        new = rx.sub(make_repl(label, grp), new)
    return new, found


def iter_files(memory_dir):
    for root, dirs, files in os.walk(memory_dir):
        dirs[:] = [d for d in dirs if d != "archive"]
        for fn in files:
            if not fn.endswith(".md"):
                continue
            p = os.path.join(root, fn)
            if is_excluded(p):
                continue
            yield p


def main():
    args = sys.argv[1:]
    if not args:
        sys.exit("usage: scan-secrets.py <MEMORY_DIR> [--apply] [--count]")
    memory_dir = args[0]
    apply = "--apply" in args
    count_only = "--count" in args
    if not os.path.isdir(memory_dir):
        sys.exit(f"not a directory: {memory_dir}")

    total, files_hit, report = 0, 0, []
    for p in iter_files(memory_dir):
        try:
            with open(p, encoding="utf-8") as f:
                lines = f.readlines()
        except (UnicodeDecodeError, OSError):
            continue
        file_findings, changed = [], False
        for i, line in enumerate(lines, 1):
            new, found = scan_line(line)
            if found:
                file_findings.extend((i, lbl, mk) for lbl, mk in found)
                if new != line:
                    lines[i - 1] = new
                    changed = True
        if not file_findings:
            continue
        files_hit += 1
        total += len(file_findings)
        rel = os.path.relpath(p, memory_dir)
        for lineno, lbl, mk in file_findings:
            report.append(f"   ! {rel}:{lineno}  {lbl} — {mk}")
        if apply and changed:
            tmp = p + ".tmp"
            with open(tmp, "w", encoding="utf-8") as f:
                f.writelines(lines)
            os.replace(tmp, p)

    if count_only:
        print(total)
        return

    mode = "APPLY (redacting)" if apply else "DRY-RUN (no writes)"
    print(f"== scan-secrets: {mode} — {memory_dir} ==")
    print(f"[secrets] findings: {total} across {files_hit} file(s)")
    for line in report:
        print(line)
    if total and not apply:
        print("DRY-RUN only — re-run with --apply to replace each value with <REDACTED>.")
    if total and apply:
        print("Redacted in place. Review the diff and rotate any real key that was committed earlier.")
    verb = "secrets_redacted" if apply else "secrets_found"
    print(f"SUMMARY {verb}={total} files={files_hit}")


if __name__ == "__main__":
    main()
