#!/usr/bin/env bash
# Todo script de bin/ que IMPRIMA caracteres no-ASCII debe fijar UTF-8 en su propio stdout.
#
# Por que: en Windows python codifica stdout con la pagina de codigos local cuando va a una
# tuberia. Con cp1252 los guiones largos se degradan; con cp437 —la OEM clasica de consola— el
# proceso MUERE con UnicodeEncodeError. `expire-pendientes.py` y `triage-scan.py` llevaban meses
# asi mientras los otros cinco si tenian la guarda: nadie lo vio porque nada lo comprobaba.
#
# La guarda no puede vivir solo en el `export PYTHONUTF8` de los .sh: estos scripts se invocan
# TAMBIEN directamente desde las plantillas de los comandos (`python3 "$JBIN/triage-scan.py" ...`),
# donde no hay ningun .sh de por medio. Una garantia que depende de quien te invoque no lo es.
#
# sella-huellas: no (solo lee ficheros)
set -u
BIN="$(cd "$(dirname "$0")" && pwd)"
FALLOS=0
ok()  { printf '  ok   %s\n' "$1"; }
bad() { printf '  FAIL %s\n' "$1"; FALLOS=1; }

echo "1. todo .py que imprime no-ASCII fija UTF-8 en su stdout"
SIN=$(python3 - "$BIN" <<'PY'
import glob, os, sys
faltan = []
for p in sorted(glob.glob(os.path.join(sys.argv[1], "*.py"))):
    src = open(p, encoding="utf-8").read()
    imprime = any(
        ("print(" in l or "stdout" in l) and any(ord(c) > 127 for c in l)
        for l in src.split("\n")
    )
    if imprime and "reconfigure" not in src:
        faltan.append(os.path.basename(p))
print(" ".join(faltan))
PY
)
if [ -z "$SIN" ]; then ok "ninguno sin guarda"; else bad "sin guarda: $SIN"; fi

echo "2. CONTROL: el detector SI encuentra uno cuando falta"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
printf '#!/usr/bin/env python3\nprint("hola \xe2\x80\x94 adios")\n' > "$TMP/falso.py"
CAZADO=$(python3 - "$TMP" <<'PY'
import glob, os, sys
for p in sorted(glob.glob(os.path.join(sys.argv[1], "*.py"))):
    src = open(p, encoding="utf-8").read()
    if any(("print(" in l or "stdout" in l) and any(ord(c) > 127 for c in l) for l in src.split("\n")) \
       and "reconfigure" not in src:
        print(os.path.basename(p))
PY
)
[ "$CAZADO" = "falso.py" ] && ok "lo caza" || bad "el detector no discrimina (salio '$CAZADO')"

echo "3. con cp437 el texto sale entero, no truena"
for s in expire-pendientes triage-scan; do
  M="$TMP/m"; mkdir -p "$M/pendientes"
  printf '# Pendientes\n\n## Alta prioridad\n\n- [ ] algo \xe2\x80\x94 _creado: 2026-01-01_ \xe2\x80\x94 _id: p-1111111111_\n\n## Media prioridad\n\n## Baja prioridad\n' > "$M/_pendientes.md"
  case "$s" in
    expire-pendientes) OUT=$(PYTHONIOENCODING=cp437 python3 "$BIN/$s.py" --memory-dir "$M" --revertir p-1111111111 2>&1) ;;
    *)                 OUT=$(PYTHONIOENCODING=cp437 python3 "$BIN/$s.py" --memory-dir "$M" --limit 3 2>&1) ;;
  esac
  case "$OUT" in *UnicodeEncodeError*) bad "$s.py truena con cp437" ;; *) ok "$s.py sobrevive a cp437" ;; esac
done

echo "4. CONTROL: el mismo texto SIN guarda si truena con cp437"
CTL=$(PYTHONIOENCODING=cp437 python3 -c "print('x \xe2\x80\x94 y')" 2>&1)
case "$CTL" in *UnicodeEncodeError*) ok "sin guarda truena, o sea que el caso 3 mide algo" ;;
               *) bad "el control no truena: cp437 no esta haciendo lo que se cree" ;; esac

echo
[ "$FALLOS" -eq 0 ] && echo "TODO VERDE" || echo "HAY FALLOS"
exit "$FALLOS"
