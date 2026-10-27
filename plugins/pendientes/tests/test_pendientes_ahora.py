"""Pruebas de bin/pendientes-ahora.py sobre una memoria de ejemplo.

Uso: python3 -I tests/test_pendientes_ahora.py --lib <carpeta bin/ de 3-tier-memory>
Sale 0 solo si todas pasan; imprime OK <n> al final.
"""
import json
import os
import re
import subprocess
import sys
import tempfile
import time

AQUI = os.path.dirname(os.path.abspath(__file__))
SCRIPT = os.path.join(AQUI, "..", "bin", "pendientes-ahora.py")

PEND = """# Pendientes

## Alta prioridad

- [ ] Paso del hilo — _origen: [[sessions/2026-10-13-b]]_ — _creado: 2026-10-13_ — _id: p-aaaaaaaaaa_ — _relacionado: p-bbbbbbbbbb_
- [ ] Alta bloqueada — _creado: 2026-10-01_ — _id: p-1111111111_ — _bloqueado: espera una decision_
- [ ] Alta con recordatorio futuro — _creado: 2026-10-01_ — _id: p-2222222222_ — _revisar: 2026-10-20_
- [ ] Alta que espera al 2026-11-02 para medir — _creado: 2026-10-01_ — _id: p-3333333333_
- [ ] Alta libre uno — _origen: barrido A04_ — _creado: 2026-09-01_ — _id: p-4444444444_
- [ ] Alta libre dos — _origen: [[sessions/2026-01-01-borrada]]_ — _creado: 2026-09-02_ — _id: p-5555555555_
- [ ] Alta libre tres — _origen: [[plans/plan-x|el plan]], sessions/2026-10-12-a_ — _creado: 2026-09-03_ — _id: p-6666666666_ — _relacionado: p-dddddddddd, plan-x_
- [ ] Alta que vence hoy — _creado: 2026-09-03_ — _id: p-7777777777_ — _revisar: 2026-10-13_

## Media prioridad

- [ ] Ligado al paso — _creado: 2026-10-10_ — _id: p-bbbbbbbbbb_
- [ ] Media vencida nueva — _creado: 2026-09-01_ — _id: p-9999999999_ — _revisar: 2026-10-10_
- [ ] Media vencida vieja — _creado: 2026-09-01_ — _id: p-8888888888_ — _revisar: 2026-09-20_
- [ ] Media vencida otra — _origen: [[../fuera]], foo — bar_ — _creado: 2026-09-01_ — _id: p-0000000000_ — _revisar: 2026-10-11_
- [x] Media vencida otra, cerrada — _origen: [[sessions/2026-10-13-b]]_ — _id: p-0000000000_ — _relacionado: p-aaaaaaaaaa_

## Baja prioridad

- [ ] Baja suelta — _creado: 2026-09-01_ — _id: p-cccccccccc_
"""

FICHA_VIEJA = "# a\n\n## Como retomar\n\nProximo paso: hacer p-5555555555\n"
# 0.3.1: el hilo es el de la ficha de ESTA ventana; la b la escribio la sesion "sb".
FICHA = "---\nsession_id: sb\n---\n# b\n\n## Como retomar\n\n```\nRetomamos: x\nProximo paso: implementar p-aaaaaaaaaa ya\n```\n"


def correr(mem, lib, *extra):
    out = subprocess.run([sys.executable, "-I", SCRIPT, "--memory-dir", mem, "--hoy", "2026-10-13",
                          "--lib", lib, *extra], capture_output=True, text=True,
                         encoding="utf-8")  # el script escribe UTF-8; Windows decodificaria en cp1252
    assert out.returncode == 0, out.stderr
    assert out.stderr == "", out.stderr
    return json.loads(out.stdout)


