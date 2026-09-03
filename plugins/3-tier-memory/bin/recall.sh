#!/bin/bash
# 3-tier-memory plugin: UserPromptSubmit hook — relevance recall.
# Surfaces the memory units most relevant to the user's prompt, scored by
# lexical overlap (BM25-lite) × recency decay × importance. Silent when nothing
# is relevant (avoids polluting context with noise).

source "$(dirname "$0")/resolve-project-dir.sh"

# Detect memory dir (Model B first, then Model A fallback) — same logic as session-start
if [ -f "$CLAUDE_PROJECT_DIR/memory/_pendientes.md" ]; then
  MEMORY_DIR="$CLAUDE_PROJECT_DIR/memory"
elif [ -d "$HOME/.claude/projects" ]; then
  ENCODED=$(echo "$CLAUDE_PROJECT_DIR" | sed 's/[^A-Za-z0-9]/-/g')
  AUTO_DIR="$HOME/.claude/projects/$ENCODED/memory"
  [ -f "$AUTO_DIR/_pendientes.md" ] && MEMORY_DIR="$AUTO_DIR"
fi
[ -z "$MEMORY_DIR" ] && exit 0

# Journal (v2.12.0): un evento que nadie compacto (el agente que lo emitio se cerro antes de
# su checkpoint) se aplica en el siguiente prompt de cualquier sesion. Fast path: un listado
# de directorio; solo se lanza python3 si pending/ tiene algo.
JOURNAL_PENDING="$MEMORY_DIR/.journal/pending"
if [ -f "$CLAUDE_PLUGIN_ROOT/bin/journal-compact.py" ] && [ -d "$JOURNAL_PENDING" ] \
   && [ -n "$(ls -A "$JOURNAL_PENDING" 2>/dev/null)" ]; then
  python3 "$CLAUDE_PLUGIN_ROOT/bin/journal-compact.py" --memory-dir "$MEMORY_DIR" --budget 1 --quiet >/dev/null 2>&1
fi

# Derived recall index lives alongside other per-machine state (like
# .backfill-progress.json), NOT in memory/ — so it never gets committed.
ENCODED=$(echo "$CLAUDE_PROJECT_DIR" | sed 's/[^A-Za-z0-9]/-/g')
STATE_DIR="$HOME/.claude/projects/$ENCODED"
mkdir -p "$STATE_DIR" 2>/dev/null
INDEX="$STATE_DIR/.recall-index.jsonl"
BUILDER="$CLAUDE_PLUGIN_ROOT/bin/build-recall-index.py"

# Rebuild if missing or stale (any memory file newer than the index)
NEEDS_BUILD=false
if [ ! -f "$INDEX" ]; then
  NEEDS_BUILD=true
elif [ -n "$(find "$MEMORY_DIR" -name '*.md' -not -path '*/archive/*' -not -name '*.bak*' -not -name '*.archived.md' -not -name 'archived-*.md' -newer "$INDEX" -print -quit 2>/dev/null)" ]; then
  NEEDS_BUILD=true
fi
if [ "$NEEDS_BUILD" = true ] && [ -f "$BUILDER" ]; then
  python3 "$BUILDER" "$MEMORY_DIR" "$INDEX" >/dev/null 2>&1
fi
[ -f "$INDEX" ] || exit 0

PROMPT=$(echo "$_HOOK_INPUT" | python3 -c "import json,sys;print(json.load(sys.stdin).get('prompt',''))" 2>/dev/null)
[ -z "$PROMPT" ] && exit 0

RECALL_INDEX="$INDEX" RECALL_PROMPT="$PROMPT" python3 <<'PYEOF' 2>/dev/null
import json, os, re, math
from datetime import date

index_path = os.environ.get("RECALL_INDEX", "")
prompt = os.environ.get("RECALL_PROMPT", "")

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
WORD_RE = re.compile(r"[a-záéíóúüñ0-9]{2,}", re.IGNORECASE)

def tokenize(text):
    out, seen = [], set()
    for w in WORD_RE.findall(text.lower()):
        if w in seen or w in STOPWORDS:
            continue
        if len(w) < 3 and not any(c.isdigit() for c in w):
            continue
        seen.add(w)
        out.append(w)
    return out

q_terms = set(tokenize(prompt))
if not q_terms:
    raise SystemExit(0)

units = []
try:
    with open(index_path, encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if line:
                units.append(json.loads(line))
except Exception:
    raise SystemExit(0)
if not units:
    raise SystemExit(0)

N = len(units)
# document frequency for IDF (rare terms in the corpus carry more signal)
df = {}
for u in units:
    for kw in set(u.get("keywords", [])):
        df[kw] = df.get(kw, 0) + 1

def idf(term):
    n = df.get(term, 0)
    if n == 0:
        return 0.0
    return math.log(1 + (N - n + 0.5) / (n + 0.5))

HALFLIFE = {"session": 30.0, "pendiente": 60.0, "plan": 180.0,
            "research": 180.0, "learning": 3650.0}
today = date.today()

def recency(u):
    f = u.get("fecha", "")
    m = re.match(r"(\d{4})-(\d{2})-(\d{2})", f or "")
    if not m:
        return 0.85  # unknown date → mild neutral weight
    try:
        d = date(int(m.group(1)), int(m.group(2)), int(m.group(3)))
    except ValueError:
        return 0.85
    days = max(0, (today - d).days)
    hl = HALFLIFE.get(u.get("tipo"), 180.0)
    return 0.5 ** (days / hl)

scored = []
for u in units:
    kws = set(u.get("keywords", []))
    matched = q_terms & kws
    if not matched:
        continue
    relevance = sum(idf(t) for t in matched)
    if relevance <= 0:
        continue
    imp = u.get("importance", 5) or 5
    score = relevance * recency(u) * (imp / 5.0)
    scored.append((score, relevance, len(matched), u))

if not scored:
    raise SystemExit(0)

# Threshold: require meaningful lexical signal (≥2 matched terms OR one rare term)
def passes(item):
    _, relevance, nmatch, _ = item
    return nmatch >= 2 or relevance >= 1.6

scored = [s for s in scored if passes(s)]
if not scored:
    raise SystemExit(0)

scored.sort(key=lambda x: x[0], reverse=True)
top = scored[:4]

LABEL = {"learning": "regla", "session": "sesión", "pendiente": "pendiente",
         "plan": "plan", "research": "research"}
print("MEMORIA RELEVANTE A TU PETICIÓN (del sistema 3-tier; ábrela si aplica, ignórala si no):")
for score, relevance, nmatch, u in top:
    tag = LABEL.get(u.get("tipo"), u.get("tipo"))
    path = u.get("path", "")
    print(f"  - [{tag}] {u.get('texto','')}" + (f"  ({path})" if path else ""))
PYEOF

exit 0
