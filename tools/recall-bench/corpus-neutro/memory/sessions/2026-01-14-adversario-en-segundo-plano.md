---
type: session
date: 2026-01-14
status: completed
importance: 6
---
# Verificación con un adversario externo

## Contexto
Revisión de un cambio de hooks con un revisor externo antes del push.

## Callejones sin salida
- `timeout 7200` delante del comando del adversario → no existe en macOS (la regla 1 de [[learnings/shell-y-portabilidad]] ya lo decía) → lanzarlo en segundo plano.
- Esperar al revisor con `while pgrep -f revisor` por SSH → el bucle no terminaba nunca; la regla 10 de [[learnings/shell-y-portabilidad]] ya estaba escrita → timeout remoto y patrón anclado a la ruta del binario.
- Editar el fichero mientras el revisor seguía corriendo → el veredicto describía un árbol que ya no existía (regla 8 de [[learnings/proceso-del-agente]] ya escrita) → congelar el árbol antes de verificar.
- Hacer commit en el clon mientras corría la revisión automática → la ronda abortó sin veredicto y se perdió entera; la regla 3 de [[learnings/git-y-ci]] ya lo decía → esperar a que termine.
