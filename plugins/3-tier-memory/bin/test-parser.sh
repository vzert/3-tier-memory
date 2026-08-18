#!/bin/bash
# Regresiones del parser de _pendientes.md (bloque python de session-start.sh).
#
# Cada caso aqui es un fallo que YA OCURRIO en produccion o que una verificacion
# adversarial encontro antes de publicarse. Todos comparten la misma forma: el hook
# se queda callado y el usuario no tiene como notarlo. Por eso el criterio no es
# "clasifica bien" sino "nada desaparece sin decirlo".
#
# Uso: bash bin/test-parser.sh    (sin dependencias; sale != 0 si algo falla)

set -u
HOOK="$(dirname "$0")/session-start.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PARSER="$TMP/parser.py"

python3 - "$HOOK" "$PARSER" <<'PY'
import sys
lines = open(sys.argv[1], encoding="utf-8").read().split("\n")
a = next(i for i, l in enumerate(lines) if "<<'PYEOF'" in l)
b = next(i for i, l in enumerate(lines) if l.strip() == "PYEOF" and i > a)
open(sys.argv[2], "w", encoding="utf-8").write("\n".join(lines[a + 1:b]))
PY

PASS=0; FAIL=0
check() { # nombre, archivo, patron-que-debe-aparecer
  local out; out=$(PENDIENTES_FILE="$2" python3 "$PARSER" 2>&1)
  if echo "$out" | grep -q "$3"; then
    PASS=$((PASS + 1)); echo "  ok   $1"
  else
    FAIL=$((FAIL + 1)); echo "  FAIL $1"; echo "$out" | sed 's/^/         /'
  fi
}

# Seccion fuera del esquema de prioridad. Real: unifi-expert (## Abiertos) inyecto
# 0 de 15 pendientes durante meses; el header imprimia un total falso.
printf '# P\n\n## Abiertos\n- [ ] item bajo seccion no canonica\n' > "$TMP/1.md"
check "seccion desconocida -> OTROS, no descartada" "$TMP/1.md" 'item bajo seccion no canonica'

# Colision por prefijo al clasificar secciones cerradas: "## Scope expansion tasks"
# empieza con "## scope" y se tragaba entera, con el auto-chequeo callado.
printf '# P\n\n## Scope expansion tasks\n- [ ] tarea viva\n' > "$TMP/2.md"
check "seccion viva con prefijo de seccion cerrada" "$TMP/2.md" 'tarea viva'

# "---" a media pagina activaba la deteccion de frontmatter y se comia el archivo entero.
printf '# P\n\n---\n\n## Alta prioridad\n- [ ] item tras regla horizontal\n' > "$TMP/3.md"
check "regla horizontal no es frontmatter" "$TMP/3.md" 'item tras regla horizontal'

# El frontmatter YAML de verdad si debe saltarse.
printf -- '---\ntype: index\n---\n# P\n\n## Alta prioridad\n- [ ] item real\n' > "$TMP/4.md"
check "frontmatter YAML real se salta" "$TMP/4.md" 'item real'

# Item en el preambulo, antes del primer "## ". Real: sms-masivos/landings.
printf '# P\n\n- [ ] item en el preambulo\n\n## Alta prioridad\n- [ ] otro\n' > "$TMP/5.md"
check "item antes de cualquier seccion" "$TMP/5.md" 'item en el preambulo'

# Total 0 clasificados pero el archivo SI tenia items: el caso donde callarse es el bug.
printf '# P\n\n## Completados\n- [ ] viejo sin cerrar\n' > "$TMP/6.md"
check "supresion total avisa igual" "$TMP/6.md" 'ESTRUCTURA'

# Item indentado: se clasifica con strip() y se contaba a columna cero -> desajuste falso.
printf '# P\n\n## Alta prioridad\n  - [ ] item indentado\n' > "$TMP/7.md"
out=$(PENDIENTES_FILE="$TMP/7.md" python3 "$PARSER" 2>&1)
if echo "$out" | grep -q 'quedaron fuera del conteo'; then
  FAIL=$((FAIL + 1)); echo "  FAIL item indentado no debe dar desajuste falso"
else
  PASS=$((PASS + 1)); echo "  ok   item indentado no da desajuste falso"
fi

# --- detector de hook local duplicado -----------------------------------------
# Vive en el mismo hook. Los dos casos de aqui los encontro una verificacion
# adversarial: la deteccion pasaba por alto formas de escritura perfectamente
# normales, o sea fallaba en silencio igual que el parser.
DUP="$TMP/dupcheck.py"
python3 - "$HOOK" "$DUP" <<'PY'
import sys
lines = open(sys.argv[1], encoding="utf-8").read().split("\n")
a = next(i for i, l in enumerate(lines) if "<<'DUPEOF'" in l)
b = next(i for i, l in enumerate(lines) if l.strip() == "DUPEOF" and i > a)
open(sys.argv[2], "w", encoding="utf-8").write("\n".join(lines[a + 1:b]))
PY

mkproj() { # dir, comando-del-hook
  mkdir -p "$1/.claude/hooks" "$1/memory"
  printf '#!/bin/bash\nP=$(grep -E "^- \\[ \\]" "$CLAUDE_PROJECT_DIR/memory/_pendientes.md")\necho "$P"\n' > "$1/.claude/hooks/session-start.sh"
  printf '# P\n\n## Alta prioridad\n- [ ] x\n' > "$1/memory/_pendientes.md"
  printf '{"hooks":{"SessionStart":[{"matcher":"","hooks":[{"type":"command","command":"%s"}]}]}}\n' "$2" > "$1/.claude/settings.local.json"
}
dupcheck() { CLAUDE_PROJECT_DIR="$1" MEMORY_DIR="$1/memory" python3 "$DUP" 2>&1; }
expect() { # nombre, dir, si|no
  local out; out=$(dupcheck "$2")
  local got=no; [ -n "$out" ] && got=si
  if [ "$got" = "$3" ]; then PASS=$((PASS + 1)); echo "  ok   $1"
  else FAIL=$((FAIL + 1)); echo "  FAIL $1 (esperado=$3 obtenido=$got)"; fi
}

# Forma con llaves: se expandia solo $CLAUDE_PROJECT_DIR, no ${CLAUDE_PROJECT_DIR}.
mkproj "$TMP/d1" 'bash ${CLAUDE_PROJECT_DIR}/.claude/hooks/session-start.sh'
expect "detecta \${CLAUDE_PROJECT_DIR} con llaves" "$TMP/d1" si

# Un comando con dos scripts: se miraba solo el primero, asi que un huerfano lo tapaba.
mkproj "$TMP/d2" 'bash $CLAUDE_PROJECT_DIR/.claude/hooks/no-existe.sh && bash $CLAUDE_PROJECT_DIR/.claude/hooks/session-start.sh'
expect "huerfano primero no tapa al script real" "$TMP/d2" si

# El propio hook del plugin no es duplicado de si mismo.
mkproj "$TMP/d3" 'bash "${CLAUDE_PLUGIN_ROOT}/bin/session-start.sh"'
expect "no se autodenuncia (CLAUDE_PLUGIN_ROOT)" "$TMP/d3" no

# Entrada huerfana sola: la reporta /migrate, no es duplicacion de contexto.
mkproj "$TMP/d4" 'bash $CLAUDE_PROJECT_DIR/.claude/hooks/no-existe.sh'
rm -f "$TMP/d4/.claude/hooks/session-start.sh"
expect "entrada huerfana no cuenta como duplicado" "$TMP/d4" no

echo "  ---- $PASS ok, $FAIL fallo(s)"
[ "$FAIL" -eq 0 ]
