---
importance: 7
---
# Shell y portabilidad

1. **`timeout` no existe en macOS** — un script que lo usa falla en la Mac del usuario aunque pase en Linux; lanza el proceso en segundo plano o usa un tope propio.
2. **`sed -i` no es igual en BSD y GNU** — en macOS necesita un argumento de sufijo (`sed -i ''`); en Linux no lo acepta separado.
3. **`bc` no está en el Git Bash de Windows** — la aritmética de punto flotante en un test rompe solo en windows-latest.
4. **Windows ignora el `TZ` que le pases desde Git Bash** — ni nombres IANA ni reglas POSIX; un test que depende del huso da otro resultado.
5. **Un glob sin coincidencias aborta el script con nullglob o queda literal sin él** — no uses globs en snippets que un agente copia y ejecuta.
6. **Git Bash convierte a rutas de Windows los argumentos y variables, no el texto dentro de un JSON** — una ruta `/tmp/...` escrita dentro de un JSON no la encuentra el python de Windows.
7. **`chmod 000` no impide leer en Windows** — un test que simula un fichero ilegible así pasa en Unix y falla en Windows.
8. **Python en Windows escribe en la página de códigos local, no en UTF-8** — fuerza `reconfigure(encoding="utf-8")` en stdout y stderr de cada script.
9. **`open()` sin `encoding` usa la codificación local** — en Windows rompe con acentos; ponlo siempre, también en los tests.
10. **Un `while pgrep -f patrón` por SSH no termina nunca** — el propio ssh lleva el patrón en su línea de comandos y se encuentra a sí mismo.
11. **Un heredoc con comillas simples desbalanceadas rompe el bloque entero en silencio** — un apóstrofe dentro de un texto en inglés basta.
12. **`set -e` no salta dentro de una condición** — un comando que falla dentro de un `if` o de un `&&` no detiene el script.
13. **Los permisos de ejecución no viajan igual en todos los checkouts** — invoca los scripts con `bash script.sh`, no con `./script.sh`.
14. **`echo -e` no es portable** — usa `printf` para secuencias de escape.
15. **`readlink -f` no existe en el macOS antiguo** — resuelve rutas con `cd "$(dirname ...)" && pwd`.
16. **Una variable sin comillas se parte en los espacios** — una ruta con espacios llega como dos argumentos.
17. **En la Mac no hay `timeout`: el comando del adversario falla al arrancar** — lanzarlo en segundo plano con su propio tope.
