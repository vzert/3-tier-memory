#!/bin/bash
# Prueba de que journal-emit rechaza cualquier flag que su tipo no lee (p-7ae84c8ef2, 2.63.2).
#
# Antes salia rc=0, escribia el evento y el flag se perdia sin avisar: 926 combinaciones tipo x flag
# en 2.62.10 (research/flags-sin-lector-journal-emit). --nota era una de ellas (2.62.4, 2.62.10).
#
# La lista de flags y la de tipos salen del `--help` del emisor, no de una lista escrita aqui: un flag
# nuevo del parser entra solo en la prueba. Lo que SI va escrito aqui es que lee cada tipo (LEE), a
# proposito separado de FLAGS_DE: si las dos tablas no dicen lo mismo, cae un aserto.
#
# Para cada tipo x flag de fuera de LEE: sale con error, el mensaje nombra el flag y no deja evento.
# Para cada flag de LEE (control): pasa y deja su evento, con los compañeros que su rama pide (CONTROL);
# los dos que su propia rama rechaza con su mensaje van aparte (RAMA).
# Corre en un solo proceso (importa el emisor y llama a main): ~1000 corridas por subproceso tardaban
# minutos, y en Git Bash mas.
set -e
BIN="$(cd "$(dirname "$0")" && pwd)"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
unset CLAUDE_CODE_SESSION_ID MEMORY_DIR

HELP=$(python3 "$BIN/journal-emit.py" --help)
python3 - "$BIN/journal-emit.py" "$T" "$HELP" <<'EOF'
import contextlib, importlib.util, io, os, re, shutil, sys

EMIT, T, HELP = sys.argv[1], sys.argv[2], sys.argv[3]
spec = importlib.util.spec_from_file_location("journal_emit", EMIT)
je = importlib.util.module_from_spec(spec)
sys.path.insert(0, os.path.dirname(EMIT))
spec.loader.exec_module(je)

ok = fail = 0
def chk(et, cond, detalle=""):
    global ok, fail
    if cond:
        ok += 1; print(f"  ok  {et}")
    else:
        fail += 1; print(f"  FALLA {et}: {detalle}")

# Lo que lee cada tipo, medido con el emisor real (arnes del research) y confrontado con cada rama.
LEE = {
    "pendiente.add": "text prioridad origen creado revisar bloqueado-por relacionado transcript",
    "pendiente.resolve": "id estado sesion nota text-prefix",
    "pendiente.update": "id text prioridad text-prefix nota",
    "pendiente.expire": "id dias prioridad line",
    "pendiente.reopen": "id prioridad",
    "pendiente.window": "id revisar",
    "pendiente.retomar": "id retomar ficha quitar",
    "pendiente.block": "id bloqueado-por desbloquear revisar",
    "pendiente.relate": "id relacionado sin-relacion",
    "pendiente.adopt": "todas line id text-prefix colapsar",
    "session.add": "slug date status summary commit",
    "session.amend": "slug date alias fecha-vieja sesion-vieja",
    "learning.add": "topic text section quickref title when importance disparadores "
                    "sin-disparadores supersedes decision solo-vecinos quickref-prefix nota",
    "learning.update": "topic text quickref match-prefix quickref-prefix title when disparadores "
                       "sin-disparadores quickref-regla last-verified",
    "learning.retire": "topic match-prefix motivo por nota quickref-prefix",
    "plan.upsert": "slug parent inline promote title status date sesion pendientes learnings",
    "plan.reopen": "slug title",
    "research.upsert": "slug status tema date next-step resultado origen inline",
    "research.rename": "slug tema tema-viejo",
}
LEE = {t: {"--" + f for f in v.split()} for t, v in LEE.items()}
COMUNES = {"--type", "--memory-dir", "--session", "--help"}

