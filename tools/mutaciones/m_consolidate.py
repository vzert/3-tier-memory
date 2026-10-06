import io, sys
# F6 del plan de ciclo de vida de learnings (2.50.0): el aviso de consolidar (consolidate-aviso.py y
# su linea en session-start.sh) y `learning.update --last-verified` (journal-emit.py +
# journal-compact.py). Cada mutacion apaga una pieza y su aserto de test-consolidate-aviso.sh o de
# test-learning-update.sh (seccion 23) tiene que caer.
#
# Uso: m_consolidate.py <fichero> <mutacion>
# Patrones de una sola linea, sin "\n": el checkout de Windows trae CRLF (regla 322).
# Cada sustitucion tiene que calzar EXACTAMENTE una vez; si no, imprime 0 -> SIN PROBAR.
M = {
    # consolidate-aviso.py
    "umbral-16": [("CRECIMIENTO = 15", "CRECIMIENTO = 16")],
    "cuenta-vivas": [
        ("    return max(nums) if nums else len(reglas)",
         "    return len([t for _, t in reglas if not learning_marks.regla_retirada(t)])")],
    "negativo-valido": [
        ("            if isinstance(k, str) and isinstance(v, int) and not isinstance(v, bool) and v >= 0}",
         "            if isinstance(k, str) and isinstance(v, int) and not isinstance(v, bool)}")],
    "bool-valido": [
        ("            if isinstance(k, str) and isinstance(v, int) and not isinstance(v, bool) and v >= 0}",
         "            if isinstance(k, str) and isinstance(v, int) and v >= 0}")],
    "h11-en-cuerpo": [
        ("    return bool(_CORRIGE.match(t) or _CORREGIDO.match(t))",
         "    return bool(re.search(_CORRIGE.pattern[1:], texto or \"\", re.IGNORECASE) or _CORREGIDO.match(t))")],
    "h11-insensible": [
        ('_CORREGIDO = re.compile(r"^CORREGIDO\\b")', '_CORREGIDO = re.compile(r"^CORREGIDO\\b", re.IGNORECASE)')],
    "h11-cuenta-retiradas": [
        ("                 if not learning_marks.regla_retirada(t)]", "                 if True]")],
    "archivados-cuentan": [
        ('        if not n.endswith(".md") or n.startswith(".") or _ARCHIVADO.search(n):',
         '        if not n.endswith(".md") or n.startswith("."):')],
    "aviso-sin-guarda": [("        except Exception:", "        except ZeroDivisionError:")],
    "guardar-no-escribe": [
        ("        os.replace(tmp, os.path.join(mem, ESTADO))", "        os.unlink(tmp)")],
    # session-start.sh
    "aviso-solo-agente": [('      human "$CONSOL_AVISO"', "      :")],
    # journal-compact.py
    "lv-retrocede": [
        ('            if re.fullmatch(r"\\d{4}-\\d{2}-\\d{2}", viejo) and viejo >= lv:', "            if False:")],
    "lv-fecha-sin-validar": [("                date.fromisoformat(lv)", "                pass")],
    "lv-inventa-frontmatter": [
        ('        raise Quarantine(f"no-anchor: learnings/{topic}.md no tiene frontmatter (--- en la linea 1)")',
         '        lines[0:0] = ["---", "---"]')],
    "lv-ignorado-validador": [
        ('                or p.get("disparadores") or p.get("last_verified")):', '                or p.get("disparadores")):')],
    # journal-emit.py
    "lv-emisor-sin-validar": [("                                  and fecha_real(last_verified)):", "                                  and True):")],
}

p, nombre = sys.argv[1], sys.argv[2] if len(sys.argv) > 2 else ""
if nombre not in M:
    print(f"0 mutacion desconocida: {nombre}")
    sys.exit(0)
with io.open(p, encoding="utf-8", newline="") as fh:
    s = fh.read()
n = 0
for viejo, nuevo in M[nombre]:
    c = s.count(viejo)
    if c != 1:
        print(f"0 sustituciones (el patron aparece {c} veces)")
        sys.exit(0)
    s = s.replace(viejo, nuevo)
    n += 1
with io.open(p, "w", encoding="utf-8", newline="") as fh:
    fh.write(s)
print(f"{n} sustituciones")
