Caso real (2026-10-15, un proyecto que usa el plugin): el hilo transitivo de 2.57.0 llevo una sesion
de indices, en 7 saltos de `_relacionado`, a la sombrilla de un trabajo que llevaba otro agente.
`_pendientes.md` conserva la forma del grafo (prioridad, `_relacionado`, `_revisar`, `_bloqueado`,
`_origen`); ids, fichas y textos son inventados. Los `_revisar` (del 2026-10-15 al 29 en el caso)
van en 9999-12-31 para que la prueba no dependa de la fecha real: con `--hoy 2026-10-15` siguen
siendo futuros, como lo eran entonces. Lo usa test-hilo-pendientes.sh, seccion 8.
