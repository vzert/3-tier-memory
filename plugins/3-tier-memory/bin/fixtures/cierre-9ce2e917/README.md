# Fixture: snippet viejo tras cerrar un pendiente (sesion 9ce2e917, 2026-09-22/23)

Texto extraido tal cual del JSONL de esa sesion (p-c72a33ae7a). Solo se cambio la ruta del home
del usuario por `/home/usuario/`.

| Fichero | Que es |
|---|---|
| `snippet-antes-del-push.txt` | el snippet que el usuario tenia, con `p-477bb60303` (el push) en `Sigue abierto` |
| `comando-resolve.txt` | el comando real que resolvio `p-477bb60303` despues del checkpoint |
| `respuesta-tras-el-push.txt` | la respuesta real de ese turno: no reimprime el snippet |

Lo usa `test-checkpoint-close-guard.sh` ("caso REAL").
