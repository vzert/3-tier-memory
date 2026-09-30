---
importance: 8
---
# Git y CI

1. **Mira el CI después de cada push, no esperes al correo** — una plataforma puede quedarse en rojo varios pushes seguidos mientras cada sesión cierra diciendo "publicado".
2. **Un checkout superficial no tiene la historia** — `actions/checkout` trae un solo commit por defecto; un test que lee un commit anterior con `git show` necesita `fetch-depth: 0`.
3. **Nunca hagas commit en un clon mientras un revisor automático corre sobre él** — la revisión se aborta si el árbol se mueve a mitad y se pierde la ronda entera.
4. **Commitea antes de lanzar la revisión** — la revisión mira el HEAD, no el árbol de trabajo; lo que no está commiteado no se revisa.
5. **Sube la versión en cada push de un plugin** — el cliente usa la versión como llave de caché; misma versión significa que nadie recibe el cambio.
6. **Un fichero ignorado por .gitignore puede seguir trackeado** — se publica en cada push; compruébalo con `git ls-files | git check-ignore --no-index --stdin`.
7. **`git config` dentro de un worktree escribe el config compartido del repo** — cambia la identidad de todos los que usan ese repo, no solo la del worktree.
8. **Un hash no puede contener su propio hash** — grabar el hash de un commit y amendear para incluirlo produce otro hash; se graba como referencia hacia adelante.
9. **Rebase interactivo no funciona sin terminal** — en un agente, usa rebase no interactivo o commits nuevos.
10. **Un force-push a main borra trabajo de otros** — antes de reescribir historia compartida, pregunta.
11. **El mensaje de commit de otra cuenta queda para siempre** — un fichero temporal de mensaje reutilizado mete el texto de otra sesión en el historial.
12. **Windows en el CI hace checkout con CRLF** — un `case` exacto sobre texto leído conserva el `\r` final donde un `grep` de subcadena no fallaba.
13. **Una rama de medición en el CI se borra después** — sirve para medir otra plataforma sin tener la máquina.
14. **Los tags de versión se crean después del merge, no antes** — un tag sobre un commit que no llegó a main apunta a nada publicado.
15. **Un required check rojo bloquea el merge de todos** — arreglarlo va antes que cualquier otra tarea del repo.
16. **`git stash` no guarda los ficheros sin trackear por defecto** — usa `-u` o se pierden al cambiar de rama.
17. **No comitear en el clon con la revisión corriendo: la ronda aborta sin veredicto** — el árbol movido invalida la revisión; espera a que termine.
