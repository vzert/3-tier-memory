---
type: session
date: 2026-01-23
status: completed
importance: 6
---
# Un hook que avisa antes de una edición

## Contexto
Diseño de un aviso para el agente cuando edita un índice protegido.

## Callejones sin salida
- Imprimir el aviso como texto plano desde el hook PreToolUse → el modelo nunca lo vio (la regla 4 de [[learnings/proceso-del-agente]] ya lo decía) → devolver JSON con additionalContext.
- Confiar en additionalContext para frenar la edición → la edición ya había ocurrido cuando llegó el aviso; la regla 5 de [[learnings/proceso-del-agente]] ya existía → devolver deny.
- Dar por buena la prueba del hook sin haberla visto fallar → con el hook saboteado seguía en verde (regla 2 de [[learnings/proceso-del-agente]] ya escrita) → sabotear y comprobar que cae.
- Buscar con un grep las plantillas que llevaban la regla vieja → quedaron dos copias en otro directorio; la regla 6 de [[learnings/proceso-del-agente]] ya lo decía → enumerar directorios.
