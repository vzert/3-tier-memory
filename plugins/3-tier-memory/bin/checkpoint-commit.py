#!/usr/bin/env python3
"""
3-tier-memory plugin: el commit de un checkpoint lleva solo lo de SU sesion (2.52.0).

POR QUE EXISTE. Hasta 2.51.0 Step 6 hacia `git add memory/` + `git commit`. Con varias sesiones en
el mismo checkout eso barre lo de las demas. Medido:
  - Una instalacion real (2026-10-06): el checkpoint de una sesion metio 19 archivos ajenos (fichas
    de sesiones vivas, colas de Step 8 de sesiones viejas, un plan de otra sesion). Del 28-sep al
    6-oct, 26 de 125 commits con fichas llevaron fichas de otras sesiones.
  - Banco f9d (de otro proyecto, 100 ordenes al azar x 3 sesiones, eventos y compactador reales):
    6,4 archivos de otra sesion por corrida, en 100 de 100; en 28 de 100 uno era una ficha que su
    dueno aun escribia. Con `git add` de rutas propias pero `git commit` sin rutas: 2,7. El indice
    de git TAMBIEN es compartido: hace falta `git commit --only -- <rutas>`.

QUE COMMITEA. memory/ se parte en dos clases:
  - POR SESION: sessions/, plans/, research/, handoffs/. De ahi entra solo lo de esta sesion: la
    ficha (--session-file) y los plans/research que la ficha enlaza en sus secciones `## Plans` y
    `## Research` (Step 5 ya obliga a ponerlos ahi). Mas --propio para rutas sueltas. Un plan que
    dos sesiones vivas registran a la vez es de las dos: lo commitea la que llegue primero.
  - COMPARTIDA: todo lo demas de memory/ (indices _*.md, MEMORY.md, pendientes/, learnings/,
    .journal/ segun su .gitignore, .memory-config...). La escribe el compactador para todas las
    sesiones; que entren filas de otras es lo esperado.
  Con --solo-compartidos (consolidate, migrate-learnings, save-learning) no entra nada POR SESION.
  Nunca se usa un pathspec de exclusion: en git una exclusion gana tambien sobre una ruta incluida
  a mano (medido: `memory ':(exclude)memory/sessions' memory/sessions/a.md` deja fuera a a.md).

COMO. En el repo que contiene memory/ (en un worktree enlazado, la memoria vive en el principal:
memory-home.sh), bajo el candado del compactador si lo consigue en 10 s (para no fotografiar un
indice a medio compactar; si no, commitea igual e imprime `AVISO candado-ocupado`):
  git add -- <rutas>                      (las nuevas, sin trackear, necesitan entrar al indice)
  git commit --only -m MSG -- <rutas>     (solo esas rutas; lo que otro dejo en el indice se queda)
Reintenta si otro proceso tiene .git/index.lock. Nunca --amend, nunca stash, nunca cambia de rama.

Es best-effort, como el Step 6 de siempre: sale 0 y explica en una linea por que no commiteo.
Salida (ultima linea):
  COMMIT hash=<corto> rama=<rama> archivos=<N> propios=<N> compartidos=<N>
  COMMIT skip=<motivo> [detalle]
Antes, una linea `  + <ruta>` por archivo del commit.

Uso:
  checkpoint-commit.py --memory-dir DIR --session-file FICHA --mensaje MSG [--propio RUTA ...]
  checkpoint-commit.py --memory-dir DIR --solo-compartidos --mensaje MSG [--propio RUTA ...]
  checkpoint-commit.py ... --listar      (solo imprime las rutas que entrarian; no toca git)
"""
# sella-huellas: no (solo git add/commit de rutas; no escribe ningun fichero de memory/)
import argparse
import importlib.util
import os
import re
import subprocess
import sys
import time

for _f in (sys.stdout, sys.stderr):
    if hasattr(_f, "reconfigure"):
        _f.reconfigure(encoding="utf-8")

