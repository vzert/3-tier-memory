#!/bin/bash
# sella-huellas: no (prueba: escribe solo en un mktemp, nada en memory/)
# Banco de regresiones de bin/match-session-file.py — el dedup de /backfill-3t Step 1.
#
# QUE SE PRUEBA. El matcher decide si un .jsonl YA tiene ficha en memory/sessions/. Si dice que
# si cuando no, la sesion se pierde en silencio; si dice que no cuando si, se duplica. Los dos
# fallos son invisibles leyendo el codigo y visibles solo aqui.
#
# LOS CINCO CASOS ROJOS son defectos que este script TUVO, medidos el 2026-09-12 contra los 22
# JSONL reales de este proyecto, no imaginados:
#   R1  fecha UTC cruda: los ts del JSONL son UTC y la fecha de la ficha es local, asi que una
#       sesion de las 21:36 de CDMX quedaba un dia corrida y su ficha "no existia" -> duplicado.
#   R2  idioma `python3 - <<'PY'` con la ruta en variable: es COMO SE ESCRIBE aqui la mayoria de
#       las fichas, y no lleva ningun `>` delante -> la escritura se leia como lectura.
#   R3  leer no es escribir: `cat ficha.md` y `cat > ficha.md` mencionan la misma ruta.
#   R4  `cp ficha.md /tmp/...`: el ORIGEN de un cp no se escribe, se lee.
#   R5  modificar una ficha creada por OTRA sesion (un /enrich-3t) no es tener ficha propia.
#
# Cada uno tiene ademas su MUTACION: se corre el matcher con el defecto reinyectado y el banco
# TIENE que ponerse rojo. Un banco que solo pasa en verde no prueba que discrimine — esa leccion
# ya se pago con el contador de 2.15.2.
#
# Uso:  bash bin/test-backfill-dedup.sh
#       MATCHER_PY=/ruta/a/copia.py bash bin/test-backfill-dedup.sh   <- correrlo contra otra copia
# Sale != 0 si algo falla.

set -u
DIR="$(cd "$(dirname "$0")" && pwd)"
MATCHER_PY="${MATCHER_PY:-$DIR/match-session-file.py}"
[ -f "$MATCHER_PY" ] || { echo "no existe: $MATCHER_PY"; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "python3 no esta en PATH"; exit 2; }
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0; SALIDA=""; RC=0
echo "SUT: $MATCHER_PY"

ok()   { PASS=$((PASS + 1)); }
fail() { FAIL=$((FAIL + 1)); echo "  FAIL $1"; [ -n "${2:-}" ] && echo "$2" | sed 's/^/         /'; return 0; }

# El desfase UTC solo existe fuera de UTC: se fija el huso para que el banco mida lo mismo en
# cualquier maquina. El runner de macOS ya dio un rojo falso por el reloj (2.19.2).
export TZ="America/Mexico_City"

