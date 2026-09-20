#!/bin/bash
# Prueba de `learning.update` (journal-emit.py + journal-compact.py).
#
# Por que existe este evento: un learning vive en TRES superficies y las tres envejecen — el
# bullet del cuerpo de learnings/<topic>.md, la fila de resumen de '## Topic Files' y la regla
# numerada del '## Quick Reference'. `learning.add` solo ANADE. Hasta 2.31.0, corregir una regla
# vencida obligaba a emitir otra NUEVA que dijera "la anterior no vale": el indice quedaba mal Y
# anotado, y el recall devolvia las dos. Con journal_strict=1 tampoco se podia a mano.
#
# Las dos propiedades que este fichero vigila y que NO son la edicion en si (que es la parte facil):
#
# 1. EL NUMERO SE CONSERVA. Las reglas se citan por numero, asi que renumerar rompe esas citas —
#    el mismo dano que renombrar el `_id:` de un pendiente, que es justo el motivo por el que
#    existe `pendiente.update`. Medido con corpus y comando declarados (una cifra sin corpus no la
#    pudo reproducir un adversario externo):
#      grep -roiE "\b(learning|regla|rule)s? [0-9]{1,3}\b" plugins/ \
#        --include='*.py' --include='*.sh' --include='*.md' | wc -l
#    -> 37 en plugins/ (lo que se publica); 118 anadiendo memory/. Casos 1, 2 y 9.
#
# 2. UN REPLAY ES NOOP, NO CUARENTENA. El ancla de un learning es el texto de HOY (no tiene id),
#    asi que en un replay el prefijo viejo no casa POR CONSTRUCCION. Si el guardian de prefijo
#    corre antes de mirar si ya esta corregida, TODO replay acaba en cuarentena — que es el defecto
#    medido en `pendiente.update` el 2026-09-19 y corregido en esta misma version. Caso 5.
set -e
BIN="$(cd "$(dirname "$0")" && pwd)"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
pass=0; fail=0
chk() { if [ "$2" = "$3" ]; then pass=$((pass+1)); echo "  ok  $1"; else fail=$((fail+1)); echo "  FALLA $1: esperaba '$2', salio '$3'"; fi; }
has() { if printf '%s' "$2" | grep -q "$3"; then pass=$((pass+1)); echo "  ok  $1"; else fail=$((fail+1)); echo "  FALLA $1: no encontre '$3' en '$2'"; fi; }