POR_SESION = ("sessions", "plans", "research", "handoffs")
# Formas reales de enlazar un plan desde la ficha: `[[plans/plan-x]]`, `[[plans/plan-x|T]]`,
# `[[plans/plan-x\\|T]]` (en tabla), `[[../plans/plan-x]]` (28 en fichas de una instalacion real) y el
# enlace markdown `[T](../plans/plan-x.md)`. Adversario de 2.52.0, ronda 1: solo se reconocia la
# primera, y un plan enlazado con `../` no lo commiteaba nadie.
ENLACE = re.compile(r"\[\[(?:\.\./)?((?:plans|research)/[^\]|#]+)(?:[|#][^\]]*)?\]\]"
                    r"|\]\((?:\.\./)?((?:plans|research)/[^)\s#]+)\)")
COMMIT_OUT = re.compile(r"(?m)^\[[^\]\n]*?([0-9a-f]{7,40})\] ")
BIN = os.path.dirname(os.path.abspath(__file__))


def git(repo, *args, timeout=60):
    # core.quotePath=false: con el valor por defecto git escribe `"Migraci\303\263n/..."` y ninguna
    # ruta con acentos casaba (adversario de 2.52.0, ronda 1: el script salia `sin-cambios` DESPUES
    # del `git add`, y dejaba la ficha en el indice compartido para el siguiente commit de cualquiera).
    return subprocess.run(["git", "-c", "core.quotePath=false", "-C", repo, *args], capture_output=True, text=True,
                          encoding="utf-8", errors="replace", timeout=timeout)


def fin(motivo, detalle=""):
    print(f"COMMIT skip={motivo}" + (f" {detalle}" if detalle else ""))
    sys.exit(0)


SECCIONES = ("## plans", "## research")


def enlazados(mem, ficha):
    """plans/research que la ficha REGISTRA (enlaces dentro de sus secciones `## Plans` y
    `## Research`, donde Step 5 los pone) y existen en disco. Un enlace suelto en otra seccion
    ("ver tambien [[plans/plan-a]]", `## Related`) no hace propio el plan: el adversario de 2.52.0
    (ronda 2) lo hizo con una ficha B que citaba el plan a medias de A, y B se lo llevaba en su
    commit. En las instalaciones reales hay planes enlazados desde 2 o mas fichas en 10 de 10."""
    out = []
    try:
        with open(ficha, encoding="utf-8", errors="replace") as fh:
            lineas = fh.read().splitlines()
    except OSError:
        return out
    dentro, trozos = False, []
    for l in lineas:
        if l.startswith("## ") or l.startswith("# "):
            dentro = l.strip().lower().startswith(SECCIONES)
            continue
        if dentro:
            trozos.append(l)
    for m in ENLACE.finditer("\n".join(trozos)):
        # `[[plans/plan-x\\|Titulo]]` dentro de una tabla lleva la barra escapada: fuera la `\\` final.
        rel = (m.group(1) or m.group(2)).strip().rstrip("\\").strip()
        for cand in (rel, rel + ".md"):
            p = os.path.join(mem, cand)
            if os.path.isfile(p) and p not in out:
                out.append(p)
                break
    return out


