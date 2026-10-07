# Guía: escribir disparadores para una regla

(La lee cada subagente escritor de `/migrate-learnings-3t`, Step 4. No es un comando.)

Una regla de memoria la tiene que encontrar un agente que NO la conoce, en el momento en que va a
cometer el error que la regla evita. El buscador es léxico: compara palabras exactas, sin
sinónimos y sin raíces ("commit" y "commitear" son palabras distintas; "abortó" y "aborto"
también). Tu trabajo: escribir como hablaría ese agente en ese momento, para que sus palabras
estén en la regla.

## Qué escribes por regla

- `frases`: 3 a 6 frases. Cada una describe la SITUACIÓN en la que la regla aplica, como la diría
  alguien que no conoce la regla: lo que está a punto de hacer (la intención), el síntoma que ve,
  o la pregunta que se hace. Primera persona o impersonal, lenguaje de trabajo diario.
  - Escribe en el idioma en que están escritas las reglas del proyecto (míralo en `texto`).
  - Varía el vocabulario: verbos coloquiales ("subir", "pushear", "mandar"), el nombre de la
    herramienta o comando, el síntoma visible ("se cuelga", "sale vacío", "da 403").
  - Escribe con la ortografía normal, con sus acentos ("terminé", "qué pasó", "revisión"): quien
    escribe el prompt los pone, y una palabra con acento no casa con la misma palabra sin él.
  - Varía la forma del verbo de la acción clave entre frases: infinitivo, presente, "voy a",
    gerundio y pasado ("hacer", "hago", "voy a hacer", "estoy haciendo", "hice"). El buscador no
    une formas de un mismo verbo; cada forma que no escribas es una forma que no encuentra la regla.
  - Mezcla español e inglés si el proyecto los mezcla. Cuando la acción clave tiene un nombre en
    inglés de uso común, usa en las frases la palabra inglesa, su forma adaptada tal como se
    escribe en el día a día (con sus variantes de ortografía) y el término propio del idioma.
  - Cada frase entre 4 y 20 palabras.
- `cmd`: prefijos de comando normalizados a los que aplica la regla (`git push`, `rm -rf`,
  `gh workflow run`). Solo si la regla habla de comandos concretos. Si no, lista vacía.
- `path`: globs relativos al proyecto de los ficheros que toca la situación (`.github/workflows/*`,
  `memory/learnings/*.md`). Solo si la regla los nombra. Si no, lista vacía.
- `tool`: nombres de herramienta del agente (`Bash`, `Edit`, `Write`, `Agent`...). Solo si la regla
  se refiere a una acción con esa herramienta. Si no, lista vacía.

No inventes comandos, rutas ni herramientas que la regla no sugiere.

## Frase buena y frase mala

Regla de ejemplo (inventada): **No borres un worktree con cambios sin publicar** — `git worktree
remove --force` tira commits que no están en ningún remoto.

- MALA: "no borrar un worktree con cambios sin publicar" — repite el título; quien va a cometer el
  error no piensa en la lección, piensa en lo que quiere hacer.
- MALA: "gestión de worktrees" — abstracta, sin el momento.
- BUENA: "ya terminé la rama, limpio la carpeta del worktree"
- BUENA: "voy a quitar el worktree viejo aunque git se queja de cambios"
- BUENA: "estoy haciendo cleanup de worktrees antes de seguir"
- BUENA: "quité el worktree con force y desaparecieron los commits"

Regla de ejemplo (inventada): **Un `grep -c` que sale 1 no es error** — sale 1 cuando cuenta 0, y
`set -e` mata el script.

- MALA: "grep -c sale 1 no es error"
- BUENA: "el script muere en silencio después del conteo"
- BUENA: "con set -e el script se para al contar líneas"
- BUENA: "estoy contando matches con grep y el script se corta"
- BUENA: "why does my bash script exit when nothing matches"

## Reglas del encargo

- Lee SOLO: este fichero y tu fichero de lote. No leas nada más del disco: ni otros ficheros de
  `memory/`, ni salidas de otros escritores.
- Cada fila del lote trae `id`, `match_prefix`, `texto` (la regla) y `vecinos`: los títulos de las
  reglas más parecidas del mismo topic. Usa los vecinos para que tus frases describan lo PROPIO de
  esta regla y no la situación de la vecina.
- Una regla larga o de contexto (una decisión de diseño, un hecho medido) también tiene un momento
  en el que importa: la pregunta que alguien se haría antes de repetir la decisión.
- Escribe una fila por regla, en el mismo orden, en tu fichero de salida, como JSONL, copiando
  `id` y `match_prefix` tal cual vienen:
  `{"id": "<topic#N>", "match_prefix": "<igual que en el lote>", "frases": [...], "cmd": [...], "path": [...], "tool": [...]}`
- Sin `;`, `|`, `=`, `<`, `>` ni `--` dentro de una frase o un valor (son separadores del
  formato, o cortarían el comentario HTML). Los comandos van en `cmd`, no en las frases, salvo su
  nombre suelto ("git commit").
- Al terminar, responde con la ruta de tu fichero de salida, cuántas filas escribiste y la lista
  exacta de ficheros que leíste.
