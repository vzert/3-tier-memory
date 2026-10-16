Caso real (2026-10-15, un proyecto que usa el plugin): el hilo transitivo de 2.57.0 llevo una sesion
de indices, en 7 saltos de `_relacionado`, a la sombrilla de un trabajo que llevaba otro agente.
`_pendientes.md` conserva la forma del grafo (prioridad, `_relacionado`, `_revisar`, `_bloqueado`,
`_origen`); ids, fichas y textos son inventados. Lo usa test-hilo-pendientes.sh, seccion 8.
