---
importance: 9
---
# Publicación y privacidad

1. **Un repo público no lleva rutas reales del usuario ni nombres de sus proyectos privados** — ni en plantillas, ni en ejemplos, ni en comentarios de código.
2. **El escaneo de datos privados es un paso del push, no una buena intención** — va antes, porque después solo se puede borrar, no despublicar.
3. **Una clave que llegó a un push público se rota** — redactarla en el historial no la des-filtra.
4. **Un fixture de test copiado de una sesión real lleva datos del usuario** — anonimízalo antes de commitearlo.
5. **El CHANGELOG es publicación** — lo que dice sobre incidentes no nombra clientes, hosts ni cuentas.
6. **Los datos de medición de una instalación no se publican** — el código del banco sí; los casos, que citan sesiones, van en .gitignore.
7. **Un token en una URL queda en el historial del shell y en los logs** — pásalo por variable de entorno o por fichero.
8. **Revisa el diff saliente completo, no solo los ficheros que tocaste** — un fichero generado puede arrastrar datos.
9. **Un mensaje de error puede imprimir un secreto** — no imprimas el valor de una variable de credenciales ni en modo depuración.
10. **Las capturas de pantalla también se publican** — revisa que no muestren correos, IDs de cuenta ni rutas.
11. **Borrar un fichero en un commit nuevo no lo borra del historial** — sigue accesible en el commit anterior.
12. **Un issue público es publicación** — pegar un log entero en un issue puede filtrar hosts internos.
13. **La licencia va antes del primer push público** — sin ella el código no es reutilizable aunque sea visible.
14. **Un .env de ejemplo lleva valores falsos obvios** — nunca uno real "desactivado".
15. **Los nombres de ramas se publican con el push** — una rama con el nombre de un cliente lo expone.
16. **Un commit firmado con el correo personal lo publica** — configura el correo de noreply antes de publicar.
17. **El borrador del CHANGELOG llevaba el nombre de un proyecto privado** — revisa el texto saliente contra la lista de proyectos antes de publicar.
