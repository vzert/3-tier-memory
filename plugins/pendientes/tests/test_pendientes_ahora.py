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
- [ ] Media vencida otra — _creado: 2026-09-01_ — _id: p-0000000000_ — _revisar: 2026-10-11_

## Baja prioridad

- [ ] Baja suelta — _creado: 2026-09-01_ — _id: p-cccccccccc_
"""

FICHA_VIEJA = "# a\n\n## Como retomar\n\nProximo paso: hacer p-5555555555\n"
FICHA = "# b\n\n## Como retomar\n\n```\nRetomamos: x\nProximo paso: implementar p-aaaaaaaaaa ya\n```\n"


def correr(mem, lib, *extra):
    out = subprocess.run([sys.executable, "-I", SCRIPT, "--memory-dir", mem, "--hoy", "2026-10-13",
                          "--lib", lib, *extra], capture_output=True, text=True)
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
        with open(os.path.join(mem, "plans", "plan-x.md"), "w", encoding="utf-8") as fh:
            fh.write("# plan x\n")
        with open(os.path.join(mem, "_pendientes.md"), "w", encoding="utf-8") as fh:
            fh.write(PEND)
        for nombre, texto in (("2026-10-12-a.md", FICHA_VIEJA), ("2026-10-13-b.md", FICHA)):
            with open(os.path.join(mem, "sessions", nombre), "w", encoding="utf-8") as fh:
                fh.write(texto)

        d = correr(mem, lib)
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
                                          "bloqueados": 1})

        # Con tope 3: el cupo del hilo (3) no deja sitio, pero el hilo sigue primero.
        d3 = correr(mem, lib, "--max", "3")
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
        check("sin sesion ni transcripciones: solo commits",
              all((i["en_curso"] or {}).get("donde") in (None, "commits") for i in sin["items"]))

        # Un paso que cita lo bloqueado, lo de revisar futuro, lo de fecha futura y lo que vence
        # hoy: nada de eso es "proximo paso"; la Baja libre si.
        with open(os.path.join(mem, "sessions", "2026-10-14-c.md"), "w", encoding="utf-8") as fh:
            fh.write("# c\n\n## Como retomar\n\nProximo paso: p-1111111111 p-2222222222 "
                     "p-3333333333 p-7777777777 p-cccccccccc\n")
        dp = correr(mem, lib)
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

    for f in fallos:
        print("FALLA:", f)
    if fallos:
        return 1
    print(f"OK {n}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
