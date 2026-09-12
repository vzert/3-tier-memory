#!/usr/bin/env bash
# Todo .py de bin/ fija UTF-8 en stdout Y en stderr.
#
# Por que el criterio es "todos" y no "los que imprimen no-ASCII": la version anterior de esta
# prueba intentaba decidir quien imprime no-ASCII leyendo el fuente, y eso NO se puede decidir
# leyendo el fuente. Solo veia literales en la misma linea que un `print(`; no veia una variable,
# un f-string armado antes, una RUTA que el usuario elige, ni el mensaje de una excepcion. Un
# adversario externo lo rompio el 2026-09-12 con un directorio llamado `memoria—x`: `triage-scan.py`
# —que esa misma prueba daba por cubierto— escupia `no existe /…/memoria—x/_pendientes.md`,
# porque la guarda de entonces reconfiguraba solo stdout.
#
# Exigir la guarda en todos no necesita adivinar nada y no puede quedarse corto.
#
# Los dos modos de fallo, que son distintos:
#   stdout con una pagina OEM (cp437) -> UnicodeEncodeError, el proceso MUERE.
#   stderr con la misma              -> degrada a la forma escapada `—`. Menos grave, igual
#                                        de falso, y mas dificil de ver porque nada peta.
#
# sella-huellas: no (solo lee ficheros y corre scripts sobre temporales propios)
set -u
BIN="$(cd "$(dirname "$0")" && pwd)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
FALLOS=0
ok()  { printf '  ok   %s\n' "$1"; }
bad() { printf '  FAIL %s\n' "$1"; FALLOS=1; }

falta() {   # $1 = directorio; imprime los .py cuyos flujos NO acaban en UTF-8
  # Se comprueba POR COMPORTAMIENTO, no leyendo el fuente. La primera version de esta funcion
  # buscaba los identificadores de la guarda en el texto, y bastaba con que el token `_flujo`
  # apareciera para darla por buena: cambiando `(sys.stdout, sys.stderr)` por `(sys.stdout,)` la
  # suite seguia diciendo TODO VERDE con stderr sin guardar. Lo cazo un adversario el 2026-09-12
  # mutando `build-recall-index.py`. Una comprobacion de texto no sabe lo que hace el codigo.
  #
  # Ahora cada fichero se IMPORTA en un proceso propio con PYTHONIOENCODING=cp437 —lo que Windows
  # hace por su cuenta— y se lee la codificacion REAL de los dos flujos despues. Los 14 protegen su
  # `main()` con `if __name__ == "__main__"`, asi que importar ejecuta la guarda y nada mas.
  python3 - "$1" <<'PY'
import glob, os, subprocess, sys

malos = []
for p in sorted(glob.glob(os.path.join(sys.argv[1], "*.py"))):
    codigo = (
        "import importlib.util, sys\n"
        "spec = importlib.util.spec_from_file_location('sut', sys.argv[1])\n"
        "m = importlib.util.module_from_spec(spec)\n"
        "spec.loader.exec_module(m)\n"
        "sys.__stdout__.write('%s %s' % (sys.stdout.encoding, sys.stderr.encoding))\n"
    )
    env = dict(os.environ, PYTHONIOENCODING="cp437")
    r = subprocess.run([sys.executable, "-c", codigo, p],
                       capture_output=True, text=True, env=env, timeout=60)
    campos = r.stdout.strip().split()
    norm = [c.lower().replace("-", "").replace("_", "") for c in campos]
    if len(norm) != 2 or norm != ["utf8", "utf8"]:
        detalle = " ".join(campos) if campos else (r.stderr.strip().splitlines() or ["sin salida"])[-1][:50]
        malos.append(f"{os.path.basename(p)}({detalle})")
print(" ".join(malos))
PY
}

echo "1. los .py de bin/ fijan UTF-8 en los DOS flujos"
SIN=$(falta "$BIN")
[ -z "$SIN" ] && ok "ninguno se queda fuera" || bad "sin guarda completa: $SIN"

echo "2. CONTROL: el detector caza uno al que le falta stderr"
printf '#!/usr/bin/env python3\nimport sys\nif hasattr(sys.stdout, "reconfigure"):\n    sys.stdout.reconfigure(encoding="utf-8")\n' > "$TMP/solo-stdout.py"
CAZ=$(falta "$TMP")
case "$CAZ" in
  solo-stdout.py*) ok "lo caza, y dice por que: $CAZ" ;;
  "")              bad "NO lo caza: la comprobacion es vacua" ;;
  *)               bad "caza otra cosa: $CAZ" ;;
esac

echo "3. en vivo: una RUTA no-ASCII por stderr sale entera con cp437"
# El caso exacto del adversario. Es una ruta, no un literal del fuente: la prueba vieja no podia
# verlo ni en principio.
D="$TMP/memoria—x"; mkdir -p "$D"
ESCAPADO='\u2014'   # comillas simples: la SECUENCIA barra-u-2014, no el caracter
OUT=$(PYTHONIOENCODING=cp437 python3 "$BIN/triage-scan.py" --memory-dir "$D" 2>&1)
if   printf '%s' "$OUT" | grep -qF "memoria${ESCAPADO}x"; then bad "stderr sigue escapando: $OUT"
elif printf '%s' "$OUT" | grep -qF 'memoria—x';        then ok "stderr conserva el guion largo"
else bad "salida inesperada: $OUT"; fi

echo "4. en vivo: stdout con cp437 no truena"
M="$TMP/m"; mkdir -p "$M/pendientes"
printf '# Pendientes\n\n## Alta prioridad\n\n- [ ] algo — _creado: 2026-01-01_ — _id: p-1111111111_\n\n## Media prioridad\n\n## Baja prioridad\n' > "$M/_pendientes.md"
OUT=$(PYTHONIOENCODING=cp437 python3 "$BIN/expire-pendientes.py" --memory-dir "$M" --revertir p-1111111111 2>&1)
case "$OUT" in *UnicodeEncodeError*) bad "truena: $OUT" ;; *) ok "sobrevive y sale entero" ;; esac

echo "5. CONTROL: sin guarda, cp437 SI rompe los dos flujos"
E1=$(PYTHONIOENCODING=cp437 python3 -c "print('x — y')" 2>&1)
E2=$(PYTHONIOENCODING=cp437 python3 -c "import sys; print('x — y', file=sys.stderr)" 2>&1)
case "$E1" in *UnicodeEncodeError*) ok "stdout sin guarda muere" ;; *) bad "stdout no murio: los casos 3 y 4 no miden nada" ;; esac
if printf '%s' "$E2" | grep -qF "$ESCAPADO"; then ok "stderr sin guarda escapa"
else bad "stderr no escapo: el caso 3 no mide nada ($E2)"; fi

echo
[ "$FALLOS" -eq 0 ] && echo "TODO VERDE" || echo "HAY FALLOS"
exit "$FALLOS"