M="$T/memory"
emit() { python3 "$BIN/journal-emit.py" --memory-dir "$M" "$@"; }
compact() { python3 "$BIN/journal-compact.py" --memory-dir "$M" "$@"; }
cuar() { ls "$M/.journal/quarantine" 2>/dev/null | grep -c '\.json$' | tr -d ' '; }
motivo() { cat "$M/.journal/quarantine"/*.reason 2>/dev/null | tr '\n' ' '; }
cuerpo() { sed -n '/## Rules/,/## Related/p' "$M/learnings/gate-review.md"; }
qr() { sed -n '/## Quick Reference/,/## Related/p' "$M/_learnings.md"; }

fixture() {
  rm -rf "$M"; mkdir -p "$M/learnings"
  cat > "$M/_learnings.md" <<'IDX'
---
type: index
updated: 2026-01-01
---
# Learnings Index

## Topic Files

| Topic | File | When to consult |
|---|---|---|
| Gate Review | [[learnings/gate-review]] | antes de empujar |
| Otro Tema | [[learnings/otro]] | ver tambien [[learnings/gate-review]] |

## Quick Reference

1. **Primera regla** — no la toques
2. **La cita de .gitignore:134** — el harness vive ahi
3. **Tercera regla** — tampoco

## Related
IDX
  cat > "$M/learnings/gate-review.md" <<'TOP'
---
type: learnings
topic: gate-review
updated: 2026-01-01
---
# Gate Review

## Rules

1. **Algo previo** — contexto que no se toca
2. **El harness de post-merge vive en .gitignore:134** — comprobarlo antes de empujar

## Related
- [[_learnings|Learnings Index]]
TOP
  printf -- '---\ntype: learnings\ntopic: otro\n---\n# Otro\n\n## Rules\n\n## Related\n' > "$M/learnings/otro.md"
}

NUEVA="**El harness de post-merge vive en .gitignore:137** — el PR #217 metio 3 lineas"

echo "== 1. el cuerpo se corrige y el NUMERO se conserva =="
fixture
emit --type learning.update --topic gate-review \
  --match-prefix "El harness de post-merge vive en .gitignore:134" --text "$NUEVA" >/dev/null
compact --quiet >/dev/null
chk "el texto nuevo esta" "1" "$(cuerpo | grep -c 'gitignore:137')"
chk "el texto viejo ya NO esta" "0" "$(cuerpo | grep -c 'gitignore:134')"
chk "sigue siendo la regla numero 2" "1" "$(cuerpo | grep -c '^2\. \*\*El harness')"
chk "la regla vecina no se toco" "1" "$(cuerpo | grep -c '^1\. \*\*Algo previo\*\* — contexto que no se toca')"
chk "no cuarentena nada" "0" "$(cuar)"

echo "== 2. el Quick Reference se corrige conservando su numero =="
fixture
emit --type learning.update --topic gate-review \
  --quickref-prefix "La cita de .gitignore:134" --quickref "**La cita de .gitignore:137** — el harness vive ahi" >/dev/null
compact --quiet >/dev/null
chk "sigue siendo la regla 2 del Quick Reference" "1" "$(qr | grep -c '^2\. \*\*La cita de .gitignore:137')"
chk "las vecinas 1 y 3 intactas" "2" "$(qr | grep -cE '^(1\. \*\*Primera regla|3\. \*\*Tercera regla)')"
chk "el cuerpo NO se toco (superficies independientes)" "1" "$(cuerpo | grep -c 'gitignore:134')"

echo "== 3. la fila de Topic Files se corrige =="
fixture
emit --type learning.update --topic gate-review --title "Gate Review (VPS)" --when "antes de empujar al VPS" >/dev/null
compact --quiet >/dev/null
chk "titulo nuevo" "1" "$(grep -c '| Gate Review (VPS) |' "$M/_learnings.md")"
chk "when nuevo" "1" "$(grep -c 'antes de empujar al VPS' "$M/_learnings.md")"

echo "== 4. la fila se ancla a la CELDA, no a la fila entera =="
# La fila de 'Otro Tema' cita [[learnings/gate-review]] en su columna 'When to consult'. Con un
# `search` sobre la fila entera (lo que hace find_row_anywhere) el update se la lleva a ella y
# reescribe el titulo del tema equivocado. Al INSERTAR eso solo producia un duplicado; al
# REESCRIBIR corrompe una fila ajena, que es otra cosa. Defecto medido por una sesion par en el
# otro arbol y cerrado aqui con find_topic_row.
chk "la fila de 'Otro Tema' conserva su titulo" "1" "$(grep -c '| Otro Tema |' "$M/_learnings.md")"
chk "y su celda when intacta" "1" "$(grep -c 'ver tambien \[\[learnings/gate-review\]\]' "$M/_learnings.md")"

echo "== 5. REPLAY: noop, no cuarentena (el defecto que pendiente.update tenia) =="
fixture
emit --type learning.update --topic gate-review \
  --match-prefix "El harness de post-merge vive en .gitignore:134" --text "$NUEVA" >/dev/null
compact --quiet >/dev/null
cp "$M"/.journal/applied/*/*.json "$M"/.journal/pending/
OUT=$(compact)
has "el replay cuenta como noop" "$OUT" "noop=1"
chk "el replay NO cuarentena" "0" "$(cuar)"
chk "y el texto sigue siendo el corregido, una sola vez" "1" "$(cuerpo | grep -c 'gitignore:137')"

echo "== 6. prefijo que no casa: no-anchor, y el motivo LISTA las candidatas =="
# Sin la lista, un error de citado deja a la persona adivinando y la devuelve al workaround que
# este evento existe para matar.
fixture
emit --type learning.update --topic gate-review --match-prefix "una regla que no existe" --text "$NUEVA" >/dev/null
compact --quiet >/dev/null 2>&1 || true
chk "cuarentena 1" "1" "$(cuar)"
has "motivo no-anchor" "$(motivo)" "no-anchor"
has "el motivo nombra las reglas que SI hay" "$(motivo)" "Algo previo"
chk "el fichero no se toco" "1" "$(cuerpo | grep -c 'gitignore:134')"

echo "== 7. prefijo ambiguo: cuarentena, no escribe a medias =="
fixture
# Dentro de '## Rules': `>>` lo pondria tras '## Related', fuera de la region del cuerpo, y
# entonces no habria ambiguedad que detectar — el fixture probaria otra cosa.
python3 - "$M/learnings/gate-review.md" <<'INS'
import sys
p = sys.argv[1]
l = open(p).read().split("\n")
i = l.index("## Related")
l.insert(i - 1, "3. **El harness de post-merge vive en .gitignore:999** - duplicado a proposito")
open(p, "w").write("\n".join(l))
INS
emit --type learning.update --topic gate-review \
  --match-prefix "El harness de post-merge vive en .gitignore:" --text "$NUEVA" >/dev/null
compact --quiet >/dev/null 2>&1 || true
chk "cuarentena 1" "1" "$(cuar)"
has "motivo ambiguous" "$(motivo)" "ambiguous"
chk "ninguna de las dos se reescribio" "0" "$(grep -c 'gitignore:137' "$M/learnings/gate-review.md")"

echo "== 8. el prefijo casa aunque se cite SIN el enfasis markdown =="
# Una regla se escribe `**Titulo** — detalle`. Exigir el prefijo con sus asteriscos convierte el
# evento en una trampa de citado; el prefijo se compara con plain().
fixture
emit --type learning.update --topic gate-review \
  --match-prefix "el harness DE POST-MERGE vive" --text "$NUEVA" >/dev/null
compact --quiet >/dev/null
chk "caso y enfasis no importan en el ancla" "1" "$(cuerpo | grep -c 'gitignore:137')"
chk "sin cuarentena" "0" "$(cuar)"

echo "== 9. un cambio que SOLO anade enfasis se aplica (no se lee como replay) =="
# La igualdad se mide con normalize_text (exacta), no con plain(): si se midiera con plain(),
# ponerle negrita a una regla se leeria como "ya esta corregida" y se perderia en silencio.
fixture
emit --type learning.update --topic gate-review \
  --match-prefix "Algo previo" --text "**Algo previo** — **contexto** que no se toca" >/dev/null
compact --quiet >/dev/null
chk "el enfasis nuevo se escribio" "1" "$(cuerpo | grep -c '\*\*contexto\*\*')"
chk "y sigue siendo la regla 1" "1" "$(cuerpo | grep -c '^1\. \*\*Algo previo')"

echo "== 10. la emision rechaza lo que no se puede anclar =="
fixture
O=$(emit --type learning.update --topic gate-review --text "$NUEVA" 2>&1 || true)
has "--text sin --match-prefix se rechaza" "$O" "necesita --match-prefix"
O=$(emit --type learning.update --topic gate-review --quickref "x" 2>&1 || true)
has "--quickref sin --quickref-prefix se rechaza" "$O" "necesita --quickref-prefix"
O=$(emit --type learning.update --topic gate-review 2>&1 || true)
has "sin nada que corregir se rechaza" "$O" "al menos uno"
chk "y no se escribio ningun evento" "0" "$(ls "$M/.journal/pending" 2>/dev/null | grep -c json)"

echo "== 11. el compactador es su propia frontera de confianza (learning 106) =="
# journal-emit ya rechaza el caso 10, pero un evento puede venir escrito a mano o de otro emisor.
fixture
mkdir -p "$M/.journal/pending"
printf '{"v":1,"type":"learning.update","ts":1,"payload":{"topic":"gate-review","text":"x"}}\n' > "$M/.journal/pending/mano.json"
compact --quiet >/dev/null 2>&1 || true
chk "un evento a mano sin match_prefix cae en cuarentena" "1" "$(cuar)"
has "y el motivo lo nombra" "$(motivo)" "match_prefix"

echo "== 12. sobre un topic que no existe, no-anchor con motivo util =="
fixture
emit --type learning.update --topic inexistente --match-prefix "algo" --text "$NUEVA" >/dev/null
compact --quiet >/dev/null 2>&1 || true
chk "cuarentena 1" "1" "$(cuar)"
has "el motivo dice que learning.update no CREA" "$(motivo)" "no la crea"

echo "== 13. otra regla ya tiene el texto destino: la del prefijo SE CORRIGE igual =="
# Lo rompio un adversario externo. La version anterior recorria la region buscando CUALQUIER regla
# igual al texto nuevo y, si la encontraba, declaraba replay y no tocaba nada. Con dos reglas
# distintas donde una ya dice lo que la otra debe decir, la vencida se quedaba sin corregir EN
# SILENCIO — perder una correccion legitima es justo el fallo que este evento existe para cerrar.
# Ahora se resuelve primero por el prefijo (el ancla que el emisor eligio) y la igualdad global
# solo decide cuando el prefijo no casa nada, que es el replay de verdad.
fixture
python3 - "$M/learnings/gate-review.md" <<'INS'
import sys
p = sys.argv[1]; l = open(p).read().split("\n"); i = l.index("## Related")
l.insert(i - 1, "3. **El destino** - este texto ya existe en el fichero")
open(p, "w").write("\n".join(l))
INS
emit --type learning.update --topic gate-review \
  --match-prefix "El harness de post-merge vive en .gitignore:134" \
  --text "**El destino** - este texto ya existe en el fichero" >/dev/null
compact --quiet >/dev/null
chk "la regla 2 (la del prefijo) SI se corrigio" "1" "$(cuerpo | grep -c '^2\. \*\*El destino\*\*')"
chk "la vencida ya no esta" "0" "$(cuerpo | grep -c 'gitignore:134')"
chk "sin cuarentena" "0" "$(cuar)"

echo "== 14. la vineta se conserva: un fichero de '*' no se convierte a '-' =="
fixture
printf -- '---\ntype: learnings\ntopic: bullets\n---\n# B\n\n## Rules\n\n* **Regla con asterisco** - texto viejo\n\n## Related\n' > "$M/learnings/bullets.md"
emit --type learning.update --topic bullets --match-prefix "Regla con asterisco" \
  --text "**Regla con asterisco** - texto nuevo" >/dev/null
compact --quiet >/dev/null
chk "sigue siendo '*', no '-'" "1" "$(grep -c '^\* \*\*Regla con asterisco\*\* - texto nuevo' "$M/learnings/bullets.md")"
chk "no aparecio una vineta '-'" "0" "$(grep -c '^- \*\*Regla con asterisco' "$M/learnings/bullets.md")"

echo "== 15. regla multilinea: SE NIEGA, no la toca =="
# Dos versiones anteriores intentaron reescribirla y dos adversarios distintos las rompieron: la
# primera dejaba las continuaciones viejas colgando bajo el texto nuevo; la segunda sustituia el
# bloque decidiendo por sangria y se cortaba antes de tiempo en una sublista. Lo que cierra el
# problema no es un parser mejor, es el alcance: medido, 0 de 247 reglas del corpus real tienen
# continuaciones, asi que negarse cuesta cero casos de verdad.
fixture
printf -- '---\ntype: learnings\ntopic: multi\n---\n# M\n\n## Rules\n\n1. **Regla larga** - primera linea\n   continuacion que le pertenece\n\n## Related\n' > "$M/learnings/multi.md"
ANTES=$(cat "$M/learnings/multi.md")
emit --type learning.update --topic multi --match-prefix "Regla larga" \
  --text "**Regla larga** - texto nuevo entero" >/dev/null
compact --quiet >/dev/null 2>&1 || true
chk "cuarentena 1" "1" "$(cuar)"
has "motivo bloque-multilinea" "$(motivo)" "bloque-multilinea"
has "el motivo dice que hacer" "$(motivo)" "a mano"
chk "el fichero no se toco EN ABSOLUTO" "$ANTES" "$(cat "$M/learnings/multi.md")"

echo "== 16. sublista indentada: tambien se niega =="
fixture
printf -- '---\ntype: learnings\ntopic: sub\n---\n# S\n\n## Rules\n\n1. **Regla con sublista** - cabecera\n   - punto uno\n2. **La vecina** - no se toca\n\n## Related\n' > "$M/learnings/sub.md"
ANTES=$(cat "$M/learnings/sub.md")
emit --type learning.update --topic sub --match-prefix "Regla con sublista" --text "**Regla con sublista** - nueva" >/dev/null
compact --quiet >/dev/null 2>&1 || true
chk "cuarentena 1" "1" "$(cuar)"
chk "el fichero intacto, la vecina incluida" "$ANTES" "$(cat "$M/learnings/sub.md")"

echo "== 17. bloque de codigo con una linea tipo lista: el caso que rompia EN SILENCIO =="
# Un adversario en otro modelo lo reprodujo: la valla de apertura se tragaba como continuacion,
# pero la linea `- item` de dentro (sangria 0) casaba la regex de vineta y cortaba el bloque ahi.
# La valla de CIERRE quedaba huerfana y el markdown roto. Y no avisaba, porque no se absorbia
# ninguna linea y el aviso iba atado a "absorbi N". Silencio + fichero roto es el peor par posible.
fixture
printf -- '---\ntype: learnings\ntopic: fence\n---\n# F\n\n## Rules\n\n1. **Regla con codigo** - cabecera\n```\n- item dentro del bloque\n```\n2. **La vecina** - no se toca\n\n## Related\n' > "$M/learnings/fence.md"
ANTES=$(cat "$M/learnings/fence.md")
emit --type learning.update --topic fence --match-prefix "Regla con codigo" --text "**Regla con codigo** - nueva" >/dev/null
compact --quiet >/dev/null 2>&1 || true
chk "cuarentena 1" "1" "$(cuar)"
has "motivo bloque-multilinea" "$(motivo)" "bloque-multilinea"
chk "el fichero intacto byte a byte" "$ANTES" "$(cat "$M/learnings/fence.md")"
chk "las dos vallas siguen ahi" "2" "$(grep -c '^```' "$M/learnings/fence.md")"

echo "== 18. sangria con TABULADOR: tambien se niega =="
# La sangria se medía en CARACTERES. Un tabulador es 1 caracter y varias columnas, asi que una
# sublista indentada con tabulador bajo una regla indentada con espacios salia "menos indentada"
# que su padre, pasaba por regla hermana, y la regla se reescribia dejando la sublista vieja
# pegada — sin cuarentena y sin aviso. Ahora se mide en COLUMNAS (expandtabs).
# (Adversario externo, 4a ronda, con el caso ['    1. parent', '\t- child'].)
fixture
printf -- '---\ntype: learnings\ntopic: tabs\n---\n# T\n\n## Rules\n\n    1. **Regla indentada** - cabecera\n\t- sublista con tabulador\n\n## Related\n' > "$M/learnings/tabs.md"
ANTES=$(cat "$M/learnings/tabs.md")
emit --type learning.update --topic tabs --match-prefix "Regla indentada" --text "**Regla indentada** - nueva" >/dev/null
compact --quiet >/dev/null 2>&1 || true
chk "cuarentena 1" "1" "$(cuar)"
has "motivo bloque-multilinea" "$(motivo)" "bloque-multilinea"
chk "el fichero intacto byte a byte" "$ANTES" "$(cat "$M/learnings/tabs.md")"

echo "== 19. sangria mixta: la propiedad, no unos ejemplos =="
# Tres versiones se rompieron aqui y las tres respondian a una pregunta mas facil que la de verdad:
# contar caracteres, contar columnas con una anchura fija, y MUESTREAR unas anchuras. La tercera
# parecia bien y fallaba igual: '  \t ' contra '   \t' coincide a anchura 1,2,4,8 y discrepa a 3.
# Un sondeo no puede cerrar un "para todo", asi que la funcion lo DECIDE (sangrias identicas, o sin
# ningun tabulador; cualquier otra cosa se niega). Este caso comprueba la PROPIEDAD por fuerza
# bruta, no una lista de ejemplos: ninguna escritura puede depender de cuanto mida un tabulador.
R=$(python3 - "$BIN/journal-compact.py" <<'BRUTO'
import importlib.util, sys, itertools
spec = importlib.util.spec_from_file_location('jc', sys.argv[1])
m = importlib.util.module_from_spec(spec); sys.argv = ['x']; spec.loader.exec_module(m)
ws = [''.join(c) for n in range(6) for c in itertools.product(' \t', repeat=n)]
malos = escrituras = 0
for wa in ws:
    for wb in ws:
        L = ['x', f"{wa}1. p", f"{wb}- c"]
        try:
            m.rewrite_rule(L, 1, len(L), 'NUEVO', 'd')
        except m.Quarantine:
            continue
        escrituras += 1
        # Escribio: entonces "el hijo no esta mas adentro" tiene que ser cierto con CUALQUIER
        # anchura de tabulador, porque el formato no fija ninguna.
        vistas = {len(wb.expandtabs(w)) <= len(wa.expandtabs(w)) for w in range(1, 33)}
        if len(vistas) != 1 or not vistas.pop():
            malos += 1
print(f"{escrituras} {malos}")
BRUTO
)
chk "hay escrituras legitimas (el guardian no lo bloquea todo)" "1" "$([ "${R% *}" -gt 0 ] && echo 1 || echo 0)"
chk "ninguna escritura depende de la anchura del tabulador" "0" "${R#* }"

echo "== 20. los dos casos exactos con que se rompio la version anterior =="
fixture
printf -- '---\ntype: learnings\ntopic: mix\n---\n# X\n\n## Rules\n\n    \t- **Regla mixta** - cabecera\n\t - hijo con sangria mixta\n\n## Related\n' > "$M/learnings/mix.md"
ANTES=$(cat "$M/learnings/mix.md")
emit --type learning.update --topic mix --match-prefix "Regla mixta" --text "**Regla mixta** - nueva" >/dev/null
compact --quiet >/dev/null 2>&1 || true
chk "cuarentena 1" "1" "$(cuar)"
chk "el fichero intacto byte a byte" "$ANTES" "$(cat "$M/learnings/mix.md")"

echo "== 21. el replay por igualdad global AVISA, no es mudo =="
fixture
emit --type learning.update --topic gate-review \
  --match-prefix "un prefijo que no casa nada" \
  --text "**Algo previo** — contexto que no se toca" >/dev/null
compact --log "$M/.journal/c.log" --quiet >/dev/null 2>&1 || true
chk "no cuarentena (es un replay plausible)" "0" "$(cuar)"
has "pero lo dice en el log" "$(cat "$M/.journal/c.log" 2>/dev/null)" "se toma como replay"
chk "y no escribio nada" "1" "$(cuerpo | grep -c 'gitignore:134')"

echo
echo "pass=$pass fail=$fail"
[ "$fail" = 0 ]
