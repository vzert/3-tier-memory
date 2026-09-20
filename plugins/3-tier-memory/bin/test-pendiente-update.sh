#!/bin/bash
# Prueba de `pendiente.update` (journal-emit.py + journal-compact.py).
#
# Lo que este evento tiene que cumplir, y por que cada cosa:
#
# El id de upstream es `sha1(texto+creado+origen)[:10]`, asi que corregir el texto le cambia el
# hash. El evento conserva el id VIEJO a proposito: ese id ya esta citado en fichas de sesion, en
# recordatorios de calendario y en research, y renombrarlo deja todas esas citas apuntando a nada
# — que es exactamente lo que hacia el unico camino que habia antes (`resolve --superseded` +
# `add`), ademas de partir la fila mensual en dos trabajos donde solo hay uno.
#
# El precio de conservarlo es que el id deja de casar con el hash de su propia linea, y hay DOS
# herramientas que miden esa discrepancia: `repair-dualwrite.ids_invented` (avisa) y
# `--fix-ids --apply` (RENOMBRA). La marca `_actualizado: FECHA_` en la linea es lo que las
# distingue de un id tecleado a mano. Por eso los tres primeros casos de este fichero no prueban
# la edicion —que es la parte facil— sino que las otras herramientas no la deshagan.
#
# Contexto de por que esto se prueba entre ficheros y no dentro de uno: 2.15.0 anadio `_revisar:`
# a la linea de Tier 2 y `repair-dualwrite` no lo despojaba antes de hashear, asi que todo
# pendiente con ventana salia como `ids_invented` falso (learning 143). `_actualizado:` es la
# siguiente clave que se anade al mismo formato; el caso 15 compara las 7 expresiones que lo
# despojan con un comando, en vez de afirmar que son iguales (learning 148).
set -e
BIN="$(cd "$(dirname "$0")" && pwd)"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
pass=0; fail=0
chk() { if [ "$2" = "$3" ]; then pass=$((pass+1)); echo "  ok  $1"; else fail=$((fail+1)); echo "  FALLA $1: esperaba '$2', salio '$3'"; fi; }