def candado(mem):
    """El Lock del compactador, si se puede cargar. None si no (best-effort: se sigue sin el)."""
    try:
        spec = importlib.util.spec_from_file_location("_jc", os.path.join(BIN, "journal-compact.py"))
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        lk = mod.Lock(os.path.join(mem, ".journal"), 10.0)
        return lk if lk.acquire() else None
    except Exception:
        return None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--memory-dir", required=True)
    ap.add_argument("--session-file")
    ap.add_argument("--solo-compartidos", action="store_true")
    ap.add_argument("--propio", action="append", default=[])
    ap.add_argument("--mensaje", default="")
    ap.add_argument("--listar", action="store_true")
    a = ap.parse_args()
    if not a.session_file and not a.solo_compartidos:
        ap.error("falta --session-file o --solo-compartidos")
    if not a.listar and not a.mensaje:
        ap.error("falta --mensaje")

    # realpath: git devuelve rutas reales (/private/tmp en macOS), y se comparan con estas.
    # memhome: en un worktree enlazado, un --memory-dir relativo (`memory`) apunta a la copia del
    # worktree; la memoria es la del principal.
    import memhome
    mem = os.path.realpath(memhome.normaliza(a.memory_dir))
    if not os.path.isdir(mem):
        fin("sin-memoria", mem)

    propias = []
    if a.session_file and not a.solo_compartidos:
        ficha = os.path.realpath(a.session_file)
        if not os.path.isfile(ficha):
            fin("sin-ficha", ficha)
        propias = [ficha] + enlazados(mem, ficha)
    for p in a.propio:
        p = os.path.realpath(p)
        if os.path.exists(p) and p not in propias:
            propias.append(p)
    compartidas = []
    for nombre in sorted(os.listdir(mem)):
        if nombre in POR_SESION:
            continue
        if nombre == ".journal" and os.path.isdir(os.path.join(mem, nombre)):
            # El candado del compactador (.lock, .lock-steal) lo tiene ESTE proceso mientras hace el
            # add: listado a mano fuera, aunque falte el .gitignore del journal (medido: sin el, el
            # commit se llevaba .journal/.lock/owner).
            for sub in sorted(os.listdir(os.path.join(mem, nombre))):
                if not sub.startswith(".lock"):
                    compartidas.append(os.path.join(mem, nombre, sub))
            continue
        compartidas.append(os.path.join(mem, nombre))

    if a.listar:
        for p in propias:
            print(f"propia {os.path.relpath(p, mem)}")
        for p in compartidas:
            print(f"compartida {os.path.relpath(p, mem)}")
        return

    try:
        r = git(mem, "rev-parse", "--show-toplevel")
    except (OSError, subprocess.TimeoutExpired):
        fin("sin-git")
    if r.returncode != 0:
        fin("sin-repo")
    repo = os.path.realpath(r.stdout.strip())
    if git(mem, "check-ignore", "-q", mem).returncode == 0:
        fin("memoria-ignorada", "(memory/ esta en .gitignore: no hay nada que commitear)")
    rama = git(repo, "symbolic-ref", "--short", "-q", "HEAD").stdout.strip()
    if not rama:
        fin("head-suelto", "(HEAD sin rama: un commit aqui no lo veria ninguna rama)")

    # Un merge, rebase o cherry-pick a medias: `git commit --only` falla, pero el `git add` ya habria
    # metido la ficha en el indice del merge y el commit del usuario se la llevaria. Se para antes.
    for marca in ("MERGE_HEAD", "CHERRY_PICK_HEAD", "REVERT_HEAD", "rebase-merge", "rebase-apply"):
        ruta = git(repo, "rev-parse", "--git-path", marca).stdout.strip()
        if ruta and os.path.exists(os.path.join(repo, ruta) if not os.path.isabs(ruta) else ruta):
            fin("operacion-en-curso", f"({marca}: termina o aborta esa operacion y vuelve a correr esto)")

    rutas = propias + compartidas
    # Una ruta ignorada hace fallar `git add` entero: se quitan antes (un directorio no hace falta,
    # git add ya salta lo ignorado de dentro).
    r = subprocess.run(["git", "-c", "core.quotePath=false", "-C", repo, "check-ignore", "--stdin"], input="\n".join(rutas),
                       capture_output=True, text=True, encoding="utf-8", errors="replace")
    ignoradas = {os.path.realpath(l) for l in r.stdout.splitlines() if l.strip()}
    rutas = [p for p in rutas if p not in ignoradas]
    propias = [p for p in propias if p not in ignoradas]
    if not rutas:
        fin("sin-rutas")

    lk = candado(mem)
    if lk is None:
        # Best-effort, como todo Step 6: sin el candado (otro compactador lo tuvo 10 s, o el modulo no
        # carga) el commit sigue, pero lo dice. El riesgo es un indice compartido a medio compactar en
        # este commit; el siguiente commit lo completa.
        print("AVISO candado-ocupado: commit sin el candado del compactador")
    try:
        cambios = git(repo, "status", "--porcelain", "--untracked-files=all", "--", *rutas)
        if cambios.returncode != 0:
            fin("git-status", (cambios.stderr.strip().splitlines() or [""])[-1])
        if not cambios.stdout.strip():
            fin("sin-cambios")
        # Si el commit falla, lo que NUESTRO `git add` cambio en el indice vuelve a las entradas de
        # antes, con los mismos blobs. Lo que ya estaba de otra sesion o del usuario no es nuestro.
        # Sin esto un pre-commit que rechaza o una firma que falla dejaban la ficha y su plan en el
        # indice compartido, y el siguiente `git commit` de cualquiera se los llevaba (adversario,
        # ronda 2); y restaurar solo los NOMBRES dejaba en un indice ya preparado el contenido nuevo
        # de este checkpoint (ronda 3). -z: rutas con tabuladores o saltos de linea, sin comillas.
        foto = git(repo, "ls-files", "-s", "-z", "--", *rutas).stdout

        tras_add = {}   # ruta -> entrada que dejo NUESTRO ultimo `git add` que salio bien

        def entradas(texto):
            return {e.split("\t", 1)[1]: e for e in texto.split("\0") if "\t" in e}

        def deshacer():
            # Solo se toca una ruta cuya entrada sigue siendo la que dejo nuestro `git add`: si otro
            # proceso la preparo despues (o la quito), es suya y se queda (adversario externo, ronda
            # 4: un hook que preparaba un cambio ajeno a mitad del commit lo perdia al restaurar).
            antes = entradas(foto)
            ahora = entradas(git(repo, "ls-files", "-s", "-z", "--", *rutas).stdout)
            entrada = []
            for ruta in set(tras_add) | set(ahora):
                if ahora.get(ruta) != tras_add.get(ruta):
                    continue                      # cambio despues de nuestro add: no es nuestro
                if ruta in antes:
                    if antes[ruta] != ahora.get(ruta):
                        entrada.append(antes[ruta])
                elif ruta in ahora:
                    # mode 0 = quitar la entrada (un archivo nuevo que nuestro `git add` metio)
                    entrada.append("0 " + "0" * 40 + "\t" + ruta)
            if entrada:
                subprocess.run(["git", "-C", repo, "update-index", "-z", "--index-info"],
                               input="\0".join(entrada) + "\0", capture_output=True, text=True,
                               encoding="utf-8", errors="replace")

        def falla(motivo, detalle=""):
            deshacer()
            fin(motivo, detalle)

        ultimo = ""
        for intento in range(8):
            ad = git(repo, "add", "--", *rutas)
            if ad.returncode == 0:
                tras_add.clear()
                tras_add.update(entradas(git(repo, "ls-files", "-s", "-z", "--", *rutas).stdout))
                # `git commit -- <ruta>` falla entero si una ruta no casa con nada que git conozca
                # (medido: un pendientes/ vacio). Entran solo las que tienen algo en el indice o en
                # HEAD; una borrada del disco sigue en HEAD y su borrado entra.
                conocidas = set(git(repo, "ls-files", "--full-name", "--", *rutas).stdout.splitlines())
                conocidas |= set(git(repo, "ls-tree", "-r", "--name-only", "--full-tree", "HEAD", "--",
                                     *[os.path.relpath(p, repo) for p in rutas]).stdout.splitlines())
                spec = []
                for p in rutas:
                    rel = os.path.relpath(p, repo).replace(os.sep, "/")
                    if any(c == rel or c.startswith(rel + "/") for c in conocidas):
                        spec.append(p)
                if not spec:
                    falla("sin-cambios")
                co = git(repo, "commit", "--only", "-m", a.mensaje, "--", *spec)
                if co.returncode == 0:
                    break
                ultimo = (co.stderr or co.stdout).strip()
            else:
                ultimo = ad.stderr.strip()
            if "index.lock" not in ultimo:
                falla("commit-fallo", ultimo.splitlines()[-1] if ultimo else "")
            time.sleep(min(0.25 * (2 ** intento), 2.0))
        else:
            falla("index-lock", "(otro proceso tuvo .git/index.lock todo el tiempo; lo que este "
                                "script anadio al indice se saco)")
    finally:
        if lk is not None:
            try:
                lk.release()
            except Exception:
                pass

    m = COMMIT_OUT.search(co.stdout)
    h = m.group(1)[:7] if m else ""
    if not h:
        fin("sin-hash", "(el commit salio bien pero su salida no trae el hash)")
    nombres = git(repo, "show", "--name-only", "--format=", h).stdout.split("\n")
    nombres = [n for n in nombres if n.strip()]
    for n in nombres:
        print(f"  + {n}")
    prop_rel = {os.path.relpath(p, repo).replace(os.sep, "/") for p in propias}
    n_prop = sum(1 for n in nombres if n in prop_rel)
    print(f"COMMIT hash={h} rama={rama} archivos={len(nombres)} propios={n_prop} "
          f"compartidos={len(nombres) - n_prop}")


if __name__ == "__main__":
    main()
