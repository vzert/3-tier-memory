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

echo "  ---- $PASS ok, $FAIL fallo(s)"
[ "$FAIL" -eq 0 ]