# Del --help: los tipos (las choices de --type) y todos los flags largos.
m = re.search(r"--type \{([^}]*)\}", HELP)
tipos = m.group(1).split(",") if m else []
flags = sorted(set(re.findall(r"(?<![\w-])--[a-z][a-z-]*", HELP)) - COMUNES)
chk("el --help trae los 19 tipos", len(tipos) == 19, f"{len(tipos)}: {tipos}")
chk("el --help trae los 56 flags", len(flags) == 56, f"{len(flags)}")
chk("LEE cubre los mismos tipos que el emisor", set(tipos) == set(LEE),
    f"sobran {set(LEE) - set(tipos)}, faltan {set(tipos) - set(LEE)}")
fuera = sorted({f for v in LEE.values() for f in v} - set(flags))
chk("LEE solo nombra flags que existen", not fuera, f"{fuera}")

# Un valor que pase la validacion de cada flag (no importa para el rechazo, que va antes).
VAL = {"--text": "**Regla nueva** — cuerpo de prueba", "--prioridad": "Alta",
       "--origen": "[[sessions/2026-10-17-demo]]", "--creado": "2026-10-01",
       "--revisar": "2026-12-01", "--retomar": "2026-12-01", "--ficha": "sessions/2026-10-17-demo",
       "--relacionado": "p-2222222222", "--id": "p-1111111111", "--estado": "abandoned",
       "--dias": "7", "--date": "2026-10-02", "--importance": "5", "--motivo": "duplicada",
       "--por": "1", "--supersedes": "1", "--decision": "nueva", "--last-verified": "2026-10-03",
       "--quickref-regla": "ninguna", "--topic": "uno",
       "--disparadores": "frases=uno dos tres | cuatro cinco seis | siete ocho nueve"}
BOOL = {"--desbloquear", "--quitar", "--sin-relacion", "--todas", "--colapsar", "--inline", "--promote",
        "--solo-vecinos", "--sin-disparadores"}

BASE = {
    "pendiente.add": ["--text", "algo por hacer", "--prioridad", "Baja",
                      "--origen", "[[sessions/2026-10-17-demo]]"],
    "pendiente.resolve": ["--id", "p-1111111111", "--estado", "resolved"],
    "pendiente.update": ["--id", "p-1111111111", "--prioridad", "Media"],
    "pendiente.expire": ["--id", "p-1111111111", "--dias", "30"],
    "pendiente.reopen": ["--id", "p-1111111111"],
    "pendiente.window": ["--id", "p-1111111111", "--revisar", "2026-11-01"],
    "pendiente.retomar": ["--id", "p-1111111111", "--retomar", "2026-11-01",
                          "--ficha", "sessions/2026-10-17-demo"],
    "pendiente.block": ["--id", "p-1111111111", "--bloqueado-por", "otra cosa"],
    "pendiente.relate": ["--id", "p-1111111111", "--relacionado", "p-3333333333"],
    "pendiente.adopt": ["--todas"],
    "session.add": ["--slug", "2026-10-17-demo", "--status", "done"],
    "session.amend": ["--slug", "2026-10-17-demo", "--alias", "otro"],
    "learning.add": ["--topic", "uno", "--text", "**Regla nueva** — cuerpo de prueba distinto"],
    "learning.update": ["--topic", "uno", "--title", "Titulo"],
    "learning.retire": ["--topic", "uno", "--match-prefix", "**Regla vieja**", "--motivo", "obsoleta"],
    "plan.upsert": ["--slug", "demo", "--title", "Demo", "--status", "active"],
    "plan.reopen": ["--slug", "demo"],
    "research.upsert": ["--slug", "rs", "--tema", "Tema", "--status", "active"],
    "research.rename": ["--slug", "rs", "--tema", "Tema nuevo", "--tema-viejo", "Tema"],
}

