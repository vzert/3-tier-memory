# Fixtures: cierres reales de la sesion 5790b9f2 (2026-09-22)

Texto extraido tal cual del JSONL de esa sesion de este repo (p-daf3051915). Solo se cambio la
ruta del home del usuario por `/home/usuario/` (un repo publico no lleva rutas reales).

| Fichero | Registro del JSONL | Forma |
|---|---|---|
| `respuesta-turno-1813.txt` | 1813, texto final del turno de /checkpoint-3t | (1) Proximo paso bloqueado por un tercero; (3) calendario solo "persistido" |
| `snippet-1813.txt` | el snippet pegado en 1813 | (1) |
| `snippet-2071.txt` | 2071 | (2) caso 4 generico con trabajo propio abierto |
| `snippet-2120.txt` | tool_result 2120 (print-como-retomar.py) | el snippet correcto que nunca llego a la respuesta |
| `respuesta-turno-2129.txt` | texto de los registros 2078-2131 | (4) snippet solo en el tool result |
| `calendario-1880.txt`, `calendario-2129.txt` | 1880, 2129 | los recordatorios tal como se imprimieron |

Los usan `test-checkpoint-audit.sh` (formas 1 y 2) y `test-checkpoint-close-guard.sh` (formas 3 y 4).
