---
description: Barrido del backlog de pendientes — leer, decidir y cerrar con evidencia, por lotes
---

# /triage-3t — barrido del backlog

Sesion dedicada a vaciar el cementerio de pendientes **leyendolos**, no adivinando. El usuario
corre el comando; tu haces el barrido y **el usuario aprueba antes de que se emita nada**.

## Lo que este comando NO hace, y por que

**No cierra nada automaticamente.** Tres mecanismos se midieron en este proyecto y los tres
fallaron, siempre por lo mismo — el item no trae el dato que el cierre necesita:

| mecanismo | resultado medido |
|---|---|
| cerrar por silencio (M2) | precision **8.6%**, 23 cierres de items que pedian consultar un dato |
| ejecutar el comando del item (M6) | cobertura **0 de 78** |
| caducar por edad (N=90) | **29 de 30** seguian **vivos** bajo la rubrica congelada; 19 de 30 solo si se acepta un codigo posterior al resultado |

**Expectativa correcta de un barrido: la mayoria de los items viejos siguen vivos.** Si terminas
cerrando el 80% de un lote, te equivocaste. El backlog de este sistema es trabajo real sin
priorizar, no basura.

## Step 1 — Contexto y lote

**No invoques `bin/resolve-project-dir.sh`**: hace `$(cat)` para leer el stdin del hook, asi que
sin stdin se cuelga, y no imprime nada. Los dos scripts resuelven la ruta solos si omites
`--memory-dir`.

```bash
JBIN="${CLAUDE_PLUGIN_ROOT}/bin"
MEMORY_DIR="memory"   # Model B; usa la ruta de Model A si el proyecto no tiene memory/ local
python3 "$JBIN/journal-compact.py" --memory-dir "$MEMORY_DIR"     # aplicar lo que otros dejaron
python3 "$JBIN/triage-scan.py" --memory-dir "$MEMORY_DIR" --limit 25
```

`triage-scan.py` **no clasifica**: reune la evidencia. Por item da edad, origen, la ventana
`_revisar:` si la tiene, y **que sesiones POSTERIORES hablan del mismo tema**.

Esa ultima columna es la unica que separa *"ya se hizo y nadie lo marco"* de *"sigue vivo y nadie
lo ha tocado"*. Dispara en el **14-26%** de los items (medido en 4 instalaciones), asi que cuando
aparece, vale la pena abrir ese session file. **No es un veredicto**: es un puntero a que leer.

Si el usuario pidio una prioridad o un lote concreto, pasa `--prioridad Alta` o
`--desde FECHA:ID --limit N`. Sin argumentos: los 25 mas viejos.

## Step 2 — Leer cada item y clasificar

Uno por uno. **Prohibido clasificar por patron de texto** (reglas 93 y 102 de
`memory/_learnings.md`: se intento tres veces y un revisor rompio las tres). Para cada item,
**cita la frase literal que decide** — del item, de su sesion de origen, o de una posterior.

Cinco destinos:

- **resolved** — el trabajo se hizo. **Exige evidencia citada**: una sesion posterior que lo diga.
  El silencio NO es evidencia (8.6% de precision, medido). Sin cita, no es `resolved`.
- **abandoned** — ya no aplica: el objeto no existe, la decision se supero, el proyecto cambio.
  Cita que lo dejo sin efecto.
- **still-open** — sigue siendo un compromiso. **Es el destino mas comun y no es un fracaso.**
- **necesita ventana** — es una verificacion con su fecha escrita en prosa (`revisar el 2026-10-01`,
  `target ≤14d`). No se cierra: se le pone el campo. Va al Step 4b.
- **no es un compromiso** — el registro de algo ya hecho, una regla permanente disfrazada de
  pendiente, o un texto cortado a mitad. Lleva a `abandoned` con la nota de por que, y si la regla
  vale la pena, a un learning con `/save-learning`.

Si el texto no alcanza para decidir, es **still-open**. El sesgo va contra cerrar.

## Step 3 — Tabla al usuario, y esperar

Imprime la propuesta **antes de emitir nada**, con la cita que sostiene cada cierre:

```
BARRIDO — lote 1-25 de 576

  p-xxxxxxxxxx  162d  Alta   -> resolved
      "Probar /migrate en proyecto con Model A"
      evidencia: [[sessions/2026-06-21-scale-consolidation]] "migrate probado en los 3 proyectos"

  p-yyyyyyyyyy  161d  Media  -> still-open
      "Test installation en maquina limpia" — nadie lo ha hecho; sigue aplicando

  p-zzzzzzzzzz  108d  Media  -> necesita ventana 2026-10-01
      "Re-evaluar el floor despues de 3 reactivaciones (target 2026-10-01)"

RESUMEN: still-open 16 · resolved 4 · abandoned 3 · necesita ventana 2
```

**Pregunta al usuario si aplica el lote completo, parte, o ninguno.** No emitas sin respuesta.
Si el usuario aprueba con cambios, aplica los cambios, no tu propuesta.

## Step 4 — Emitir lo aprobado

**4a. Cierres** — uno por item aprobado como `resolved` / `abandoned`:

```bash
python3 "$JBIN/journal-emit.py" --type pendiente.resolve --id p-xxxxxxxxxx \
  --estado resolved|abandoned --sesion "[[sessions/DATE-SLUG]]" --nota "<la cita que lo sostiene>"
```

**4b. Ventanas** — el item se queda abierto pero gana su campo:

```bash
python3 "$JBIN/journal-emit.py" --type pendiente.window --id p-xxxxxxxxxx --revisar YYYY-MM-DD
```

**Por evento, nunca editando la linea a mano.** Con `journal_strict=1` en
`memory/.memory-config`, el hook `journal-guard.sh` deniega precisamente ese `Edit` sobre
`memory/_*.md` — o sea que la instruccion manual era inaplicable justo en la configuracion que el
plugin recomienda. Desde que el campo existe, `expire-pendientes.py --modo revisar` caduca el item
solo cuando la fecha pase.

**4c. Compactar**:

```bash
python3 "$JBIN/journal-compact.py" --memory-dir "$MEMORY_DIR"
```

Debe imprimir `quarantined=0`. Si no, abre cada `memory/.journal/quarantine/*.reason` y arreglalo
antes de seguir con el lote siguiente.

## Step 5 — Siguiente lote o cierre

`triage-scan.py` imprime el cursor del lote siguiente: **`--desde FECHA:ID`** — el par
`(_creado, _id)` del ultimo item mostrado, no una posicion. **Copialo tal cual**; el script rechaza
un id inventado o uno que ya no este abierto, en vez de saltarse items en silencio.

Nunca un `--offset` numerico: al cerrar items del lote la lista se acorta y el offset se saltaria
los que ocupan los huecos. El corte del cursor es **estricto**, asi que ni repite ni salta, tambien
cuando varios items comparten dia; los que no tienen `_creado` van al final y se alcanzan con la
clave `SIN`.

Pregunta al usuario si sigue.

Al terminar la sesion, reporta: cuantos lotes, cuantos cerrados por destino, y **cuantos siguen
abiertos** — esa ultima cifra es la util, porque es el trabajo real que queda.

Si el usuario corre `/checkpoint-3t` despues, el Step 3a no tiene que repetir este trabajo: dile
que el barrido ya reconcilio los items del lote.

## Related
- `memory/plans/plan-pendientes-diferidos-v2.13.0.md` — el plan padre (este comando es su M5)
- `memory/plans/plan-caducidad-por-edad-v2.13.0.md` — por que el cierre automatico no entra
- `bin/expire-pendientes.py` — caducidad por ventana declarada, complementaria a este barrido