# ---------------------------------------------------------------- fixture
# Construye mem/ y jd/ con un caso por sesion. Se regenera en cada llamada para que una mutacion
# no herede el estado de la anterior.
construir() {
  rm -rf "$TMP/mem" "$TMP/jd"
  mkdir -p "$TMP/mem/sessions" "$TMP/jd"
  python3 - "$TMP" <<'PY'
import json, os, sys, datetime

raiz = sys.argv[1]
mem = os.path.join(raiz, "mem", "sessions")
jd = os.path.join(raiz, "jd")


def ficha(nombre, session_id=None, cuerpo="trabajo"):
    fm = ["---", "type: session", "date: " + nombre[:10], "status: completed"]
    if session_id:
        fm.append("session_id: " + session_id)
    fm.append("---")
    with open(os.path.join(mem, nombre), "w", encoding="utf-8") as fh:
        fh.write("\n".join(fm) + "\n\n# " + cuerpo + "\n")


def utc_de(local_iso, hora=10):
    """'2026-05-04' a las <hora> LOCAL -> timestamp UTC con Z, como los escribe Claude Code."""
    d = datetime.date.fromisoformat(local_iso)
    naive = datetime.datetime(d.year, d.month, d.day, hora, 0, 0)
    local = naive.astimezone()
    return local.astimezone(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.000Z")


def jsonl(stem, ts, comandos=(), writes=()):
    lineas = [{"type": "user", "timestamp": ts,
               "message": {"role": "user", "content": "hola"}}]
    for c in comandos:
        lineas.append({"type": "assistant", "timestamp": ts, "message": {"role": "assistant",
                       "content": [{"type": "tool_use", "name": "Bash", "input": {"command": c}}]}})
    for w in writes:
        lineas.append({"type": "assistant", "timestamp": ts, "message": {"role": "assistant",
                       "content": [{"type": "tool_use", "name": "Write", "input": {"file_path": w}}]}})
    with open(os.path.join(jd, stem + ".jsonl"), "w", encoding="utf-8") as fh:
        for o in lineas:
            fh.write(json.dumps(o, ensure_ascii=False) + "\n")


# --- C1 sello exacto: la ficha lleva session_id y el JSONL ni menciona rutas.
ficha("2026-05-04-con-sello.md", session_id="aaaaaaaa-0000-0000-0000-000000000001")
jsonl("aaaaaaaa-0000-0000-0000-000000000001", utc_de("2026-05-04"))

# --- C2 redireccion de shell: `cat > memory/sessions/X.md <<EOF`.
ficha("2026-05-05-heredoc-shell.md")
jsonl("bbbbbbbb-0000-0000-0000-000000000002", utc_de("2026-05-05"),
      comandos=["cd /p; cat > memory/sessions/2026-05-05-heredoc-shell.md <<'EOF'\n---\ntype: session\n---\nEOF"])

# --- C3 (R2) idioma python con la ruta en variable: como se escriben aqui de verdad.
ficha("2026-05-06-heredoc-python.md")
jsonl("cccccccc-0000-0000-0000-000000000003", utc_de("2026-05-06"),
      comandos=["cd /p; python3 - <<'PY'\np=\"memory/sessions/2026-05-06-heredoc-python.md\"\n"
                "open(p,\"w\",encoding=\"utf-8\").write(\"hola\")\nPY"])

# --- C4 (R3) SOLO LEE una ficha que existe: no es suya.
ficha("2026-05-07-leida-por-otra.md", session_id="99999999-0000-0000-0000-00000000000f")
jsonl("dddddddd-0000-0000-0000-000000000004", utc_de("2026-05-07"),
      comandos=["cd /p; cat memory/sessions/2026-05-07-leida-por-otra.md | head -20",
                "sed -n '1,12p' memory/sessions/2026-05-07-leida-por-otra.md"])

# --- C5 sin ficha ninguna.
jsonl("eeeeeeee-0000-0000-0000-000000000005", utc_de("2026-05-08"))

# --- C6 (R1) desfase UTC: sesion de las 21:00 locales; en UTC ya es el dia siguiente.
ficha("2026-05-09-desfase-utc.md")
jsonl("ffffffff-0000-0000-0000-000000000006", utc_de("2026-05-09", hora=21),
      comandos=["cd /p; cat > memory/sessions/2026-05-09-desfase-utc.md <<'EOF'\nx\nEOF"])

# --- C7 (R4) copia la ficha a un temporal: el origen de un cp no se escribe.
ficha("2026-05-10-copiada-a-tmp.md", session_id="99999999-0000-0000-0000-00000000000e")
jsonl("11111111-0000-0000-0000-000000000007", utc_de("2026-05-10"),
      comandos=["T=$(mktemp -d); mkdir -p \"$T/m/sessions\"; "
                "cp memory/sessions/2026-05-10-copiada-a-tmp.md \"$T/m/sessions/\""])

# --- C8 (R5) una sesion CREA la ficha; otra del mismo dia solo la reescribe (enrich).
ficha("2026-05-11-de-la-creadora.md")
jsonl("22222222-0000-0000-0000-000000000008", utc_de("2026-05-11"),
      writes=["/p/memory/sessions/2026-05-11-de-la-creadora.md"])
jsonl("33333333-0000-0000-0000-000000000009", utc_de("2026-05-11"),
      comandos=["cd /p; python3 - <<'PY'\np=\"memory/sessions/2026-05-11-de-la-creadora.md\"\n"
                "s=open(p,encoding=\"utf-8\").read()\nopen(p,\"w\").write(s+\"enriquecido\")\nPY"])

# --- C13 ano ISO valido en el extremo minimo. Bajo un huso al oeste (el banco fija
#     America/Mexico_City) convertir 0001-01-01T02:00Z a hora local cae por debajo de
#     datetime.MINYEAR y lanza OverflowError. Sin capturarla, el matcher no falla en ESTA
#     sesion: se lleva por delante la clasificacion del corpus entero. El arreglo esta en los
#     DOS scripts y solo el del sello tenia mutacion; este caso le da la suya al matcher.
with open(os.path.join(jd, "aaaa0001-0000-0000-0000-0000000000bb.jsonl"), "w", encoding="utf-8") as fh:
    fh.write(json.dumps({"type": "user", "timestamp": "0001-01-01T02:00:00Z",
                         "message": {"role": "user", "content": "x"}}, ensure_ascii=False) + "\n")

# --- C12 transcripcion cuyos `timestamp` tienen pinta de fecha pero no lo son. `fecha_local`
#     recortaba a diez caracteres y fabricaba una fecha creible, asi que esta sesion parecia del
#     2026-05-05 y reclamaba la ficha de ese dia. Con `fecha_local` devolviendo None no tiene
#     fechas, no puede reclamar nada y sale a procesar. El defecto estaba en LOS DOS scripts y
#     solo el del sello tenia caso: este fija el del matcher.
with open(os.path.join(jd, "99999999-0000-0000-0000-0000000000aa.jsonl"), "w", encoding="utf-8") as fh:
    fh.write(json.dumps({"type": "user", "timestamp": "2026-05-05XXXXXXXXX",
                         "message": {"role": "user", "content": "x"}}, ensure_ascii=False) + "\n")
    fh.write(json.dumps({"type": "assistant", "timestamp": "2026-05-05XXXXXXXXX",
                         "message": {"role": "assistant", "content": [{"type": "tool_use", "name": "Bash",
                          "input": {"command": "cd /p; cat > memory/sessions/2026-05-05-heredoc-shell.md <<'EOF'\nx\nEOF"}}]}},
                        ensure_ascii=False) + "\n")

# --- C11 otra sesion del MISMO dia que C3, sin ficha propia. Sirve para probar que el sello no
#     se pisa: hace falta un UUID que pase la guarda de fecha y aun asi sea el equivocado.
jsonl("77777777-0000-0000-0000-00000000000c", utc_de("2026-05-06"))

# --- C9 sesion en curso (se pasa con --current).
jsonl("44444444-0000-0000-0000-00000000000a", utc_de("2026-05-12"))

# --- C10 higiene: un DIRECTORIO llamado algo.jsonl y un jsonl oculto no son sesiones.
os.makedirs(os.path.join(jd, "55555555-0000-0000-0000-00000000000b.jsonl"), exist_ok=True)
with open(os.path.join(jd, ".recall-index.jsonl"), "w", encoding="utf-8") as fh:
    fh.write('{"x":1}\n')
# ...y un DIRECTORIO llamado algo.md dentro de sessions/ no es una ficha.
os.makedirs(os.path.join(mem, "2026-05-13-soy-un-directorio.md"), exist_ok=True)
PY
}

# campo <stem-prefijo> <clave>  -> imprime ese campo del resultado, o AUSENTE
campo() {
  printf '%s' "$SALIDA" | python3 -c "
import json, sys
# Una salida vacia o rota NO es una excepcion del banco: es AUSENTE. Cuando una mutacion hace
# reventar al matcher, su stdout queda vacio, y sin esto el banco escupia un traceback de JSON
# por encima de su propio informe — ruido que tapa el resultado que se esta midiendo.
try:
    d = json.load(sys.stdin)
except (ValueError, TypeError):
    print('AUSENTE'); raise SystemExit(0)
for r in d.get('results', []):
    if r['stem'].startswith(sys.argv[1]):
        print(r.get(sys.argv[2], 'AUSENTE')); break
else:
    print('AUSENTE')
" "$1" "$2"
}

# veredicto <stem-prefijo>  -> imprime match|review|process|current|AUSENTE
veredicto() { campo "$1" verdict; }

correr() {
  SALIDA="$(python3 "$1" "$TMP/mem" "$TMP/jd" --current "44444444-0000-0000-0000-00000000000a" 2>"$TMP/err")"
  RC=$?
  return $RC
}

# esperar <etiqueta> <stem> <veredicto esperado>
esperar() {
  local got; got="$(veredicto "$2")"
  if [ "$got" = "$3" ]; then ok; else fail "$1: esperaba $3, dio $got"; fi
}

# ---------------------------------------------------------------- banco en verde
construir
correr "$MATCHER_PY" || fail "el matcher salio con codigo $RC" "$(cat "$TMP/err")"

esperar "C1 sello exacto"                 aaaaaaaa match
esperar "C2 heredoc de shell"             bbbbbbbb match
esperar "C3 heredoc de python (R2)"       cccccccc match
esperar "C4 solo lectura (R3)"            dddddddd process
esperar "C5 sin ficha"                    eeeeeeee process
esperar "C6 desfase UTC (R1)"             ffffffff match
esperar "C7 cp a temporal (R4)"           11111111 process
esperar "C8a la creadora"                 22222222 match
esperar "C8b la que solo reescribe (R5)"  33333333 review
esperar "C9 sesion en curso"              44444444 current
esperar "C10 directorio .jsonl"           55555555 AUSENTE
esperar "C11 otra sesion del mismo dia"   77777777 process
# Sin fechas legibles no puede reclamar la ficha del 2026-05-05 aunque diga haberla escrito.
esperar "C12 timestamps ilegibles"        99999999 process
# Con la excepcion capturada no tiene fecha utilizable y sale a procesar; sin capturar, el
# matcher revienta y este caso ni aparece.
esperar "C13 ano minimo (OverflowError)"  aaaa0001 process

# Y lo que de verdad esta en juego con C13: que UN solo timestamp imposible no se lleve por
# delante la clasificacion del corpus entero. El matcher tiene que TERMINAR BIEN con ese fichero
# dentro y seguir clasificando a los demas.
if [ "$RC" = "0" ] && [ "$(veredicto bbbbbbbb)" = "match" ]; then ok
else fail "C13: un timestamp imposible tumbo la clasificacion del corpus (rc=$RC)"; fi

# C6 otra vez, de frente: la fecha reportada tiene que ser la LOCAL (2026-05-09), no la UTC
# (2026-05-10). Para el VEREDICTO el margen de un dia tapa el defecto, asi que sin esta
# comprobacion R1 no se puede ver, y la mutacion M1 pasaria en verde con el defecto dentro.
if [ "$(campo ffffffff dateFirst)" = "2026-05-09" ]; then ok
else fail "C6 fecha local: esperaba dateFirst=2026-05-09, dio $(campo ffffffff dateFirst)"; fi

# El .jsonl oculto no se cuenta como sesion.
if printf '%s' "$SALIDA" | grep -q "recall-index"; then
  fail "C10 el .jsonl oculto entro en el inventario"
else ok; fi

# Un directorio llamado .md no se cuenta como ficha (no debe reclamar nada ni romper).
if [ -n "$(printf '%s' "$SALIDA" | python3 -c "
import json, sys
d = json.load(sys.stdin)
print('\n'.join(r['matched'] for r in d['results'] if 'soy-un-directorio' in (r['matched'] or '')))
")" ]; then fail "C10 un directorio .md se conto como ficha"; else ok; fi

# ---------------------------------------------------------------- el sello (stamp-session-id.py)
# El sello GANA a la evidencia de escritura en el matcher, asi que un sello equivocado no da un
# duplicado visible: da el fallo invisible. La primera version solo comprobaba que el UUID tuviera
# ALGUN .jsonl, con lo que cualquier id existente podia sellar cualquier ficha. Lo encontro un
# adversario externo el 2026-09-12, antes de publicar.
STAMP_PY="${STAMP_PY:-$DIR/stamp-session-id.py}"
if [ -f "$STAMP_PY" ]; then
  construir
  SID="cccccccc-0000-0000-0000-000000000003"     # su .jsonl es del 2026-05-06
  BUENA="$TMP/mem/sessions/2026-05-06-heredoc-python.md"
  AJENA="$TMP/mem/sessions/2026-05-11-de-la-creadora.md"

  python3 "$STAMP_PY" "$BUENA" "$SID" --jsonl-dir "$TMP/jd" >"$TMP/st1" 2>&1
  if grep -q 'stamped=1' "$TMP/st1" && grep -q "session_id: $SID" "$BUENA"; then ok
  else fail "sello: no sello la ficha de su propia fecha" "$(cat "$TMP/st1")"; fi

  # EL CASO DEL ADVERSARIO: mismo UUID valido, ficha de otra fecha. Tiene que negarse.
  python3 "$STAMP_PY" "$AJENA" "$SID" --jsonl-dir "$TMP/jd" >"$TMP/st2" 2>&1
  RC2=$?
  if [ "$RC2" != "0" ] && grep -q 'stamped=0' "$TMP/st2" && ! grep -q 'session_id' "$AJENA"; then ok
  else fail "sello: acepto sellar una ficha de fecha ajena (fallo invisible)" "$(cat "$TMP/st2")"; fi

  python3 "$STAMP_PY" "$BUENA" "99999999-0000-0000-0000-000000000099" --jsonl-dir "$TMP/jd" >"$TMP/st3" 2>&1
  if [ $? != 0 ] && grep -q 'no-hay-jsonl-para-ese-id' "$TMP/st3"; then ok
  else fail "sello: acepto un UUID sin transcripcion" "$(cat "$TMP/st3")"; fi

  # Con un UUID de la MISMA fecha: pasa la guarda de fecha, y aun asi no debe pisar el sello.
  python3 "$STAMP_PY" "$BUENA" "77777777-0000-0000-0000-00000000000c" --jsonl-dir "$TMP/jd" >"$TMP/st4" 2>&1
  if [ $? != 0 ] && grep -q 'ya-sellada-con-otro-id' "$TMP/st4"; then ok
  else fail "sello: piso un sello ajeno" "$(cat "$TMP/st4")"; fi

  # EL MARGEN. Ficha de UN dia despues de su transcripcion: con MARGEN_DIAS=0 se rechaza, con 1
  # se aceptaria. Es el unico caso que distingue los dos valores; sin el, revertir el margen no
  # ponia el banco en rojo y el arreglo no estaba fijado por nada.
  printf -- '---\ntype: session\ndate: 2026-05-07\nstatus: completed\n---\n# x\n' > "$TMP/mem/sessions/2026-05-07-un-dia-despues.md"
  python3 "$STAMP_PY" "$TMP/mem/sessions/2026-05-07-un-dia-despues.md" "$SID" --jsonl-dir "$TMP/jd" >"$TMP/st6" 2>&1
  if [ $? != 0 ] && grep -q 'stamped=0' "$TMP/st6"; then ok
  else fail "sello: acepto una ficha de un dia despues (el margen no es cero)" "$(cat "$TMP/st6")"; fi

  # LA FECHA ILEGIBLE. El nombre empieza por algo con forma de fecha pero que no existe, asi que
  # llega a `en_rango` y revienta al parsear: esa rama tiene que fallar CERRADO. Sin este caso,
  # devolver True ahi (el defecto original) pasaba inadvertido — los otros dos casos de
  # fail-cerrado los atajan las guardas de antes y nunca llegan a `en_rango`.
  printf -- '---\ntype: session\ndate: 2026-05-06\nstatus: completed\n---\n# x\n' > "$TMP/mem/sessions/2026-13-45-fecha-imposible.md"
  python3 "$STAMP_PY" "$TMP/mem/sessions/2026-13-45-fecha-imposible.md" "$SID" --jsonl-dir "$TMP/jd" >"$TMP/st7" 2>&1
  if [ $? != 0 ] && grep -q 'stamped=0' "$TMP/st7"; then ok
  else fail "sello: acepto una ficha con fecha imposible (en_rango falla ABIERTO)" "$(cat "$TMP/st7")"; fi

  # LA TRANSCRIPCION DE BASURA. Sus 'timestamp' tienen pinta de fecha pero no lo son. Recortar a
  # diez caracteres fabricaba una fecha creible y el sello pasaba. Tiene que rechazarse.
  printf '{"type":"user","timestamp":"2026-05-06XXXXXXXXX","message":{"role":"user","content":"x"}}\n' \
    > "$TMP/jd/88888888-0000-0000-0000-00000000000d.jsonl"
  printf -- '---\ntype: session\ndate: 2026-05-06\nstatus: completed\n---\n# x\n' > "$TMP/mem/sessions/2026-05-06-contra-basura.md"
  python3 "$STAMP_PY" "$TMP/mem/sessions/2026-05-06-contra-basura.md" "88888888-0000-0000-0000-00000000000d" --jsonl-dir "$TMP/jd" >"$TMP/st8" 2>&1
  if [ $? != 0 ] && grep -q 'timestamps-legibles' "$TMP/st8"; then ok
  else fail "sello: acepto una transcripcion sin un solo timestamp valido" "$(cat "$TMP/st8")"; fi

  # EL ANO IMPOSIBLE. Un timestamp ISO valido (parsea sin excepcion) puede seguir reventando en
  # `dt.astimezone()`: el ano 0001 en UTC, convertido a un huso al oeste (este banco corre en
  # America/Mexico_City), cae antes de datetime.MINYEAR y `OverflowError` no es NI ValueError NI
  # OSError. Sin capturarla, la excepcion no cogida tumbaba el proceso ENTERO (en el matcher, todo
  # el corpus, no solo esta transcripcion) en vez de devolver None y dejar actuar al fail-cerrado.
  # Lo encontro un adversario en la cuarta ronda, probando exactamente el caso que el propio round
  # pedia probar: "fecha valida pero absurda como el ano 0001 o 9999".
  printf '{"type":"user","timestamp":"0001-01-01T02:00:00Z","message":{"role":"user","content":"x"}}\n' \
    > "$TMP/jd/99999999-0000-0000-0000-0000000000ee.jsonl"
  printf -- '---\ntype: session\ndate: 2026-05-06\nstatus: completed\n---\n# x\n' > "$TMP/mem/sessions/2026-05-06-ano-imposible.md"
  python3 "$STAMP_PY" "$TMP/mem/sessions/2026-05-06-ano-imposible.md" "99999999-0000-0000-0000-0000000000ee" --jsonl-dir "$TMP/jd" >"$TMP/st9" 2>&1
  if [ $? != 0 ] && grep -q 'timestamps-legibles' "$TMP/st9" && ! grep -q 'Traceback' "$TMP/st9"; then ok
  else fail "sello: OverflowError (ano 0001) no capturada -- crash en vez de stamped=0" "$(cat "$TMP/st9")"; fi

  # Fail CERRADO: si la ficha no empieza por fecha, no hay nada que comprobar y no se sella.
  printf -- '---\ntype: session\ndate: 2026-05-06\nstatus: completed\n---\n# x\n' > "$TMP/mem/sessions/sin-fecha.md"
  python3 "$STAMP_PY" "$TMP/mem/sessions/sin-fecha.md" "$SID" --jsonl-dir "$TMP/jd" >"$TMP/st5" 2>&1
  if [ $? != 0 ] && grep -q 'no-empieza-por-fecha' "$TMP/st5"; then ok
  else fail "sello: sello una ficha sin fecha en el nombre" "$(cat "$TMP/st5")"; fi

  # Y la ficha recien sellada tiene que salir `match` por sello en el matcher.
  correr "$MATCHER_PY"
  esperar "sello -> el matcher lo reconoce" cccccccc match
else
  fail "sello: no existe $STAMP_PY"
fi

# ---------------------------------------------------------------- mutaciones: tienen que dar ROJO
# Cada mutacion reinyecta un defecto real y el banco reducido debe fallar al menos un caso.
CASOS_QUE_DEBEN_CAER=()

muta() {
  local etiqueta="$1"; shift
  local copia="$TMP/mutante.py"
  cp "$MATCHER_PY" "$copia"
  if ! python3 - "$copia" "$@" <<'PY'
import sys
p = sys.argv[1]
s = open(p, encoding="utf-8").read()
for i in range(2, len(sys.argv), 2):
    viejo, nuevo = sys.argv[i], sys.argv[i + 1]
    if viejo not in s:
        sys.stderr.write("MUTACION NO APLICABLE: %r\n" % viejo[:70])
        sys.exit(3)
    s = s.replace(viejo, nuevo, 1)
open(p, "w", encoding="utf-8").write(s)
PY
  then
    # Una mutacion que ya no encaja con el fuente NO es un verde: es un banco ciego.
    fail "$etiqueta: la mutacion no se pudo aplicar (el fuente cambio; actualiza el banco)"
    return 0
  fi
  construir
  correr "$copia"
  local rojo=0 caso stem esperado clave
  for caso in "${CASOS_QUE_DEBEN_CAER[@]}"; do
    stem="${caso%% *}"; esperado="${caso##* }"
    if [ "${esperado%%=*}" != "$esperado" ]; then
      clave="${esperado%%=*}"; esperado="${esperado#*=}"
    else
      clave="verdict"
    fi
    [ "$(campo "$stem" "$clave")" != "$esperado" ] && rojo=1
  done
  if [ "$rojo" = "1" ]; then ok; else fail "$etiqueta: el banco NO se puso rojo — no discrimina"; fi
}

# M1: fecha UTC cruda en vez de local -> C6 tiene que caer.
CASOS_QUE_DEBEN_CAER=("ffffffff dateFirst=2026-05-09")
muta "M1 fecha UTC cruda" \
  '        return dt.astimezone().date().isoformat() if dt.tzinfo else dt.date().isoformat()' \
  '        return ts[:10]  # MUTACION'

# M2: sin el idioma (c), la ruta ligada a variable -> C3 tiene que caer.
CASOS_QUE_DEBEN_CAER=("cccccccc match")
muta "M2 sin el idioma python-variable" \
  '    # (c) variables ligadas a esta ruta, y luego usadas para escribir' \
  '    return False  # MUTACION'

# M4: `fecha_local` del MATCHER vuelve a fabricar una fecha con ts[:10] -> C12 tiene que caer.
CASOS_QUE_DEBEN_CAER=("99999999 process")
muta "M4 el matcher fabrica fecha con ts[:10]" \
  '    except (ValueError, TypeError, OSError):
        return None' \
  '    except (ValueError, TypeError, OSError):
        return ts[:10]  # MUTACION'

# M5: el matcher deja de capturar OverflowError -> C13 tiene que caer. Aqui cae C13 Y CAE TODO,
# y eso no es ruido: es la firma exacta del defecto. Una excepcion no capturada al leer UN fichero
# aborta el proceso, asi que el precio de un timestamp imposible en cualquier `.jsonl` del
# directorio es la clasificacion del corpus entero, no la de esa sesion. El aserto de arriba
# ("un timestamp imposible tumbo la clasificacion del corpus") es el que nombra esa diferencia.
# Antes de tener C13 y M5, el arreglo del matcher solo se probaba de rebote.
CASOS_QUE_DEBEN_CAER=("aaaa0001 process")
muta "M5 el matcher no captura OverflowError" \
  '    except (ValueError, OSError, OverflowError):' \
  '    except (ValueError, OSError):  # MUTACION'

# M3: todo cuenta como escritura -> C4, C5 y C7 tienen que caer.
CASOS_QUE_DEBEN_CAER=("dddddddd process" "eeeeeeee process" "11111111 process")
muta "M3 siempre casa" \
  '    tramo = cmd[:inicio]' \
  '    return True  # MUTACION'

# ---------------------------------------------------------------- mutaciones del sello
# La ronda 3 del adversario midio que los dos arreglos de la ronda 2 NO estaban fijados por nada:
# revertir `MARGEN_DIAS` a 1, o `en_rango` a fail-abierto, dejaba el banco en PASS=24 FAIL=0. Un
# arreglo que se puede revertir sin que nada se queje no esta probado, esta escrito. Cada mutacion
# de aqui exige ademas que caiga EL ASERTO QUE LE TOCA: que el banco se ponga rojo por otra cosa
# no prueba que este caso discrimine.
mutar_sello() {   # mutar_sello <etiqueta> <viejo> <nuevo> <fragmento del FAIL esperado>
  local etiqueta="$1" viejo="$2" nuevo="$3" esperado="$4"
  local copia="$TMP/sello-mutante.py"
  cp "$STAMP_PY" "$copia"
  if ! python3 - "$copia" "$viejo" "$nuevo" <<'PY'
import sys
p, v, n = sys.argv[1], sys.argv[2], sys.argv[3]
s = open(p, encoding="utf-8").read()
if v not in s:
    sys.stderr.write("MUTACION NO APLICABLE\n")
    sys.exit(3)
open(p, "w", encoding="utf-8").write(s.replace(v, n, 1))
PY
  then
    fail "$etiqueta: la mutacion no se pudo aplicar (el fuente cambio; actualiza el banco)"
    return 0
  fi
  if STAMP_PY="$copia" MATCHER_PY="$MATCHER_PY" bash "$0" >"$TMP/mut-out" 2>&1; then
    fail "$etiqueta: el banco NO se puso rojo — ese arreglo no lo fija nada"
  elif grep -q "$esperado" "$TMP/mut-out"; then
    ok
  else
    fail "$etiqueta: cayo, pero por otro aserto" "$(grep FAIL "$TMP/mut-out" | head -3)"
  fi
}

if [ -f "$STAMP_PY" ] && [ -z "${EN_MUTACION:-}" ]; then
  export EN_MUTACION=1
  mutar_sello "S1 margen de un dia" \
    "MARGEN_DIAS = 0" "MARGEN_DIAS = 1" "un dia despues"
  mutar_sello "S2 en_rango fail-abierto" \
    "        return False
    return a <= f <= b" "        return True  # MUTACION
    return a <= f <= b" "fecha imposible"
  mutar_sello "S3 fecha fabricada con ts[:10]" \
    "    except (ValueError, TypeError, OSError):
        return None" "    except (ValueError, TypeError, OSError):
        return ts[:10]  # MUTACION" "sin un solo timestamp valido"
  mutar_sello "S4 sin guarda de fecha" \
    "        if not en_rango(fecha_ficha, primera, ultima):" "        if False:  # MUTACION" "fecha ajena"
  mutar_sello "S5 OverflowError sin capturar (ano imposible)" \
    "    except (ValueError, OSError, OverflowError):" "    except (ValueError, OSError):  # MUTACION" \
    "OverflowError"
  unset EN_MUTACION
fi

echo
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" = "0" ] || exit 1