def main():
    lib = sys.argv[sys.argv.index("--lib") + 1]
    fallos, n = [], 0

    def check(nombre, cond):
        nonlocal n
        n += 1
        if not cond:
            fallos.append(nombre)

    with tempfile.TemporaryDirectory() as tmp:
        mem = os.path.join(tmp, "memory")
        os.makedirs(os.path.join(mem, "sessions"))
        os.makedirs(os.path.join(mem, "plans"))
        with open(os.path.join(tmp, "fuera.md"), "w", encoding="utf-8") as fh:
            fh.write("# fuera de memory/\n")
        with open(os.path.join(mem, "plans", "plan-x.md"), "w", encoding="utf-8") as fh:
            fh.write("# plan x\n")
        with open(os.path.join(mem, "_pendientes.md"), "w", encoding="utf-8") as fh:
            fh.write(PEND)
        for nombre, texto in (("2026-10-12-a.md", FICHA_VIEJA), ("2026-10-13-b.md", FICHA)):
            with open(os.path.join(mem, "sessions", nombre), "w", encoding="utf-8") as fh:
                fh.write(texto)

        d = correr(mem, lib, "--session-id", "sb")
        ids = [i["id"] for i in d["items"]]
        check("ok", d["ok"] is True)
        # Contexto del clic (0.2.1): no depende de la version de la biblioteca.
        todos = {i["id"]: i for i in d["items"] + d["resto"]}
        ctx = {k: (v.get("origen"), v.get("origen_texto"), v.get("relacionado")) for k, v in todos.items()}
        check("contexto: ficha de _origen y _relacionado",
              ctx.get("p-aaaaaaaaaa") == (["memory/sessions/2026-10-13-b.md"], None, ["p-bbbbbbbbbb"]))
        check("contexto: plan con alias y ruta suelta, los dos si existen",
              ctx.get("p-6666666666") == (["memory/plans/plan-x.md", "memory/sessions/2026-10-12-a.md"], None,
                                          ["p-dddddddddd", "plan-x"]))
        check("contexto: origen en texto libre va tal cual",
              ctx.get("p-4444444444") == ([], "barrido A04", []))
        check("contexto: una ficha que ya no existe no se pega como ruta",
              ctx.get("p-5555555555") == ([], "[[sessions/2026-01-01-borrada]]", []))
        check("contexto: fuera de memory/ no es ruta; la raya dentro del valor no lo corta; un [x] no pisa",
              ctx.get("p-0000000000") == ([], "[[../fuera]], foo — bar", []))
        check("contexto: sin _origen ni _relacionado, vacio",
              ctx.get("p-7777777777") == ([], None, []))
        if not d["lib"]["hilo"]:
            # 3-tier-memory < 2.57.0 (sin hilo() ni recibido()): el mod degrada a "solo el paso".
            # Se prueba ese modo y nada mas; el resto de la suite pide 2.57.0+.
            print("AVISO: --lib sin hilo() (3-tier-memory < 2.57.0): solo pruebo el modo degradado")
            check("degradado: primero el proximo paso", ids[:1] == ["p-aaaaaaaaaa"])
            check("degradado: el ligado no entra como hilo",
                  all(i["grupo"] != "hilo" for i in d["items"] if i["id"] != "p-aaaaaaaaaa"))
            check("degradado: bloqueada y revisar futuro fuera",
                  not ({"p-1111111111", "p-2222222222"} & set(ids)))
            for f in fallos:
                print("FALLA:", f)
            if fallos:
                return 1
            print(f"OK {n} (degradado)")
            return 0
        check("ficha mas reciente", d["ficha"] == "2026-10-13-b.md")
        check("primero el proximo paso", ids[:1] == ["p-aaaaaaaaaa"])
        check("luego el ligado", ids[1:2] == ["p-bbbbbbbbbb"])
        # Cupos: hilo 2 (de 3), vence 2, alta 2 = 6; el hueco lo rellena el siguiente en orden (vence).
        check("vence: Alta de hoy, luego Media por _revisar mas viejo",
              ids[2:5] == ["p-7777777777", "p-8888888888", "p-9999999999"])
        check("alta libres por orden de fila", ids[5:7] == ["p-4444444444", "p-5555555555"])
        check("tope 7", len(ids) == 7)
        check("resto = los no mostrados, en orden", [i["id"] for i in d["resto"]] == ["p-0000000000", "p-6666666666"])
        check("quedan = candidatos - mostrados", d["quedan"] == d["candidatos"] - 7 and d["quedan"] == 2)
        excluidos = {"p-1111111111", "p-2222222222", "p-3333333333", "p-cccccccccc"}
        check("bloqueada, revisar futuro, fecha futura y Baja fuera", not (excluidos & set(ids)))
        check("lib con hilo", d["lib"]["hilo"] is True)
        por = {i["id"]: i for i in d["items"]}
        check("edad: dias desde _creado", por["p-4444444444"]["edad"] == 42)
        check("totales por grupo", d["totales"] == {"hilo": 2, "vence": 4, "alta": 3})
        check("dias: hoy 0, vencido 23", por["p-7777777777"]["dias"] == 0 and por["p-8888888888"]["dias"] == 23)
        check("sin _revisar no hay dias", por["p-4444444444"]["dias"] is None)

        sys.path.insert(0, os.path.join(AQUI, "..", "bin"))
        import importlib.util
        spec = importlib.util.spec_from_file_location("ahora", SCRIPT)
        ahora = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(ahora)
        texto = ("Snippet de cierre: implementar la regla del hilo que se decidio "
                 "(research/x). (1) Liga automatica")
        check("etiqueta", ahora.etiqueta_y_resto(texto)[0] == "Snippet de cierre")
        check("titulo corta en la pausa", ahora.titulo_auto(texto)
              == "Implementar la regla del hilo que se decidio")
        check("sin etiqueta si el tema es largo",
              ahora.etiqueta_y_resto("Una frase larga de mas de cuatro palabras: algo")[0] is None)
        check("ruta no se capitaliza", ahora.titulo_auto("commands/migrate.md 5c emite algo")
              == "commands/migrate.md 5c emite algo")
        check("titulo <= 61", all(len(i["titulo_auto"]) <= 61 for i in d["items"]))
        check("resumen", d["resumen"] == {"abiertos": 13, "vencidos": 3, "hoy": 1, "alta": 8,
                                          "bloqueados": 1, "sin_id": 0, "planes": 0})

        # Con tope 3: el cupo del hilo (3) no deja sitio, pero el hilo sigue primero.
        d3 = correr(mem, lib, "--session-id", "sb", "--max", "3")
        check("tope 3", [i["id"] for i in d3["items"]] == ["p-aaaaaaaaaa", "p-bbbbbbbbbb", "p-7777777777"])

        # En curso: commits posteriores a la ficha, prompts de esta sesion y de otra viva.
        proyecto = tmp
        git = lambda *a: subprocess.run(["git", "-C", proyecto, *a], capture_output=True, text=True,
                                        env={**os.environ, "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@t",
                                             "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@t"})
        git("init", "-q")
        ficha_b = os.path.join(mem, "sessions", "2026-10-13-b.md")
        os.utime(ficha_b, (time.time() - 3600, time.time() - 3600))
        # Un commit anterior a la ficha (--since mira la fecha del committer) no cuenta.
        subprocess.run(["git", "-C", proyecto, "commit", "-q", "--allow-empty", "-m", "viejo p-6666666666"],
                       env={**os.environ, "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@t",
                            "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@t",
                            "GIT_COMMITTER_DATE": "2001-01-01T00:00:00+0000", "GIT_AUTHOR_DATE": "2001-01-01T00:00:00+0000"}, capture_output=True, check=True)
        git("commit", "-q", "--allow-empty", "-m", "trabajo en p-4444444444 y p-4444444444")
        raiz = os.path.join(tmp, "projects")
        carpeta = os.path.join(raiz, re.sub(r"[^A-Za-z0-9]", "-", os.path.abspath(proyecto)))
        os.makedirs(carpeta)

        def transcripcion(nombre, filas, hace=0):
            ruta = os.path.join(carpeta, nombre + ".jsonl")
            with open(ruta, "w", encoding="utf-8") as fh:
                fh.write('{"type": "mode"}\n')
                for f in filas:
                    fh.write(json.dumps(f) + "\n")
            os.utime(ruta, (time.time() - hace, time.time() - hace))

        u = lambda c, meta=False: {"type": "user", "isMeta": meta, "message": {"role": "user", "content": c}}
        transcripcion("esta", [u("trabajemos p-7777777777: algo")])
        # Retomada: el "Retomamos:" va al principio y despues hay mas de 768 KB de trabajo; solo
        # el id del Proximo paso esta en curso, los extras del snippet son sugerencias.
        retomamos = ("Retomamos: x\n\nProximo paso: hacer p-5555555555 ya\n\n"
                     "Si ese paso es corto, suma en la misma sesion: p-0000000000 (Media) — y.")
        relleno = [u([{"type": "tool_result", "content": "z" * 1000}])] * 900
        transcripcion("retomada", [u(retomamos)] + relleno, hace=600)
        transcripcion("otra", [u([{"type": "text", "text": "retoma p-8888888888"}]),
                                u([{"type": "tool_result", "content": "p-9999999999 p-0000000000"}]),
                                u("p-0000000000 meta", meta=True)], hace=60)
        transcripcion("vieja", [u("p-6666666666")], hace=3 * 3600)
        # Filas que no escribio la persona: aviso de tarea (origin.kind) y mensaje de otro agente
        # en formato viejo (sin origin). Ninguna pone su id en curso; una humana con origin si.
        aviso = u("Tarea terminada: p-4444444444")  # solo origin.kind lo delata
        aviso["origin"] = {"kind": "task-notification"}
        humano = u("y ahora p-2222222222")
        humano["origin"] = {"kind": "human"}
        transcripcion("avisos", [aviso, u("Another Claude session sent a message: p-6666666666"),  # sin origin: lo delata la cabecera
                                 humano], hace=120)
        dc = correr(mem, lib, "--session-id", "esta", "--projects-root", raiz, "--max", "20")
        ec = {i["id"]: i["en_curso"] for i in dc["items"] + dc["resto"]}
        check("en curso: commit tras la ficha", ec.get("p-4444444444") == {"donde": "commits", "n": 1})
        check("en curso: esta sesion", (ec.get("p-7777777777") or {}).get("donde") == "aqui")
        check("en curso: otra sesion viva, con minutos", ec.get("p-8888888888") == {"donde": "otra sesion", "n": 0, "hace_min": 1})
        check("en curso: el paso de un Retomamos al principio de un archivo grande",
              (ec.get("p-5555555555") or {}).get("donde") == "otra sesion")
        check("no cuentan: los extras de un Retomamos", ec.get("p-0000000000") is None)
        check("no cuentan: avisos de tareas ni mensajes de otros agentes",
              (ec.get("p-4444444444") or {}).get("donde") == "commits" and ec.get("p-6666666666") is None)
        check("no cuentan: tool_result, meta, sesion vieja, commit anterior a la ficha",
              all(ec.get(i) is None for i in ("p-9999999999", "p-0000000000", "p-6666666666")))
        sin = correr(mem, lib, "--projects-root", os.path.join(tmp, "nada"))

        # 0.3.1: una ventana nueva (sin ficha propia y sin prompt) no tiene "trabajo actual", aunque
        # la ficha mas nueva del proyecto tenga hilo: esa es de otra ventana (caso real de
        # proyecto-edge, 2026-10-22).
        transcripcion("nueva", [], hace=0)
        dv = correr(mem, lib, "--session-id", "nueva", "--projects-root", raiz)
        check("ventana nueva: sin SIGUIENTE ni RELACIONADO",
              dv["ficha"] is None and all(i["grupo"] != "hilo" for i in dv["items"] + dv["resto"]))
        check("ventana nueva: vence y alta siguen", any(i["grupo"] == "vence" for i in dv["items"]))
        check("sin --session-id: sin hilo",
              sin["ficha"] is None and all(i["grupo"] != "hilo" for i in sin["items"] + sin["resto"]))
        # Una ventana sin ficha cuyos prompts citan un id: ese id hace de paso y su hilo sale
        # (decision 2A de Victor: "ids en sus prompts o su ficha"). p-aaaaaaaaaa liga a p-bbbbbbbbbb.
        transcripcion("solo-ids", [u("mira p-aaaaaaaaaa por favor")], hace=0)
        di = correr(mem, lib, "--session-id", "solo-ids", "--projects-root", raiz, "--max", "20")
        gi = {i["id"]: i for i in di["items"] + di["resto"]}
        check("ventana con un id citado: el id es el paso y su ligado sale en el hilo",
              di["ficha"] is None and (gi.get("p-aaaaaaaaaa") or {}).get("grupo") == "hilo"
              and (gi.get("p-aaaaaaaaaa") or {}).get("motivo") == "proximo paso"
              and (gi.get("p-bbbbbbbbbb") or {}).get("grupo") == "hilo")
        check("ventana con un id citado: el id tambien sale en curso aqui",
              ((gi.get("p-aaaaaaaaaa") or {}).get("en_curso") or {}).get("donde") == "aqui")
        transcripcion("id-cerrado", [u("y p-fedcba9876 y p-0123456789, que no existen")], hace=0)
        dz = correr(mem, lib, "--session-id", "id-cerrado", "--projects-root", raiz, "--max", "20")
        check("ventana que solo cita ids que no existen: sin hilo",
              all(i["grupo"] != "hilo" for i in dz["items"] + dz["resto"]))
        # La ventana que pego el Retomamos de la b trabaja su hilo.
        transcripcion("pegada", [u("Retomamos: x\n\nLee memory/sessions/2026-10-13-b.md para el contexto "
                                   "completo.\n\nProximo paso: implementar p-aaaaaaaaaa ya")], hace=0)
        dg = correr(mem, lib, "--session-id", "pegada", "--projects-root", raiz, "--max", "20")
        gp = {i["id"]: i for i in dg["items"] + dg["resto"]}
        check("ventana que pego el snippet: su ficha y su hilo",
              dg["ficha"] == "2026-10-13-b.md" and (gp.get("p-bbbbbbbbbb") or {}).get("grupo") == "hilo")
        # El relevo de lookout trae el snippet en el system prompt, no en un prompt.
        snap = {"type": "attachment", "attachment": {"type": "prompt_snapshot", "systemPrompt":
                "Eres un relevo.\nRetomamos: x\n\nLee memory/sessions/2026-10-13-b.md para el contexto."}}
        transcripcion("relevo", [snap], hace=0)
        dr = correr(mem, lib, "--session-id", "relevo", "--projects-root", raiz)
        check("relevo con el snippet en el system prompt: su ficha", dr["ficha"] == "2026-10-13-b.md")
        check("sin sesion ni transcripciones: solo commits",
              all((i["en_curso"] or {}).get("donde") in (None, "commits") for i in sin["items"]))

        # Un paso que cita lo bloqueado, lo de revisar futuro, lo de fecha futura y lo que vence
        # hoy: nada de eso es "proximo paso"; la Baja libre si.
        with open(os.path.join(mem, "sessions", "2026-10-14-c.md"), "w", encoding="utf-8") as fh:
            fh.write("---\nsession_id: sc\n---\n# c\n\n## Como retomar\n\nProximo paso: p-1111111111 p-2222222222 "
                     "p-3333333333 p-7777777777 p-cccccccccc\n")
        dp = correr(mem, lib, "--session-id", "sc")
        hilo_ids = [i["id"] for i in dp["items"] if i["grupo"] == "hilo"]
        check("paso filtrado como hilo()", dp["ficha"] == "2026-10-14-c.md" and hilo_ids == ["p-cccccccccc"])
        check("lo de hoy sigue en vence", any(i["id"] == "p-7777777777" and i["grupo"] == "vence"
                                               for i in dp["items"]))

        # Sin fichas: no hay hilo; vence y alta siguen.
        for f in os.listdir(os.path.join(mem, "sessions")):
            os.remove(os.path.join(mem, "sessions", f))
        d0 = correr(mem, lib)
        check("sin ficha no hay hilo", d0["ficha"] is None and all(i["grupo"] != "hilo" for i in d0["items"]))
        check("sin ficha, primero lo que vence", d0["items"][0]["id"] == "p-7777777777")

        # Sin _pendientes.md: ok false con el motivo, salida 0.
        os.remove(os.path.join(mem, "_pendientes.md"))
        dn = correr(mem, lib)
        check("sin pendientes", dn["ok"] is False and dn["error"].startswith("no hay "))

    # `_retomar` (3-tier-memory 2.62.8): el paso de un snippet que no se pego. Desde 0.3.0 no sale en
    # vence (se confundia con lo que vence de verdad): va a `planes`, una fila por ficha, fuera del
    # tope, con el snippet para el clic y si la sesion que la escribio sigue abierta.
    with tempfile.TemporaryDirectory() as tmp:
        mem = os.path.join(tmp, "memory")
        os.makedirs(os.path.join(mem, "sessions"))
        with open(os.path.join(mem, "_pendientes.md"), "w", encoding="utf-8") as fh:
            fh.write("# Pendientes\n\n## Alta prioridad\n\n"
                     "- [ ] Alta del plan r — _creado: 2026-10-01_ — _id: p-1313131313_"
                     " — _retomar: 2026-10-12 sessions/2026-10-12-r_\n"
                     + "".join(f"- [ ] Alta libre {k} — _creado: 2026-10-01_ — _id: p-a{k}a{k}a{k}a{k}a{k}_\n"
                               for k in range(5)) +
                     "\n## Media prioridad\n\n"
                     "- [ ] Paso sin pegar — _creado: 2026-10-01_ — _id: p-1212121212_"
                     " — _retomar: 2026-10-12 sessions/2026-10-12-r_\n"
                     "- [ ] Paso de ficha borrada — _creado: 2026-10-01_ — _id: p-3434343434_"
                     " — _retomar: 2026-10-11 sessions/2026-10-11-borrada_\n"
                     "- [ ] Paso de otro dia — _creado: 2026-10-01_ — _id: p-5656565656_"
                     " — _retomar: 2099-01-01 sessions/2026-10-12-r_\n"
                     "- [ ] Paso con revisar futuro — _creado: 2026-10-01_ — _id: p-7878787878_"
                     " — _revisar: 2099-01-01_ — _retomar: 2026-10-12 sessions/2026-10-12-r_\n"
                     "- [ ] Paso que ademas vence — _creado: 2026-10-01_ — _id: p-6767676767_"
                     " — _revisar: 2026-10-06_ — _retomar: 2026-10-13 sessions/2026-10-13-s_\n"
                     + "".join(f"- [ ] Vencido {k} — _creado: 2026-10-01_ — _id: p-9{k}9{k}9{k}9{k}9{k}_"
                               f" — _revisar: 2026-10-0{k + 1}_\n" for k in range(4)))
        SID_R = "11111111-2222-3333-4444-555555555555"
        SID_S = "66666666-7777-8888-9999-000000000000"
        with open(os.path.join(mem, "sessions", "2026-10-12-r.md"), "w", encoding="utf-8") as fh:
            fh.write(f"---\ntype: session\nsession_id: {SID_R}\n---\n# r\n\n## Como retomar\n\n"
                     "```\nRetomamos: r.\n\nProximo paso: hacer p-1212121212.\n```\n\n## Commits\n\nnada\n")
        with open(os.path.join(mem, "sessions", "2026-10-13-s.md"), "w", encoding="utf-8") as fh:
            fh.write(f"---\nsession_id: {SID_S}\n---\n# s\n\n## Como retomar\n\n"
                     "```\nRetomamos: s.\n\nProximo paso: hacer p-6767676767.\n```\n")
        # Otra sesion cerro despues con otro paso: es justo el caso que entierra el snippet.
        with open(os.path.join(mem, "sessions", "2026-10-14-otra.md"), "w", encoding="utf-8") as fh:
            fh.write("# otra\n\n## Como retomar\n\nNinguno — cerro todo.\n")
        # Registro de procesos: la sesion de "r" vive en este proceso; "s" no esta.
        reg = os.path.join(tmp, "sessions-reg")
        os.makedirs(reg)
        with open(os.path.join(reg, f"{os.getpid()}.json"), "w", encoding="utf-8") as fh:
            json.dump({"pid": os.getpid(), "sessionId": SID_R}, fh)
        with open(os.path.join(reg, "999999.json"), "w", encoding="utf-8") as fh:
            json.dump({"pid": 999999, "sessionId": SID_S}, fh)  # pid muerto: no cuenta
        # Transcripcion de "s": ultima actividad hace 2 dias (respecto a hoy real del reloj del test).
        proyectos = os.path.join(tmp, "projects")
        carpeta = os.path.join(proyectos, re.sub(r"[^A-Za-z0-9]", "-", os.path.abspath(tmp)))
        os.makedirs(carpeta)
        tx_s = os.path.join(carpeta, SID_S + ".jsonl")
        with open(tx_s, "w", encoding="utf-8") as fh:
            fh.write("{}\n")
        hace = time.time() - 2 * 86400 - 60
        os.utime(tx_s, (hace, hace))
        hoy_real = time.strftime("%Y-%m-%d")

        dr = correr(mem, lib, "--hoy", hoy_real, "--sessions-dir", reg, "--projects-root", proyectos)
        # Windows no usa el registro de procesos (os.kill(pid, 0) manda CTRL_C_EVENT y no hay `ps`):
        # alli manda la transcripcion y las pruebas del registro no aplican.
        REGISTRO = os.name != "nt"
        check("windows: con registro, manda la transcripcion" if not REGISTRO else "registro: fuente proceso",
              {g["slug"]: g for g in dr["planes"]}["2026-10-13-s"]["ventana"]["fuente"] ==
              ("proceso" if REGISTRO else "transcripcion"))
        lista = {i["id"]: i for i in dr["items"] + dr["resto"]}
        planes = {g["slug"]: g for g in dr["planes"]}
        check("planes: una fila por ficha, la mas reciente arriba",
              [g["slug"] for g in dr["planes"]] == ["2026-10-13-s", "2026-10-12-r", "2026-10-11-borrada"])
        r = planes.get("2026-10-12-r", {})
        check("planes: los pendientes de la ficha, en el orden del archivo",
              [p["id"] for p in r.get("pendientes", [])] == ["p-1313131313", "p-1212121212"])
        check("planes: trae el snippet sin fence ni otras secciones",
              r.get("snippet") == "Retomamos: r.\n\nProximo paso: hacer p-1212121212.")
        check("planes: proximo paso, ficha y desde", (r.get("proximo_paso"), r.get("ficha"), r.get("desde")) ==
              ("Proximo paso: hacer p-1212121212.", "memory/sessions/2026-10-12-r.md", "2026-10-12"))
        check("planes: session_id de la cabecera", r.get("session_id") == SID_R)
        REGISTRO and check("ventana: proceso vivo con ese id = abierta",
              r.get("ventana") == {"estado": "abierta", "dias": 0, "fuente": "proceso", "aqui": False,
                                    "retomada": False})
        s_ = planes.get("2026-10-13-s", {})
        REGISTRO and check("ventana: pid muerto = cerrada, con los dias desde su transcripcion",
              s_.get("ventana") == {"estado": "cerrada", "dias": 2, "fuente": "proceso", "aqui": False,
                                     "retomada": False})
        b = planes.get("2026-10-11-borrada", {})
        check("planes: ficha borrada sigue, sin snippet ni ventana",
              b.get("snippet") is None and b.get("ventana", {}).get("estado") is None)
        check("planes: fecha futura y _revisar futuro no entran",
              not ({"p-5656565656", "p-7878787878"} & {p["id"] for g in dr["planes"] for p in g["pendientes"]}))
        check("planes: un paso de snippet no sale en la lista (ni vence ni alta)",
              not ({"p-1212121212", "p-1313131313", "p-3434343434"} & set(lista)))
        v = lista.get("p-6767676767", {})
        check("planes: con _revisar pasado tambien vence (la fecha es real)",
              v.get("grupo") == "vence" and v.get("motivo") == "vencido 2026-10-06")
        check("vence: solo _revisar, motivo de siempre",
              all(i["motivo"].startswith(("vence hoy", "vencido")) for i in lista.values() if i["grupo"] == "vence"))
        # Tope: 4 vencidos + el que vence + 5 Alta libres = 10 candidatos; 7 en items, y los 3 planes
        # aparte, todos.
        check("tope: los planes no comen sitio de la lista",
              len(dr["items"]) == 7 and dr["quedan"] == 3 and len(dr["planes"]) == 3)
        check("resumen: cuenta planes", dr["resumen"].get("planes") == 3)
        check("resumen: vencidos solo de _revisar", dr["resumen"]["vencidos"] == 5)
        da = correr(mem, lib, "--hoy", hoy_real, "--sessions-dir", reg, "--projects-root", proyectos,
                    "--session-id", SID_R)
        check("ventana: la sesion actual dice aqui",
              {g["slug"]: g for g in da["planes"]}["2026-10-12-r"]["ventana"]["aqui"] is True)
        # Sin registro de procesos: solo la transcripcion. "s" lleva 2 dias sin actividad.
        dt = correr(mem, lib, "--hoy", hoy_real, "--sessions-dir", os.path.join(tmp, "no-existe"),
                    "--projects-root", proyectos)
        st = {g["slug"]: g for g in dt["planes"]}
        check("ventana sin registro: sin actividad N d",
              st["2026-10-13-s"]["ventana"] == {"estado": "sin actividad", "dias": 2, "fuente": "transcripcion",
                                                 "aqui": False, "retomada": False})
        os.utime(tx_s, None)
        dt2 = correr(mem, lib, "--hoy", hoy_real, "--sessions-dir", os.path.join(tmp, "no-existe"),
                     "--projects-root", proyectos)
        check("ventana sin registro: actividad reciente = activa",
              {g["slug"]: g for g in dt2["planes"]}["2026-10-13-s"]["ventana"]["estado"] == "activa")
        # Retomada en otra ventana viva (hallazgo del revisor de 0.3.0): la sesion que escribio la
        # ficha cerro, pero otra pego su paso. Medido: el relevo de lookout lo trae en el system prompt
        # (`prompt_snapshot`, en el byte 279397 de una transcripcion real, tras la cabeza de 256 KB);
        # un snippet pegado a mano llega como prompt de la persona. Solo cuentan ventanas del proyecto
        # o de un worktree suyo; un pid reusado (procStart que no cuadra) no es una ventana viva.
        SID_X, SID_Y, SID_Z, SID_W = ("aaaaaaaa-0000-0000-0000-00000000000" + c for c in "xyzw")
        relleno = "".join(json.dumps({"type": "progress", "n": k, "pad": "x" * 200}) + "\n" for k in range(1500))

        def tx_de(cwd, sid, lineas):
            d = os.path.join(proyectos, re.sub(r"[^A-Za-z0-9]", "-", os.path.abspath(cwd)))
            os.makedirs(d, exist_ok=True)
            with open(os.path.join(d, sid + ".jsonl"), "w", encoding="utf-8") as fh:
                fh.write(lineas)

        def registra(nombre, sid, cwd, **extra):
            with open(os.path.join(reg, nombre), "w", encoding="utf-8") as fh:
                json.dump({"pid": os.getpid(), "sessionId": sid, "cwd": cwd, **extra}, fh)

        snap = json.dumps({"type": "attachment", "attachment": {"type": "prompt_snapshot", "systemPrompt": [
            "You are...", "## Relevo\nLa sesion anterior termino.\n\n```\nRetomamos: s.\n\n"
            "Proximo paso: hacer p-6767676767.\n```\n"]}}) + "\n"
        otro = os.path.join(tmp, "otro-proyecto")
        os.makedirs(otro)
        tx_de(otro, SID_Z, snap)
        registra("z.json", SID_Z, otro)
        registra("w.json", SID_W, tmp, procStart="Mon Jan  1 00:00:00 2001")
        tx_de(tmp, SID_W, snap)
        dz = correr(mem, lib, "--hoy", hoy_real, "--sessions-dir", reg, "--projects-root", proyectos)
        REGISTRO and check("retomada: una ventana de otro proyecto o con pid reusado no cuenta",
              {g["slug"]: g for g in dz["planes"]}["2026-10-13-s"]["ventana"]["estado"] == "cerrada")
        # Linux: procStart es el starttime de /proc como CADENA de digitos (forma real, con comillas).
        if os.path.exists("/proc/self/stat"):
            tick = int(open("/proc/self/stat").read().rsplit(")", 1)[1].split()[19])
            registra("w.json", SID_W, tmp, procStart=str(tick + 500))
            dl = correr(mem, lib, "--hoy", hoy_real, "--sessions-dir", reg, "--projects-root", proyectos)
            REGISTRO and check("retomada: procStart de Linux (tick) que no cuadra no cuenta",
                  {g["slug"]: g for g in dl["planes"]}["2026-10-13-s"]["ventana"]["estado"] == "cerrada")
            registra("w.json", SID_W, tmp, procStart=str(tick))
            dl = correr(mem, lib, "--hoy", hoy_real, "--sessions-dir", reg, "--projects-root", proyectos)
            REGISTRO and check("retomada: procStart de Linux (tick) que cuadra cuenta",
                  {g["slug"]: g for g in dl["planes"]}["2026-10-13-s"]["ventana"]["estado"] == "abierta")
            registra("w.json", SID_W, tmp, procStart="Mon Jan  1 00:00:00 2001")
        tx_de(tmp, SID_X, relleno + snap)
        registra("x.json", SID_X, tmp)
        wt = os.path.join(tmp, "wt")
        os.makedirs(wt)
        with open(os.path.join(wt, ".git"), "w", encoding="utf-8") as fh:
            fh.write(f"gitdir: {os.path.join(tmp, '.git', 'worktrees', 'wt')}\n")
        tx_de(wt, SID_Y, json.dumps({"type": "user", "origin": {"kind": "human"}, "message": {
            "content": "Retomamos: borrada.\n\nProximo paso: hacer p-3434343434."}}) + "\n")
        registra("y.json", SID_Y, wt)
        dx = correr(mem, lib, "--hoy", hoy_real, "--sessions-dir", reg, "--projects-root", proyectos,
                    "--session-id", SID_Y)
        px = {g["slug"]: g for g in dx["planes"]}
        REGISTRO and check("retomada: el snippet del system prompt, tras la cabeza, abre el plan",
              px["2026-10-13-s"]["ventana"] == {"estado": "abierta", "dias": 0, "fuente": "proceso",
                                                "aqui": False, "retomada": True})
        REGISTRO and check("retomada: un snippet pegado en un worktree, sin session_id en la ficha; aqui",
              px["2026-10-11-borrada"]["ventana"] == {"estado": "abierta", "dias": 0, "fuente": "proceso",
                                                      "aqui": True, "retomada": True})
        check("retomada: la que escribio la ficha sigue mandando si vive",
              px["2026-10-12-r"]["ventana"]["retomada"] is False)

        # Un registro que existe pero no tiene ninguna entrada legible (vacio, roto) no prueba nada:
        # manda la transcripcion, como sin registro (hallazgo del revisor externo de 0.3.0).
        for nombre, contenido in (("vacio", None), ("roto", "{no-json")):
            r_ = os.path.join(tmp, "reg-" + nombre)
            os.makedirs(r_)
            if contenido:
                with open(os.path.join(r_, "malo.json"), "w", encoding="utf-8") as fh:
                    fh.write(contenido)
            dv = correr(mem, lib, "--hoy", hoy_real, "--sessions-dir", r_, "--projects-root", proyectos)
            check(f"registro {nombre}: manda la transcripcion (activa), no cerrada",
                  {g["slug"]: g for g in dv["planes"]}["2026-10-13-s"]["ventana"]["fuente"] == "transcripcion"
                  and {g["slug"]: g for g in dv["planes"]}["2026-10-13-s"]["ventana"]["estado"] == "activa")

        dh = correr(mem, lib, "--hoy", "2026-10-11", "--sessions-dir", reg, "--projects-root", proyectos)
        check("planes: antes de su fecha no hay plan", [g["slug"] for g in dh["planes"]] == ["2026-10-11-borrada"])

        # Sin `_id` la libreria no devuelve el item y el panel no puede mostrarlo. Medido 2026-10-18
        # en 39 proyectos: 1395 de 2987 abiertos sin id, y en 18 el panel decia "0 abiertos" sin
        # avisar. `sin_id` cuenta las lineas `- [ ]` que el panel no ve; el pane lo pinta.
        mem_s = os.path.join(tmp, "sin-id", "memory")
        os.makedirs(mem_s)
        with open(os.path.join(mem_s, "_pendientes.md"), "w", encoding="utf-8") as fh:
            fh.write("# Pendientes\n\n## Alta prioridad\n\n"
                     "- [ ] Alta sin id — _creado: 2026-10-01_\n"
                     "- [ ] Alta con id — _creado: 2026-10-01_ — _id: p-abababab01_\n"
                     "- [x] Cerrado sin id — _creado: 2026-10-01_\n\n"
                     "## Media prioridad\n\n  - [ ] Media sin id, indentada\n")
        ds = correr(mem_s, lib)
        check("sin id: abiertos cuenta solo lo que el panel ve", ds["resumen"]["abiertos"] == 1)
        check("sin id: resumen dice cuantos no ve", ds["resumen"].get("sin_id") == 2)
        check("sin id: con todos con id da 0", d["resumen"].get("sin_id") == 0)

    for f in fallos:
        print("FALLA:", f)
    if fallos:
        return 1
    print(f"OK {n}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
