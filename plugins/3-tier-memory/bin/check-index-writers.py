#!/usr/bin/env python3
"""Exige que TODO script de bin/ declare si re-sella la huella de los indices.

POR QUE ASI, Y NO ADIVINANDO. 2.13.3 arreglo los dos escritores que su autor encontro y dejo fuera
enrich-memory (regla 114: revisar los llamantes no prueba que sean todos). El adversario de la
ronda 6 marco la primera enumeracion como instrumento roto. La segunda tampoco veia
normalize-pendientes, que no llama a atomic_write sino que hace su propio tmp + replace a traves
de `(jc.replace_with_retry if jc is not None else os.replace)(tmp, path)` — una forma que ninguna
regex razonable iba a cazar.

Cuatro intentos de detectar la escritura por analisis de texto, cuatro veces corto. El detector
deja de adivinar: cada script que NOMBRE un indice protegido debe llevar una linea

    # sella-huellas: si        <- escribe indices y llama a guardar_huellas()
    # sella-huellas: no (razon)  <- no escribe indices, o no hace falta; la razon queda escrita

Un falso positivo cuesta una linea de comentario, no un agujero. Y un script NUEVO que escriba un
indice y olvide el marcador falla esta prueba, que es la propiedad que 2.13.3 no tenia.

Cuando el marcador dice `si`, ademas se comprueba que exista de verdad la llamada a
guardar_huellas() fuera de comentarios y docstrings — un marcador sin consumidor seria justo el
tipo de no-evidencia que este repo lleva seis rondas persiguiendo.

Uso:  check-index-writers.py [BIN_DIR]
Salida: una linea por script sin declarar + `SUMMARY scanned=N undeclared=N mislabeled=N`.
"""
import os
import re
import sys

# UTF-8 en stdout Y EN STDERR. La guarda anterior solo cubria stdout, asi que un mensaje de error
# con un caracter no-ASCII —el nombre de un directorio, por ejemplo— seguia saliendo mutilado:
# `no existe /…/memoria\u2014x/_pendientes.md`. Por stdout con una pagina OEM el proceso MUERE;
# por stderr DEGRADA a la forma escapada. Menos grave, igual de falso. Lo encontro un adversario
# externo el 2026-09-12 y se reprodujo aqui.
#
# Se pone en TODOS los .py de bin/, no solo en los que "parecen" imprimir no-ASCII: eso ultimo no
# se puede decidir leyendo el fuente —una variable, un f-string armado antes, una ruta, el mensaje
# de una excepcion— y el detector que lo intentaba fue justo lo que dejo pasar este hueco.
for _flujo in (sys.stdout, sys.stderr):
    if hasattr(_flujo, "reconfigure"):
        _flujo.reconfigure(encoding="utf-8")

MARCA = re.compile(r'^\s*#\s*sella-huellas:\s*(si|no)\b(.*)$', re.M | re.I)
SELLA = re.compile(r'guardar_huellas\s*\(')
EXENTOS = {"journal-compact", "check-index-writers"}


def sin_comentarios(src, py):
    if py:
        src = re.sub(r'"""[\s\S]*?"""', '', src)
        src = re.sub(r"'''[\s\S]*?'''", '', src)
    return re.sub(r'(?m)#[^\n]*', '', src)


def main():
    bin_dir = sys.argv[1] if len(sys.argv) > 1 else os.path.dirname(os.path.abspath(__file__))
    sin_declarar, mal = [], []
    scanned = 0
    for n in sorted(os.listdir(bin_dir)):
        if not (n.endswith(".py") or n.endswith(".sh")):
            continue
        base = n.rsplit(".", 1)[0]
        if base in EXENTOS or base.startswith("test-"):
            continue
        try:
            src = open(os.path.join(bin_dir, n), encoding="utf-8", errors="replace").read()
        except OSError:
            continue
        # SIN filtro por "nombra un indice". Esa criba era el agujero: `scan-secrets.py` recorre
        # todo memory/ con os.walk y reescribe cualquier .md —incluido `_pendientes.md`— sin
        # nombrarlo nunca como literal, asi que no se escaneaba, no estaba en `si` ni en `no`, y
        # era invisible justo al detector instalado para "dejar de adivinar". Lo encontro el
        # adversario local en la ronda 7. Ahora declara TODO script de bin/: la unica version que
        # no puede perderse nada es la que no decide a quien mirar.
        scanned += 1
        m = MARCA.search(src)
        if not m:
            sin_declarar.append(base)
            continue
        if m.group(1).lower() == "si" and not SELLA.search(sin_comentarios(src, n.endswith(".py"))):
            mal.append(base)
    for f in sin_declarar:
        print(f"  SIN DECLARAR {f}: nombra un indice protegido y no dice si re-sella. "
              f"Anade `# sella-huellas: si` o `# sella-huellas: no (razon)`.")
    for f in mal:
        print(f"  MARCADOR FALSO {f}: dice `sella-huellas: si` pero no llama a guardar_huellas().")
    print(f"SUMMARY scanned={scanned} undeclared={len(sin_declarar)} mislabeled={len(mal)}")
    return 1 if (sin_declarar or mal) else 0


if __name__ == "__main__":
    sys.exit(main())