M = os.path.join(T, "memory")
def fixture():
    shutil.rmtree(M, ignore_errors=True)
    for d in ("pendientes", "sessions", "learnings"):
        os.makedirs(os.path.join(M, d))
    open(os.path.join(M, "_pendientes.md"), "w", encoding="utf-8").write(
        "# Pendientes\n\n## Baja prioridad\n- [ ] Linea viva — _creado: 2026-10-01_ — "
        "_origen: [[sessions/2026-10-17-demo]]_ — _id: p-1111111111_\n"
        "- [ ] Linea sin id — _creado: 2026-10-01_\n")
    open(os.path.join(M, "sessions", "2026-10-17-demo.md"), "w", encoding="utf-8").write("# demo\n")
    open(os.path.join(M, "_session-index.md"), "w", encoding="utf-8").write(
        "| Fecha | Sesion | Status | Resumen | Commit |\n|---|---|---|---|---|\n"
        "| 2026-10-17 | [[sessions/2026-10-17-demo]] | done | demo | N/A |\n")
    open(os.path.join(M, "learnings", "uno.md"), "w", encoding="utf-8").write(
        "# uno\n\n## Reglas\n\n1. **Regla vieja** — texto viejo\n2. **Regla dos** — otra leccion\n")

def eventos():
    p = os.path.join(M, ".journal", "pending")
    return len([f for f in os.listdir(p) if f.endswith(".json")]) if os.path.isdir(p) else 0

def emit(args):
    """(rc, mensaje de salida) de journal-emit en este proceso."""
    fixture()
    viejo = sys.argv
    sys.argv = ["journal-emit.py", "--memory-dir", M, "--session", "prueba"] + args
    out, err = io.StringIO(), io.StringIO()
    rc, msg = 0, ""
    try:
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            je.main()
    except SystemExit as e:
        rc = 0 if e.code in (None, 0) else 1
        msg = e.code if isinstance(e.code, str) else ""
    finally:
        sys.argv = viejo
    return rc, msg + err.getvalue()

def nombrados(msg):
    """Los flags que el mensaje del rechazo generico dice que el tipo no lee."""
    m = re.search(r"no lee ([^:]*):", msg)
    return set(m.group(1).replace(",", " ").split()) if m else set()

def con(flag):
    return [flag] if flag in BOOL else [flag, VAL.get(flag, "valor")]

print("== 1. cada tipo con su comando base pasa (control de todo lo demas) ==")
for t in tipos:
    rc, msg = emit(["--type", t] + BASE[t])
    n = eventos()
    chk(f"{t} base pasa con su evento", rc == 0 and n == 1, f"rc={rc} eventos={n} {msg[-200:]!r}")

print("== 2. cada flag que el tipo no lee: error, lo nombra y no deja evento ==")
for t in tipos:
    for f in flags:
        if f in LEE[t]:
            continue
        rc, msg = emit(["--type", t] + BASE[t] + con(f))
        n = eventos()
        # --nota tiene su propio mensaje desde 2.62.10 (dice donde va); rechazarla es lo que cuenta.
        nombra = nombrados(msg) == {f} or (f == "--nota" and "no guarda --nota" in msg)
        chk(f"{t} {f} rechaza", rc == 1 and nombra and n == 0,
            f"rc={rc} eventos={n} {msg[-160:]!r}")

