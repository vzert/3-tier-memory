---
type: session
date: 2026-01-10
status: completed
importance: 6
---
# Publicar una versión y seguir el CI

## Contexto
Publicación de una versión menor del plugin con un arreglo en los tests.

## Callejones sin salida
- Cerrar la sesión diciendo "publicado" sin mirar el CI → windows-latest seguía en rojo desde hacía cuatro pushes (la regla 1 de [[learnings/git-y-ci]] ya lo decía) → mirar el CI después de cada push.
- Aritmética con `bc` en el test nuevo → el Git Bash de Windows no trae `bc` (regla 3 de [[learnings/shell-y-portabilidad]] ya escrita) → aritmética entera de bash.
- Leer un commit viejo con `git show` desde un test → en el CI el checkout es de un solo commit (regla 2 de [[learnings/git-y-ci]] ya existía) → `fetch-depth: 0`.
- Hacer push sin subir la versión del plugin → ninguna instalación recibió el arreglo; la regla 5 de [[learnings/git-y-ci]] ya lo decía → subir la versión en cada push.