M="$T/memory"
emit() { python3 "$BIN/journal-emit.py" --memory-dir "$M" "$@"; }
compact() { python3 "$BIN/journal-compact.py" --memory-dir "$M" "$@"; }
linea() { grep -m1 "_id: $1_" "$M/_pendientes.md" || true; }
fila() { grep -m1 "_id: $1_" "$M"/pendientes/2026-*.md || true; }
cuarentena() { ls "$M/.journal/quarantine" 2>/dev/null | grep -c '\.json$' | tr -d ' '; }
motivo() { cat "$M/.journal/quarantine"/*.reason 2>/dev/null | tr '\n' ' '; }

fixture() {
  rm -rf "$M"; mkdir -p "$M/pendientes" "$M/sessions"
  printf -- '---\ntype: index\n---\n# Pendientes\n\n## Alta prioridad\n\n## Media prioridad\n\n## Baja prioridad\n' > "$M/_pendientes.md"
  printf -- '# demo\n' > "$M/sessions/2026-09-19-demo.md"
  ID=$(emit --type pendiente.add --text "comprobar el 2026-09-20 que 7 code maps salieron del codigo actual" \
         --prioridad Media --origen "[[sessions/2026-09-19-demo]]" --creado 2026-09-12)
  compact --quiet >/dev/null
}
NUEVO="unir el PR #214 de los code maps (la comprobacion de los 7 ya se hizo)"

echo "== 1. el update cambia el texto y CONSERVA el id de nacimiento =="
fixture
emit --type pendiente.update --id "$ID" --text "$NUEVO" >/dev/null
compact --quiet >/dev/null
chk "la linea sigue teniendo el id viejo" "1" "$(printf '%s' "$(linea "$ID")" | grep -c "_id: ${ID}_")"
chk "el texto es el nuevo" "1" "$(printf '%s' "$(linea "$ID")" | grep -c 'unir el PR #214')"
chk "el texto viejo ya no esta" "0" "$(printf '%s' "$(linea "$ID")" | grep -c 'comprobar el 2026-09-20')"
chk "deja la marca _actualizado:" "1" "$(printf '%s' "$(linea "$ID")" | grep -c '_actualizado: 20')"
chk "conserva _origen:" "1" "$(printf '%s' "$(linea "$ID")" | grep -c '_origen: \[\[sessions/2026-09-19-demo\]\]_')"
chk "conserva _creado:" "1" "$(printf '%s' "$(linea "$ID")" | grep -c '_creado: 2026-09-12_')"
chk "la fila mensual lleva el texto nuevo con el MISMO id" "1" "$(printf '%s' "$(fila "$ID")" | grep -c "unir el PR #214.*_id: ${ID}_")"
chk "no cuarentena nada" "0" "$(cuarentena)"

echo "== 2. tras el update, ids_invented sigue en 0 (el fallo de 2.15.0, con otra clave) =="
# Sin la marca `_actualizado:`, `ids_invented` contaria esta linea y el aviso diria que un
# reemit crearia una fila duplicada — y seria falso, porque el reemit lo cubre el caso 4.
O=$(python3 "$BIN/repair-dualwrite.py" "$M" 2>&1 | grep -m1 '^adopted=')
chk "ids_invented=0" "1" "$(printf '%s' "$O" | grep -c 'ids_invented=0')"

echo "== 3. --fix-ids --apply NO renombra un id conservado a proposito =="
# Este es el consumidor que hace dano: `ids_invented` solo avisa, `--fix-ids --apply` reescribe
# el id en Tier 2 y en la fila mensual. Si lo renombrara aqui, el evento no serviria para nada:
# las citas quedarian rotas igual que con superseded+add.
ANTES=$(linea "$ID")
python3 "$BIN/repair-dualwrite.py" "$M" --fix-ids --apply >/dev/null 2>&1
chk "la linea no cambio ni un byte" "$ANTES" "$(linea "$ID")"
chk "el id sigue siendo el de nacimiento" "1" "$(grep -c "_id: ${ID}_" "$M/_pendientes.md")"

echo "== 4. replay del add ORIGINAL: noop, no colision de id =="
# Dos sesiones emitiendo el mismo pendiente el mismo dia es el camino de deduplicacion normal y
# documentado. Tras un update el texto del add ya NO casa con la linea; sin el guard, ese replay
# corriente acabaria en cuarentena, mandandole a una persona un trabajo que no existe.
emit --type pendiente.add --text "comprobar el 2026-09-20 que 7 code maps salieron del codigo actual" \
     --prioridad Media --origen "[[sessions/2026-09-19-demo]]" --creado 2026-09-12 >/dev/null
O=$(compact 2>&1)
chk "no cuarentena" "0" "$(cuarentena)"
chk "sigue habiendo UNA sola linea viva" "1" "$(grep -c '^- \[ \]' "$M/_pendientes.md")"
chk "avisa de que lo descarta, y donde lo guarda" "1" "$(printf '%s' "$O" | grep -c 'el add se descarta y queda entero en')"

echo "== 5. replay del MISMO update: idempotente, no reescribe cada dia =="
# La fecha de `_actualizado:` sale del EVENTO, no de date.today(): si saliera de hoy, cada replay
# cambiaria la linea y el detector de deriva veria una escritura fuera del journal.
ANTES=$(linea "$ID")
emit --type pendiente.update --id "$ID" --text "$NUEVO" >/dev/null
O=$(compact 2>&1)
chk "applied=0" "1" "$(printf '%s' "$O" | grep -c 'applied=0')"
chk "la linea no cambio" "$ANTES" "$(linea "$ID")"

echo "== 6. cambio de prioridad: mueve la linea de seccion y actualiza la celda =="
fixture
emit --type pendiente.update --id "$ID" --prioridad Alta >/dev/null
compact --quiet >/dev/null
ALTA=$(sed -n '/## Alta prioridad/,/## Media prioridad/p' "$M/_pendientes.md")
chk "la linea vive bajo Alta" "1" "$(printf '%s' "$ALTA" | grep -c "_id: ${ID}_")"
chk "ya no esta bajo Media" "0" "$(sed -n '/## Media prioridad/,/## Baja prioridad/p' "$M/_pendientes.md" | grep -c "_id: ${ID}_")"
chk "la celda Prioridad de la fila mensual dice Alta" "1" "$(printf '%s' "$(fila "$ID")" | grep -c '| Alta |')"

echo "== 7. cambiar SOLO la prioridad no deja marca _actualizado: =="
# La prioridad no entra en el hash, asi que el id sigue casando con su texto. Marcar la linea
# silenciaria `ids_invented` sobre un pendiente que no lo necesita — apagar una alarma buena.
chk "sin marca" "0" "$(printf '%s' "$(linea "$ID")" | grep -c '_actualizado:')"
chk "y el texto sigue intacto" "1" "$(printf '%s' "$(linea "$ID")" | grep -c 'comprobar el 2026-09-20')"

echo "== 8. la cola de metadatos se conserva VERBATIM (incluida una clave que el evento no toca) =="
fixture
emit --type pendiente.window --id "$ID" --revisar 2026-10-01 >/dev/null
compact --quiet >/dev/null
emit --type pendiente.update --id "$ID" --text "$NUEVO" >/dev/null
compact --quiet >/dev/null
chk "_revisar: sobrevive al update" "1" "$(printf '%s' "$(linea "$ID")" | grep -c '_revisar: 2026-10-01_')"
chk "y la marca nueva tambien esta" "1" "$(printf '%s' "$(linea "$ID")" | grep -c '_actualizado: 20')"
chk "_revisar: no esta duplicado" "1" "$(printf '%s' "$(linea "$ID")" | grep -o '_revisar:' | wc -l | tr -d ' ')"

echo "== 9. sobre un pendiente RESUELTO: noop con aviso, no lo resucita =="
fixture
emit --type pendiente.resolve --id "$ID" --estado resolved >/dev/null
compact --quiet >/dev/null
emit --type pendiente.update --id "$ID" --text "$NUEVO" >/dev/null
O=$(compact 2>&1)
chk "no cuarentena (cerrado no es un error)" "0" "$(cuarentena)"
chk "avisa de que ya esta resuelto" "1" "$(printf '%s' "$O" | grep -c 'ya esta resuelto')"
chk "no reaparece en _pendientes.md" "0" "$(grep -c "_id: ${ID}_" "$M/_pendientes.md")"
chk "la fila mensual sigue con su fecha de cierre" "1" "$(printf '%s' "$(fila "$ID")" | grep -c '| 20[0-9][0-9]-[0-9][0-9]-[0-9][0-9] |')"

echo "== 10. sobre un CADUCADO: noop con aviso, reabrir es pendiente.reopen =="
fixture
emit --type pendiente.expire --id "$ID" --dias 90 >/dev/null
compact --quiet >/dev/null
emit --type pendiente.update --id "$ID" --text "$NUEVO" >/dev/null
O=$(compact 2>&1)
chk "no cuarentena" "0" "$(cuarentena)"
chk "avisa de que esta caducado" "1" "$(printf '%s' "$O" | grep -c 'ya esta caducado')"

echo "== 11. id que no existe en ningun sitio: A CUARENTENA, no un silencio =="
# `find_id_line` devuelve None por dos razones opuestas: el pendiente se cerro (caso 9 y 10, un
# noop legitimo) o el id no existio nunca (un id mal tecleado). Tratarlas igual convierte el
# segundo en una correccion que el agente cree hecha y no se hizo.
fixture
emit --type pendiente.update --id p-0000000000 --text "$NUEVO" >/dev/null
compact --quiet >/dev/null 2>&1 || true
chk "un evento en cuarentena" "1" "$(cuarentena)"
chk "el motivo dice unknown-id" "1" "$(printf '%s' "$(motivo)" | grep -c 'unknown-id')"

echo "== 12. actualizacion perdida entre dos sesiones: prefix-mismatch =="
# Aqui corren 5-10 sesiones a la vez. Si otra cambio el texto entre la emision y el compactado,
# aplicar a ciegas pisa su correccion sin que nadie lo vea.
fixture
emit --type pendiente.update --id "$ID" --text "$NUEVO" --text-prefix "un texto que esta linea no tiene" >/dev/null
compact --quiet >/dev/null 2>&1 || true
chk "un evento en cuarentena" "1" "$(cuarentena)"
chk "el motivo dice prefix-mismatch" "1" "$(printf '%s' "$(motivo)" | grep -c 'prefix-mismatch')"
chk "la linea no se toco" "1" "$(printf '%s' "$(linea "$ID")" | grep -c 'comprobar el 2026-09-20')"

echo "== 13. --text con metadatos pegados: se despojan y se avisa =="
# Pegar la linea entera es el error natural (se copia de _pendientes.md). Sin despojar, la linea
# acabaria con dos `_id:` y find_id_line/find_monthly_row dejarian de resolverla.
fixture
E=$(emit --type pendiente.update --id "$ID" --text "texto nuevo — _origen: [[sessions/x]]_ — _id: p-1111111111_" 2>&1 >/dev/null)
compact --quiet >/dev/null
chk "avisa de que los quito" "1" "$(printf '%s' "$E" | grep -c 'se quitaron los metadatos')"
chk "la linea tiene UN solo _id:" "1" "$(printf '%s' "$(linea "$ID")" | grep -o '_id:' | wc -l | tr -d ' ')"
chk "y es el de nacimiento" "1" "$(printf '%s' "$(linea "$ID")" | grep -c "_id: ${ID}_")"

echo "== 14. el emisor exige --text y/o --prioridad =="
fixture
RC=0; emit --type pendiente.update --id "$ID" >/dev/null 2>&1 || RC=$?
chk "sale con error" "1" "$([ "$RC" -ne 0 ] && echo 1 || echo 0)"
chk "no dejo evento pendiente" "0" "$(ls "$M/.journal/pending" 2>/dev/null | grep -c '\.json$' | tr -d ' ')"

echo "== 15. resolve DESPUES de un update: el prefijo se toma del texto nuevo =="
fixture
emit --type pendiente.update --id "$ID" --text "$NUEVO" >/dev/null
compact --quiet >/dev/null
emit --type pendiente.resolve --id "$ID" --estado resolved --nota "cerrado tras el update" >/dev/null
compact --quiet >/dev/null
chk "no cuarentena" "0" "$(cuarentena)"
chk "la linea desaparecio de _pendientes.md" "0" "$(grep -c "_id: ${ID}_" "$M/_pendientes.md")"
chk "la fila mensual quedo cerrada" "1" "$(printf '%s' "$(fila "$ID")" | grep -c 'cerrado tras el update')"

echo "== 16. las 7 expresiones que despojan metadatos son IDENTICAS caracter a caracter =="
# No basta con decirlo en un comentario: eso es justo lo que decia el comentario de
# `journal-emit.strip_meta` mientras `repair-dualwrite.META_RE` ya habia divergido (learning 148).
N=$(grep -ho 'r"\\s\*—\\s\*_(?:origen|creado|id|revisar|actualizado):\[^—\]\*"' \
      "$BIN/journal-emit.py" "$BIN/journal-compact.py" "$BIN/repair-dualwrite.py" \
      "$BIN/enrich-memory.py" "$BIN/expire-pendientes.py" "$BIN/triage-scan.py" \
      "$BIN/build-recall-index.py" | sort -u | wc -l | tr -d ' ')
# Se cuenta la CADENA COMPLETA del despojador, no el juego de claves suelto: journal-compact.py
# lleva ademas `META_START_RE`, que usa las mismas claves para localizar donde empieza la cola y
# no para borrarla. Contar el fragmento la daria por un octavo despojador que no existe.
C=$(grep -hoc 'r"\\s\*—\\s\*_(?:origen|creado|id|revisar|actualizado):\[^—\]\*"' \
      "$BIN/journal-emit.py" "$BIN/journal-compact.py" "$BIN/repair-dualwrite.py" \
      "$BIN/enrich-memory.py" "$BIN/expire-pendientes.py" "$BIN/triage-scan.py" \
      "$BIN/build-recall-index.py" | paste -sd+ - | bc)
chk "los 7 ficheros la llevan" "7" "$C"
chk "y las 7 son la MISMA cadena" "1" "$N"

echo "== 17. el marcador no esconde lineas al parser de Tier 2 =="
# Un regex que cierre con \b NO casa en `_id: p-xxx_` porque `_` es caracter de palabra: una
# sesion par midio que asi se le perdian 24 de 190 pendientes, en silencio. Se cuenta contra el
# grep crudo, que es la unica cifra que no depende del parser que se esta probando.
fixture
emit --type pendiente.update --id "$ID" --text "$NUEVO" >/dev/null
compact --quiet >/dev/null
CRUDO=$(grep -c '^- \[ \]' "$M/_pendientes.md")
PARSER=$(python3 -c "
import importlib.util, sys
spec = importlib.util.spec_from_file_location('rd', sys.argv[1] + '/repair-dualwrite.py')
rd = importlib.util.module_from_spec(spec); spec.loader.exec_module(rd)
print(len(rd.parse_tier2(sys.argv[2] + '/_pendientes.md')))" "$BIN" "$M")
chk "el parser ve las mismas lineas que el grep crudo" "$CRUDO" "$PARSER"

echo "== 18. la marca sola NO basta: un evento incoherente sigue yendo a cuarentena =="
# Hallazgo de un adversario externo (ronda 1): `_actualizado:` es texto que cualquiera puede
# escribir a mano. Si bastara para convertir una colision de id en noop, escribirla seria la forma
# de que un `add` con OTRO pendiente bajo el mismo id se descartara en silencio. Lo que se exige
# ademas es que el evento sea coherente consigo mismo: su id tiene que ser el hash de su propio
# texto+creado+origen.
fixture
emit --type pendiente.update --id "$ID" --text "$NUEVO" >/dev/null
compact --quiet >/dev/null
# Un evento add FORJADO: reclama el id de la linea pero su texto no lo produce.
python3 - "$M" "$ID" <<'PYEOF'
import json, os, sys, time
mem, pid = sys.argv[1], sys.argv[2]
d = os.path.join(mem, ".journal", "pending"); os.makedirs(d, exist_ok=True)
ev = {"v": 1, "type": "pendiente.add", "ts": time.time_ns(), "session_id": "forjado",
      "agent_id": "forjado",
      "payload": {"id": pid, "text": "un pendiente completamente distinto", "prioridad": "Media",
                  "origen": "[[sessions/2026-09-19-demo]]", "creado": "2026-09-12", "revisar": ""}}
open(os.path.join(d, "9999-forjado.json"), "w", encoding="utf-8").write(json.dumps(ev))
PYEOF
compact --quiet >/dev/null 2>&1 || true
chk "el add forjado va a cuarentena" "1" "$(cuarentena)"
chk "el motivo sigue siendo id-collision" "1" "$(printf '%s' "$(motivo)" | grep -c 'id-collision')"

echo "== 19. un update sin fecha real se cuarentena, no cae en date.today() =="
# Si cayera en hoy, cada replay reescribiria la linea otro dia y el detector de deriva veria una
# escritura fuera del journal. Y una fecha imposible produce una marca que ACTUALIZADO_RE no
# reconoce, que el replay siguiente duplicaria.
fixture
python3 - "$M" "$ID" <<'PYEOF'
import json, os, sys, time
mem, pid = sys.argv[1], sys.argv[2]
d = os.path.join(mem, ".journal", "pending"); os.makedirs(d, exist_ok=True)
for n, fecha in (("1", None), ("2", "2026-99-99")):
    p = {"id": pid, "text": "texto nuevo sin fecha valida", "prioridad": "",
         "text_prefix": ""}
    if fecha:
        p["fecha"] = fecha
    ev = {"v": 1, "type": "pendiente.update", "ts": time.time_ns(), "session_id": "s",
          "agent_id": "a", "payload": p}
    open(os.path.join(d, f"999{n}-sinfecha.json"), "w", encoding="utf-8").write(json.dumps(ev))
PYEOF
compact --quiet >/dev/null 2>&1 || true
chk "los dos eventos a cuarentena" "2" "$(cuarentena)"
chk "el motivo nombra la fecha" "1" "$([ "$(printf '%s' "$(motivo)" | grep -c "sin .fecha. con una fecha real")" -ge 1 ] && echo 1 || echo 0)"
chk "la linea no se toco" "1" "$(printf '%s' "$(linea "$ID")" | grep -c 'comprobar el 2026-09-20')"

echo "== 20. repair-dualwrite CLASIFICA la linea corregida, no la esconde =="
# La marca no apaga la alarma: la explica. Un `ids_actualizados` distinto de cero es normal si
# alguien corrigio pendientes, y es la pista a seguir si nadie lo hizo.
fixture
emit --type pendiente.update --id "$ID" --text "$NUEVO" >/dev/null
compact --quiet >/dev/null
O=$(python3 "$BIN/repair-dualwrite.py" "$M" 2>&1)
chk "ids_invented sigue en 0" "1" "$(printf '%s' "$O" | grep -c 'ids_invented=0')"
chk "pero la cuenta aparte" "1" "$(printf '%s' "$O" | grep -c 'ids_actualizados=1')"
chk "y nombra el id en el detalle" "1" "$(printf '%s' "$O" | grep -c "NOTA 1 pendiente")"

echo "== 21. sin fila mensual: Tier 2 se corrige y el aviso lo DICE =="
# Mismo comportamiento que `pendiente.resolve`/`expire` ante una fila que falta: se avisa y no se
# inventa la fila. Lo que este caso fija es que el aviso exista, para que "Tier 2 corregido y
# Tier 3 no" no sea un silencio.
fixture
rm -f "$M"/pendientes/2026-09.md
emit --type pendiente.update --id "$ID" --text "$NUEVO" >/dev/null
O=$(compact 2>&1)
chk "avisa de que no hay fila" "1" "$(printf '%s' "$O" | grep -c 'sin fila con id')"
chk "y Tier 2 si quedo corregido" "1" "$(printf '%s' "$(linea "$ID")" | grep -c 'unir el PR #214')"
chk "no cuarentena" "0" "$(cuarentena)"

echo "== 22. los nudges y los comandos nombran el evento nuevo =="
# Learning 149: cuando una regla cambia, sus ejemplos y sus listas son carriers, no decoracion.
chk "journal-guard.sh lo nombra" "1" "$([ "$(grep -c 'pendiente.add/resolve/update' "$BIN/journal-guard.sh")" -ge 1 ] && echo 1 || echo 0)"
chk "bash-journal-nudge.sh lo nombra" "1" "$([ "$(grep -c 'pendiente.add/resolve/update' "$BIN/bash-journal-nudge.sh")" -ge 1 ] && echo 1 || echo 0)"
chk "las 3 plantillas lo nombran" "3" "$(grep -l 'pendiente.update' "$BIN/../templates/triage-3t.md" "$BIN/../templates/checkpoint-3t.md" "$BIN/../templates/audit-3t.md" | wc -l | tr -d ' ')"

echo "== 23. el add descartado no se pierde: queda entero en un log del journal =="
# `add_es_su_propio_origen` prueba coherencia, no procedencia: un adversario externo construyo por
# fuerza bruta dos textos distintos con el mismo id de 40 bits, mismo creado y mismo origen, y la
# comprobacion dice True para los dos. El texto de nacimiento ya no existe en ningun sitio (lo
# reemplazo el update), asi que distinguirlos es imposible. Lo que si se puede es no PERDER el
# descartado.
fixture
emit --type pendiente.update --id "$ID" --text "$NUEVO" >/dev/null
compact --quiet >/dev/null
emit --type pendiente.add --text "comprobar el 2026-09-20 que 7 code maps salieron del codigo actual" \
     --prioridad Media --origen "[[sessions/2026-09-19-demo]]" --creado 2026-09-12 >/dev/null
O=$(compact 2>&1)
chk "el aviso nombra el log" "1" "$(printf '%s' "$O" | grep -c 'adds-descartados.log')"
chk "el log existe" "1" "$([ -f "$M/.journal/adds-descartados.log" ] && echo 1 || echo 0)"
chk "y lleva el texto entero del add descartado" "1" "$(grep -c 'comprobar el 2026-09-20 que 7 code maps' "$M/.journal/adds-descartados.log")"
chk "con su id, creado, origen y prioridad" "1" "$(grep -c "$ID.*2026-09-12.*sessions/2026-09-19-demo.*Media" "$M/.journal/adds-descartados.log")"
# Y el log sobrevive al camino que mas corre, que es el silencioso (recall.sh usa --quiet).
emit --type pendiente.add --text "comprobar el 2026-09-20 que 7 code maps salieron del codigo actual" \
     --prioridad Media --origen "[[sessions/2026-09-19-demo]]" --creado 2026-09-12 >/dev/null
compact --quiet >/dev/null 2>&1
chk "un segundo descarte con --quiet tambien se registra" "2" "$(grep -c 'comprobar el 2026-09-20 que 7 code maps' "$M/.journal/adds-descartados.log")"

echo "== 24. un tabulador o un salto crudos no parten el registro del log =="
# El compactador es su propia frontera de confianza: `validate` de pendiente.add comprueba que los
# campos esten, no los normaliza, asi que un evento escrito a mano llega hasta el log con `\t` y
# `\n` crudos. Antes de escaparlos el fichero quedaba byte-completo pero NO recuperable: el `\t`
# corria el campo y el `\n` partia el registro en dos lineas, y el propio grep con el que el caso
# 23 prueba que se recupera devolvia 0. Byte-completo no es recuperable. (Adversario, ronda 3.)
fixture
emit --type pendiente.update --id "$ID" --text "$NUEVO" >/dev/null
compact --quiet >/dev/null
python3 - "$M" "$ID" <<'PYEOF'
import json, os, sys, time
mem, pid = sys.argv[1], sys.argv[2]
d = os.path.join(mem, ".journal", "pending"); os.makedirs(d, exist_ok=True)
# El MISMO texto de nacimiento, pero con un tabulador y un salto crudos metidos dentro. El hash
# sigue casando porque journal-emit.pendiente_id normaliza antes de hashear: el evento pasa el
# guard de coherencia y llega al log, que es justo el camino que el adversario recorrio.
texto = "comprobar el 2026-09-20\tque 7 code maps\nsalieron del codigo actual"
ev = {"v": 1, "type": "pendiente.add", "ts": time.time_ns(), "session_id": "s", "agent_id": "a",
      "payload": {"id": pid, "text": texto, "prioridad": "Media",
                  "origen": "[[sessions/2026-09-19-demo]]", "creado": "2026-09-12", "revisar": ""}}
open(os.path.join(d, "9998-crudo.json"), "w", encoding="utf-8").write(json.dumps(ev))
PYEOF
compact --quiet >/dev/null 2>&1
L="$M/.journal/adds-descartados.log"
chk "el registro ocupa UNA sola linea" "1" "$(wc -l < "$L" | tr -d ' ')"
chk "el principio del texto se recupera con grep" "1" "$(grep -c 'comprobar el 2026-09-20' "$L")"
chk "y el FINAL tambien (no quedo huerfano en otra linea)" "1" "$(grep -c 'salieron del codigo actual' "$L")"
chk "el tabulador quedo escapado, no crudo" "1" "$(grep -Fc 'el 2026-09-20\tque 7' "$L")"
chk "la linea tiene las 6 columnas del formato" "6" "$(head -1 "$L" | awk -F'\t' '{print NF}')"

echo "== 25. el escapado es REVERSIBLE y el log de avisos tambien es de una linea =="
# Dos cosas que la ronda 4 rompio. (1) Mandar `\r`, `\n` y `\r\n` los tres al mismo `\n` deja el
# registro en una linea pero ya no permite reconstruir el original: media promesa. (2) `campo_log`
# arreglaba los logs de CAMPOS y dejaba el otro escritor de lineas, `log()`, cuyos mensajes
# interpolan valores que vienen del evento (el motivo de una cuarentena lleva la prioridad tal
# como llego).
R=$(python3 -c "
import importlib.util, sys
sp = importlib.util.spec_from_file_location('jc', sys.argv[1] + '/journal-compact.py')
m = importlib.util.module_from_spec(sp); sp.loader.exec_module(m)
vals = [m.campo_log(v) for v in ('a\rb', 'a\nb', 'a\r\nb')]
print('DISTINTOS' if len(set(vals)) == 3 else 'COLISION')
print('SIN-CRUDOS' if not any(c in ''.join(vals) for c in '\r\n') else 'CON-CRUDOS')
" "$BIN")
chk "\\r, \\n y \\r\\n salen distintos" "DISTINTOS" "$(printf '%s' "$R" | sed -n 1p)"
chk "y ninguno deja el caracter crudo" "SIN-CRUDOS" "$(printf '%s' "$R" | sed -n 2p)"
# Un evento con un salto crudo en un valor que el motivo de cuarentena interpola.
fixture
python3 - "$M" "$ID" <<'PYEOF'
import json, os, sys, time
mem, pid = sys.argv[1], sys.argv[2]
d = os.path.join(mem, ".journal", "pending"); os.makedirs(d, exist_ok=True)
ev = {"v": 1, "type": "pendiente.update", "ts": time.time_ns(), "session_id": "s", "agent_id": "a",
      "payload": {"id": pid, "text": "", "prioridad": "Alta\nINYECTADO", "fecha": "2026-09-19"}}
open(os.path.join(d, "9997-multilinea.json"), "w", encoding="utf-8").write(json.dumps(ev))
PYEOF
compact --quiet --log "$M/.journal/compact.log" >/dev/null 2>&1 || true
chk "el aviso de cuarentena ocupa una sola linea" "1" "$(grep -c 'prioridad' "$M/.journal/compact.log")"
chk "y el salto quedo escapado, no partio el registro" "0" "$(grep -c '^INYECTADO' "$M/.journal/compact.log")"

echo "== 26. REPLAY del mismo evento: noop, NO cuarentena (arreglo de 2.31.0) =="
# El guardian --text-prefix corria ANTES de mirar si la linea ya estaba corregida, y el prefijo se
# captura en la EMISION (texto viejo). En un replay la linea ya tiene el texto nuevo, asi que el
# prefijo no casa POR CONSTRUCCION: el replay acababa en cuarentena, con un motivo ademas falso
# ("otra sesion la cambio" — no hubo otra sesion). Contradecia la cabecera del compactador ("un
# replay de evento ya aplicado se archiva"). Medido 2026-09-19 con este mismo fixture.
fixture
emit --type pendiente.update --id "$ID" --text "$NUEVO" >/dev/null
compact --quiet >/dev/null
cp "$M"/.journal/applied/*/*.json "$M"/.journal/pending/
OUT=$(compact)
chk "el replay NO cuarentena" "0" "$(cuarentena)"
chk "el replay cuenta como noop" "1" "$(printf '%s' "$OUT" | grep -c 'noop=')"
chk "la linea sigue con el texto corregido, una sola vez" "1" "$(printf '%s' "$(linea "$ID")" | grep -c 'unir el PR #214')"
chk "y conserva su id de nacimiento" "1" "$(printf '%s' "$(linea "$ID")" | grep -c "_id: ${ID}_")"

echo
echo "pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
