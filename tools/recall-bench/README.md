# Banco de recall

Mide si las reglas guardadas en `memory/learnings/` le llegan al agente cuando las necesita. Es la
Fase F0 del plan de ciclo de vida de learnings: cada fase siguiente tiene que mover estos números,
o no está hecha.

No sabe nada de ningún proyecto concreto. Lo concreto va en un fichero de casos.

## Qué mide

| Métrica | Qué es |
|---|---|
| `prompt@4` | Casos donde alguna regla esperada sale en el top 4 del recall (`bin/recall_rank.py`, el motor de producción) |
| `dedup@8` | Duplicados conocidos cuya regla original sale entre los 8 vecinos más parecidos de la nueva |
| `fuga` | Reglas "prohibidas" que el recall devuelve (una retirada, el segundo miembro de un duplicado) |
| `accion@2` | Recall en el momento de la acción (PreToolUse). Hoy no existe: 0 por construcción |

## Dos juegos de casos

- **`corpus-neutro/`** (publicado). Un `memory/` con 68 reglas de patrones comunes (git y CI,
  shell y portabilidad, publicación y privacidad, proceso del agente), 5 fichas de sesión y 23
  casos. Cada caso reescribe en términos generales un incidente real del desarrollo del plugin
  (`origen: neutro`, la procedencia va en `nota`). Corre en `test-bench.sh`, y por tanto en la CI.
  **Sus números son optimistas**: las reglas y las fichas las escribió la misma persona, así que
  comparten vocabulario. Sirve para detectar regresiones del motor, no para medir el recall real.
- **`casos.jsonl`** (tuyo, en `.gitignore`). Casos de tu instalación, sobre los `memory/` de tus
  proyectos. Esta es la medida real. Una fase no se da por buena solo con el corpus neutro.

## Cómo armar tus casos

1. Propón candidatos con el minador, que solo lee:

   ```bash
   python3 tools/recall-bench/minar-casos.py --proyecto ~/ruta/a/tu-proyecto --salida /tmp/candidatos.jsonl
   ```

   Busca en tus fichas de sesión las líneas donde el agente reconoce que una regla ya existía
   ("la regla 82 ya lo decía", "ya estaba documentado en [[learnings/x]]") y cita la regla. Toma la
   frase del momento del error (lo que va antes de la primera `→`). Solo encuentra lo que la ficha
   dice de forma explícita; muchos casos reales no lo dicen así.

2. Para un barrido más completo, pide a un agente que lea tus fichas con este encargo:

   > Solo lectura. En `<proyecto>/memory/sessions/*.md`, busca casos donde el agente cometió un
   > error que ya cubría una regla numerada de `<proyecto>/memory/learnings/<topic>.md`, escrita
   > ANTES del error (compruébalo con `git log` del topic file). Para cada uno: la ficha (ruta
   > absoluta), la regla (topic + número, abriendo el topic file), la frase del momento del error
   > CITADA LITERAL de la ficha (sin la lección), y la llamada de herramienta concreta si la ficha
   > la cita. Descarta los casos donde "ya estaba" se refiere a otra cosa.

3. Revisa cada candidato. Decide si es un incidente, si la regla esperada era la que aplicaba y si
   es canal `prompt` o `accion`. Quita `"revisar": true`. El banco se niega a correr mientras quede
   uno.

4. Necesitas al menos 20 casos con cita (`origen` `incidente` o `neutro`) y 5 de acción.

## Cómo correrlo

```bash
python3 tools/recall-bench/recall-bench.py                                 # tus casos
python3 tools/recall-bench/recall-bench.py --casos tools/recall-bench/corpus-neutro/casos.jsonl
python3 tools/recall-bench/recall-bench.py --comprobar-linea-base          # exige las lineas base fijadas
python3 tools/recall-bench/compare-motores.py                              # motor viejo == recall_rank.py
bash tools/recall-bench/test-bench.sh                                      # pruebas del banco
```

`--corpus-raiz` (por defecto `~/Projects`) es donde viven los proyectos cuyo `corpus` es un nombre.
Un `corpus` también puede ser una ruta a un proyecto.

## Lo que el banco no prueba

`origen`, `canal`, `esperadas` y `prohibidas` los declara quien escribe el caso. El banco comprueba
que la fuente existe, que la cita está literal en ella y que las reglas citadas existen sin
ambigüedad. No puede comprobar que el caso sea de verdad un incidente ni que la regla esperada
fuera la que aplicaba. Eso lo revisa una persona.

Nunca corras `bin/recall.sh` entero para medir otro proyecto: compacta su journal y escribe en su
`memory/`. El banco construye los índices en un directorio temporal y solo lee.
