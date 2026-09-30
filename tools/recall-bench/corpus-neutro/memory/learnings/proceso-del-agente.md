---
importance: 8
---
# Proceso del agente

1. **Una decisión narrada en prosa no es una decisión tomada** — cerrar un turno con "¿lo subo o lo dejo?" en texto plano deja al usuario sin forma de contestar; la decisión va en una pregunta con opciones.
2. **Un aserto que nunca se vio fallar no se ha visto funcionar** — sabotea el componente y comprueba que la prueba cae.
3. **Un arnés que acepta no-evidencia no vigila nada** — exigir código de salida 0, stderr vacío y un marcador literal.
4. **El texto plano de un hook PreToolUse no llega al modelo** — solo el JSON de additionalContext; y llega después de la llamada, no antes.
5. **Para frenar una acción antes de que ocurra, el hook devuelve deny** — additionalContext informa, no detiene.
6. **Un barrido de superficie se hace enumerando directorios, no buscando un patrón** — el patrón encuentra solo las formas que ya conocías.
7. **Cuando una regla cambia, todos sus portadores cambian** — plantillas, comandos, documentación y comentarios; enumeralos con grep antes de dar el cambio por hecho.
8. **Verificar mientras editas en paralelo da un veredicto sobre un árbol que ya no existe** — congela el árbol antes de verificar.
9. **Un revisor que corrige lo que revisa informa sobre un estado que él mismo creó** — el revisor solo lee.
10. **"Solo pasa en Windows" es una premisa que se mide** — no se razona.
11. **No declares terminado lo que solo está diagnosticado** — terminado es el objetivo cumplido y comprobado.
12. **Un pendiente cuyo único actor es un tercero es una espera, no un pendiente** — se cierra y se anota qué se espera.
13. **Juzgar por el texto de un pendiente si está bloqueado se evade con otras palabras** — usa un campo estructurado decidido al crearlo.
14. **Una cifra escrita de memoria en un resumen se desfasa** — cópiala del fichero que la produjo.
15. **Un componente que descarta y después cuenta miente en silencio** — reporta también lo que excluye.
16. **Antes de portar una herramienta a otra máquina, mide su premisa allí** — las cifras del docstring son de la máquina donde se escribió.
17. **Preguntar al cierre en texto plano otra vez: la decisión quedó sin respuesta** — toda pregunta de cierre va con opciones que el usuario pueda elegir.
