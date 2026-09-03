#!/bin/bash
# Regresiones de la guardia estricta del journal (bin/journal-guard.sh, PreToolUse, v2.12.0).
#
# El hook recibe por stdin el JSON de PreToolUse y debe:
#   - no decir NADA (stdout vacio, stderr vacio, exit 0) cuando la guardia esta apagada o el
#     archivo no es uno de los que pertenecen al compactador;
#   - imprimir un JSON con permissionDecision=deny (y solo eso) cuando journal_strict=1 y el
#     archivo es memory/_*.md o memory/pendientes/YYYY-MM.md.
# Un hook que muere con traceback se ve igual que "no bloquea": por eso stderr va aparte y se
# exige salida limpia antes de mirar el patron (mismo criterio que test-parser.sh).
#
# Uso: bash bin/test-journal-guard.sh    (sin dependencias; sale != 0 si algo falla)
# Alcance: prueba el HOOK, no que Claude Code honre el deny. Eso se mide con claude -p y esta
# documentado en el README (seccion del journal) y en el CHANGELOG 2.12.0.

set -u
HOOK="$(cd "$(dirname "$0")" && pwd)/journal-guard.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
P="$TMP/proj"; mkdir -p "$P/memory/pendientes" "$P/memory/sessions" "$P/memory/learnings" "$P/src"
printf -- '---\ntype: index\n---\n# Pendientes\n\n## Alta prioridad\n' > "$P/memory/_pendientes.md"
PASS=0; FAIL=0; ERR="$TMP/stderr"

call() { # tool, file_path -> stdout (stderr aparte); falla si stderr no vacio o exit != 0
  : > "$ERR"
  OUT=$(printf '{"session_id":"t","cwd":"%s","hook_event_name":"PreToolUse","tool_name":"%s","tool_input":{"file_path":"%s","content":"x"}}' "$P" "$1" "$2" \
        | CLAUDE_PROJECT_DIR="$P" bash "$HOOK" 2>"$ERR"); RC=$?
  [ "$RC" -eq 0 ] && [ ! -s "$ERR" ]
}
fail() { FAIL=$((FAIL + 1)); echo "  FAIL $1"; shift; [ -n "${1:-}" ] && echo "$1" | sed 's/^/         /'; }
expect_deny() { # nombre, tool, path
  if ! call "$2" "$3"; then fail "$1 (el hook murio o escribio en stderr)" "$(cat "$ERR")"; return; fi
  if echo "$OUT" | grep -q '"permissionDecision": *"deny"' && echo "$OUT" | grep -q 'journal-emit'; then PASS=$((PASS + 1)); else fail "$1: esperaba deny, salio: '$OUT'"; fi
}
expect_pass() { # nombre, tool, path
  if ! call "$2" "$3"; then fail "$1 (el hook murio o escribio en stderr)" "$(cat "$ERR")"; return; fi
  if [ -z "$OUT" ]; then PASS=$((PASS + 1)); else fail "$1: esperaba silencio, salio: '$OUT'"; fi
}

echo "guardia apagada (sin .memory-config):"
expect_pass "sin config: _pendientes.md pasa" Edit "$P/memory/_pendientes.md"
expect_pass "sin config: mensual pasa" Write "$P/memory/pendientes/2026-09.md"

echo "journal_strict=0:"
printf 'journal_strict=0\n' > "$P/memory/.memory-config"
expect_pass "strict=0: _pendientes.md pasa" Edit "$P/memory/_pendientes.md"

echo "journal_strict=1:"
printf '# config de memoria\njournal_strict = 1\n' > "$P/memory/.memory-config"
expect_deny "Edit _pendientes.md" Edit "$P/memory/_pendientes.md"
expect_deny "Write _session-index.md (aun sin existir)" Write "$P/memory/_session-index.md"
expect_deny "MultiEdit _learnings.md" MultiEdit "$P/memory/_learnings.md"
expect_deny "Write mensual pendientes/2026-09.md" Write "$P/memory/pendientes/2026-09.md"
expect_deny "ruta relativa al cwd" Edit "memory/_plans-index.md"
expect_deny "ruta con .." Edit "$P/src/../memory/_research-index.md"
expect_pass "MEMORY.md (Tier 1) pasa" Edit "$P/memory/MEMORY.md"
expect_pass "sessions/ (Tier 3) pasa" Write "$P/memory/sessions/2026-09-02-x.md"
expect_pass "learnings/<topic>.md (Tier 3) pasa" Edit "$P/memory/learnings/topic.md"
expect_pass "pendientes/ que no es mensual pasa" Write "$P/memory/pendientes/notas.md"
expect_pass "_*.md fuera de memory/ pasa" Write "$P/src/_config.md"
expect_pass "archivo cualquiera pasa" Write "$P/src/main.py"
expect_pass "otra herramienta (Read) pasa" Read "$P/memory/_pendientes.md"
expect_pass "Bash no se toca aunque mencione el indice" Bash "$P/memory/_pendientes.md"

echo "sin sistema de memoria:"
Q="$TMP/noproj"; mkdir -p "$Q" "$TMP/fakehome"
: > "$ERR"; OUT=$(printf '{"cwd":"%s","tool_name":"Edit","tool_input":{"file_path":"%s/memory/_pendientes.md"}}' "$Q" "$Q" | CLAUDE_PROJECT_DIR="$Q" HOME="$TMP/fakehome" bash "$HOOK" 2>"$ERR"); RC=$?
if [ "$RC" -eq 0 ] && [ ! -s "$ERR" ] && [ -z "$OUT" ]; then PASS=$((PASS + 1)); else fail "sin memory/: debe callar" "$OUT $(cat "$ERR")"; fi

echo "entrada rota:"
printf 'journal_strict=1\n' > "$P/memory/.memory-config"
: > "$ERR"; OUT=$(printf 'esto no es json' | CLAUDE_PROJECT_DIR="$P" bash "$HOOK" 2>"$ERR"); RC=$?
if [ "$RC" -eq 0 ] && [ ! -s "$ERR" ] && [ -z "$OUT" ]; then PASS=$((PASS + 1)); else fail "json roto: debe callar (fail-open)" "$OUT $(cat "$ERR")"; fi

echo "RESULT: pass=$PASS fail=$FAIL"
[ "$FAIL" -eq 0 ]
