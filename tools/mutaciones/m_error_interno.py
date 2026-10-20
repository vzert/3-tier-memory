import io, sys
# journal-compact (compact) manda a cuarentena con `error-interno:` cualquier excepcion de
# apply_event que no sea Quarantine, OSError ni UnicodeDecodeError (2.63.11, p-ac5a4bb888). Cada
# mutacion deshace una parte y su aserto de test-error-interno.sh (o de test-session-amend.sh)
# tiene que caer.
#
# Uso: m_error_interno.py <fichero> <mutacion>
# Patrones de una sola linea, sin "\n": el checkout de Windows trae CRLF (regla 322).
# Cada sustitucion tiene que calzar EXACTAMENTE una vez; si no, imprime 0 -> SIN PROBAR.
M = {
    # Sin la red: la excepcion vuelve a subir y el evento se queda en pending/.
    "sin-captura": [
        ('                msg = f"{type(e).__name__}', '                raise  # f"{type(e).__name__}')],
    # Un fallo de escritura iria a cuarentena en vez de esperar al reintento.
    "captura-oserror": [
        ("            except (OSError, UnicodeDecodeError):", "            except UnicodeDecodeError:")],
    # Un indice con bytes que no son utf-8 mandaria a cuarentena el evento.
    "captura-decode": [
        ("            except (OSError, UnicodeDecodeError):", "            except OSError:")],
    # Sin deshacer: un resolve que falla en la fila mensual deja el pendiente cerrado en el indice.
    "sin-deshacer": [
        ("                fallos = deshacer_evento(mem)", "                fallos = []")],
    # Sin la foto de antes: no hay nada que restaurar.
    "sin-foto": [
        ("        _DESHACER[ap] = (antes, _ESCRITO.get(ap))", "        pass")],
    # Sin anular lo anotado: el reopen bueno de despues ve el cierre como ya revertido.
    "sin-desanotar": [
        ("    for clave, ts in desanotar(mem, list(_ANOTADAS or [])):", "    for clave, ts in []:")],
    # Sin devolver la huella: la pasada siguiente ve el indice restaurado como escrito a mano.
    "sin-huella": [
        ("            _ESCRITO.pop(ap, None)", "            pass")],
    # Sin borrar el temporal: un sustituto suelto deja `<indice>.<pid>.tmp` en memory/.
    "sin-borrar-tmp": [
        ("            os.remove(tmp)   # el temporal de atomic_write", "            pass")],
    # Una restauracion que falla deja `<indice>.<pid>.tmp` (revisor externo, ronda 6).
    "restaura-deja-tmp": [
        ("                        os.remove(tmp)   # una restauracion que falla tampoco deja su temporal",
         "                        pass")],
}

p, nombre = sys.argv[1], sys.argv[2] if len(sys.argv) > 2 else ""
if nombre not in M:
    print(f"0 sust: mutacion desconocida {nombre}")
    sys.exit(0)
s = io.open(p, encoding="utf-8", newline="").read()
cuentas = [s.count(viejo) for viejo, _ in M[nombre]]
if cuentas != [1] * len(cuentas):
    print(f"0 sust de {nombre} (cada sustitucion calza {cuentas} veces; se exige 1)")
    sys.exit(0)
for viejo, nuevo in M[nombre]:
    s = s.replace(viejo, nuevo)
io.open(p, "w", encoding="utf-8", newline="").write(s)
print(f"{len(cuentas)} sust de {nombre}")