# Un flag que el tipo lee puede necesitar un compañero para que el evento valga (p. ej.
# learning.update --text pide --match-prefix): el control lleva el comando entero.
RV = "**Regla vieja**"
DISP = VAL["--disparadores"]
CONTROL = {
    ("pendiente.block", "--desbloquear"): ["--id", "p-1111111111", "--desbloquear"],
    ("pendiente.relate", "--sin-relacion"): ["--id", "p-1111111111", "--sin-relacion"],
    ("pendiente.retomar", "--quitar"): ["--id", "p-1111111111", "--quitar",
                                        "--ficha", "sessions/2026-10-17-demo"],
    ("learning.add", "--nota"): BASE["learning.add"] + ["--supersedes", "1", "--nota", "nota"],
    ("learning.add", "--quickref-prefix"): BASE["learning.add"] + ["--supersedes", "1",
                                                                   "--quickref-prefix", "qp"],
    ("learning.update", "--text"): ["--topic", "uno", "--match-prefix", RV,
                                    "--text", RV + " — texto nuevo"],
    ("learning.update", "--match-prefix"): ["--topic", "uno", "--match-prefix", RV,
                                            "--text", RV + " — texto nuevo"],
    ("learning.update", "--disparadores"): ["--topic", "uno", "--match-prefix", RV,
                                            "--disparadores", DISP],
    ("learning.update", "--sin-disparadores"): ["--topic", "uno", "--match-prefix", RV,
                                                "--sin-disparadores"],
    ("learning.update", "--quickref"): ["--topic", "uno", "--quickref", "q", "--quickref-prefix", "qp"],
    ("learning.update", "--quickref-prefix"): ["--topic", "uno", "--quickref", "q",
                                               "--quickref-prefix", "qp"],
    ("learning.update", "--quickref-regla"): ["--topic", "uno", "--quickref-prefix", "qp",
                                              "--quickref-regla", "ninguna"],
    ("learning.retire", "--por"): ["--topic", "uno", "--match-prefix", RV, "--motivo", "duplicada",
                                   "--por", "2"],
}
# Flags del tipo que su propia rama rechaza, con su mensaje: el flag es del tipo, el uso no.
RAMA = {
    ("pendiente.update", "--nota"): "pendiente.update no guarda --nota",
    ("learning.add", "--sin-disparadores"): "--sin-disparadores es de learning.update",
}

print("== 3. cada flag que el tipo lee pasa y deja su evento (o lo rechaza su rama) ==")
for t in tipos:
    for f in sorted(LEE[t]):
        if f in BASE[t] and (t, f) not in CONTROL:
            continue
        args = CONTROL.get((t, f), BASE[t] + con(f))
        rc, msg = emit(["--type", t] + args)
        n = eventos()
        if (t, f) in RAMA:
            chk(f"{t} {f} lo rechaza su rama, no el generico",
                rc == 1 and not nombrados(msg) and RAMA[(t, f)] in msg and n == 0, msg[-160:])
        else:
            # --solo-vecinos lista los vecinos y no escribe nada: es su conducta.
            espera = 0 if f == "--solo-vecinos" else 1
            chk(f"{t} {f} pasa con su evento", rc == 0 and n == espera and not nombrados(msg),
                f"rc={rc} eventos={n} {msg[-160:]!r}")

print("== 4. formas que sys.argv a mano no ve ==")
rc, msg = emit(["--type", "pendiente.add"] + BASE["pendiente.add"] + ["--motiv", "m"])
chk("abreviado --motiv rechaza como --motivo", rc == 1 and nombrados(msg) == {"--motivo"} and eventos() == 0, msg[-160:])
rc, msg = emit(["--type", "pendiente.reopen", "--id=p-1111111111", "--text=hola"])
chk("con igual --text=hola rechaza", rc == 1 and nombrados(msg) == {"--text"} and eventos() == 0, msg[-160:])
rc, msg = emit(["--type", "pendiente.reopen", "--id=p-1111111111"])
chk("con igual --id=... pasa", rc == 0 and eventos() == 1, msg[-160:])
rc, msg = emit(["--type", "pendiente.add"] + BASE["pendiente.add"] + ["--dias", "3", "--motivo", "m"])
chk("dos flags de mas: el mensaje nombra los dos", nombrados(msg) == {"--dias", "--motivo"}, msg[-160:])
chk("el mensaje dice que lee el tipo", "pendiente.add lee:" in msg and "--revisar" in msg, msg[-200:])
# Vacio cuenta: quien lo paso esperaba guardar algo (lo mismo que --nota "" en 2.62.10).
rc, msg = emit(["--type", "pendiente.window"] + BASE["pendiente.window"] + ["--prioridad", ""])
chk("valor vacio en --prioridad tambien rechaza", rc == 1 and nombrados(msg) == {"--prioridad"}, msg[-160:])

print()
print(f"pass={ok} fail={fail}")
sys.exit(1 if fail else 0)
EOF
