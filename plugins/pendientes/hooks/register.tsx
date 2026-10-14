import { atom, read, update } from 'claude-code'
import type { EngineInterface, Register } from 'claude-code'

import type { Ahora, Pendiente, Titulos } from '../types'

const PANE = 'pendientes-ahora'
const TITULO = 'Qué hago ahora'
const STORE_TITULOS = 'titulos'
const STORE_FALLO = 'titulos_fallo'
const ESPERA_FALLO_MS = 30 * 60 * 1000
const FALLO_NINGUNO = -1
const TANDA = 12
const ANCHO_TARJETA = 64
const BANDA_ANCHO = 44
const ahora = atom({ plugin: 'pendientes', key: 'ahora' } as const, null as Ahora | null)
const titulos = atom({ plugin: 'pendientes', key: 'titulos' } as const, {} as Titulos)
const abierto = atom({ plugin: 'pendientes', key: 'abierto' } as const, false)
const expandido = atom({ plugin: 'pendientes', key: 'expandido' } as const, false)

// Una sola tanda de titulos a la vez: la variable se pierde en una recarga, y no pasa nada.
let generando = false

type Clave = 'paso' | 'hilo' | 'vence' | 'alta' | 'curso'
const SECCIONES: { clave: Clave; titulo: string }[] = [
  { clave: 'paso', titulo: 'SIGUIENTE' },
  { clave: 'hilo', titulo: 'RELACIONADO AL TRABAJO ACTUAL' },
  { clave: 'vence', titulo: 'VENCEN' },
  { clave: 'alta', titulo: 'ALTA PRIORIDAD' },
  { clave: 'curso', titulo: 'EN CURSO' },
]

// Lo que alguien ya esta haciendo no se ofrece como siguiente: va a EN CURSO, al final.
function seccion(p: Pendiente): Clave {
  if (p.en_curso) return 'curso'
  if (p.grupo === 'hilo') return p.motivo === 'proximo paso' ? 'paso' : 'hilo'
  return p.grupo
}

function corta(texto: string | null | undefined, ancho: number): string {
  const t = texto ?? ''
  if (ancho <= 1) return ''
  return t.length <= ancho ? t : t.slice(0, ancho - 1).trimEnd() + '…'
}

// Huella corta del texto: si el pendiente cambia, el titulo se vuelve a pedir.
export function huella(texto: string): string {
  let h = 5381
  for (let i = 0; i < texto.length; i++) h = ((h << 5) + h + texto.charCodeAt(i)) | 0
  return (h >>> 0).toString(36)
}

// El titulo del modelo si es de este texto; si no, el corte automatico. Nunca vacio: un estado
// de una version anterior del mod (sin titulo_auto) no puede romper el dibujo.
export function tituloDe(p: Pendiente, cache: Titulos): string {
  const c = cache[p.id]
  if (c && p.texto && c.h === huella(p.texto)) return c.t
  return p.titulo_auto || p.corto || p.texto || p.id
}

// La fecha, como texto y no solo como color: "hoy", "17 d". En curso: donde.
export function insignia(p: Pendiente): { texto: string; color: 'warning' | 'error' | 'suggestion' } | null {
  const c = p.en_curso
  if (c) {
    const hace = c.hace_min !== undefined && c.hace_min > 0 ? ` hace ${c.hace_min} min` : ''
    const donde = c.donde === 'aqui' ? 'aquí' : c.donde === 'otra sesion' ? `otra sesión${hace}` : ''
    const commits = c.n > 0 ? `${c.n} commit${c.n === 1 ? '' : 's'}` : ''
    return { texto: `◐ ${[donde, commits].filter(Boolean).join(' · ')}`, color: 'suggestion' }
  }
  if (p.dias === null || p.dias === undefined) return null
  return p.dias === 0 ? { texto: '● hoy', color: 'warning' } : { texto: `● ${p.dias} d`, color: 'error' }
}

// Filas que ocupa una lista: por seccion su cabecera y la linea en blanco, por tarjeta dos.
export function filasDe(lista: Pendiente[]): number {
  const secciones = new Set(lista.map(seccion)).size
  return secciones * 2 + lista.length * 2
}

// Los que caben en `filas` (menos la del pie), en orden: primero los del reparto por cupos,
// luego el resto. Siempre al menos uno.
export function queCabe(lista: Pendiente[], filas: number): Pendiente[] {
  const out: Pendiente[] = []
  for (const p of lista) {
    if (out.length > 0 && filasDe([...out, p]) > filas - 1) break
    out.push(p)
  }
  return out
}

async function refrescar($: EngineInterface): Promise<void> {
  let valor: Ahora
  try {
    const raiz = await $.session.root()
    // Sin memoria 3-tier no hay nada que mostrar: ni python ni banda, en cada turno.
    const pendientesMd = `${raiz}/memory/_pendientes.md`
    if (!(await $.fs.exists(pendientesMd))) {
      await update($, ahora, () => ({ ok: false, error: `no hay ${pendientesMd}` }))
      return
    }
    const sesion = await $.session.id()
    const corrida = await $.process.run(
      [
        'python3',
        '-I',
        `${$.plugin.root}/bin/pendientes-ahora.py`,
        '--memory-dir',
        `${raiz}/memory`,
        '--session-id',
        sesion,
      ],
      { timeoutMs: 15000 },
    )
    valor =
      corrida.exitCode === 0
        ? (JSON.parse(corrida.stdout) as Ahora)
        : { ok: false, error: `el script salio ${corrida.exitCode}: ${corrida.stderr.slice(0, 200)}` }
  } catch (err) {
    valor = { ok: false, error: `no pude correr el script: ${String(err).slice(0, 200)}` }
  }
  await update($, ahora, () => valor)
  // Fuera del dispatch: la llamada al modelo no frena el arranque ni el fin de turno.
  try {
    $.clock.after(0, () => void titular($))
  } catch {
    // Sin reloj no hay titulos del modelo; el corte automatico basta.
  }
}

// Pide a Haiku un titulo corto para los pendientes que no lo tienen (o cuyo texto cambio),
// todos en una sola llamada, y los guarda por id en $.store. Cada pendiente se pide UNA vez por
// texto: un titulo que no sirve (vacio, > 80 caracteres, ausente) se guarda como el corte
// automatico y no se vuelve a pedir. Si la llamada entera falla (sin respuesta, JSON roto), no se
// reintenta hasta pasados ESPERA_FALLO_MS: sin eso, cada fin de turno volveria a llamar al modelo.
export async function titular($: EngineInterface): Promise<void> {
  if (generando) return
  generando = true
  try {
    const guardados = ((await $.store.get(STORE_TITULOS)) ?? {}) as Titulos
    const a = await read($, ahora)
    const todos = [...(a?.items ?? []), ...(a?.resto ?? [])]
    const faltan = todos.filter(p => p.texto && guardados[p.id]?.h !== huella(p.texto))
    const ahoraMs = await $.clock.now()
    // Sin fallo guardado (ausente o borrado) no hay espera: un reloj que empieza en 0 no es un fallo.
    const fallo = await $.store.get(STORE_FALLO)
    const enEspera = typeof fallo === 'number' && fallo !== FALLO_NINGUNO && ahoraMs - fallo < ESPERA_FALLO_MS
    // En tandas de TANDA: una respuesta larga se cortaria y su JSON no se podria leer. Cada tanda
    // que llega se guarda; la primera que falla para todo y abre la espera.
    for (let i = 0; i < faltan.length && !enEspera; i += TANDA) {
      const tanda = faltan.slice(i, i + TANDA)
      const lista = tanda.map(p => `${p.id}\t${p.texto}`).join('\n')
      const r = await $.model.complete({
        model: 'haiku',
        system:
          'Resumes tareas pendientes en titulos para una lista. Responde SOLO un objeto JSON {"id": "titulo"}. ' +
          'Cada titulo: espanol, de 3 a 6 palabras, empieza por verbo en infinitivo, sin ids, sin fechas, ' +
          'sin el tema inicial tipo "Snippet de cierre:", sin punto final. Conserva nombres de comandos o versiones si son la clave.',
        prompt: `Una tarea por linea (id TAB texto):\n${lista}`,
        maxTokens: 900,
        timeoutMs: 30000,
      })
      let nuevos: Record<string, unknown> | null = null
      if (r.isAnswered) {
        try {
          nuevos = JSON.parse(r.text.slice(r.text.indexOf('{'), r.text.lastIndexOf('}') + 1)) as Record<string, unknown>
        } catch {
          nuevos = null
        }
      }
      if (nuevos === null) {
        await $.store.set(STORE_FALLO, ahoraMs)
        break
      }
      for (const p of tanda) {
        const t = nuevos[p.id]
        const sirve = typeof t === 'string' && t.trim().length > 0 && t.length <= 80
        guardados[p.id] = { h: huella(p.texto), t: sirve ? t.trim() : p.titulo_auto || p.texto }
      }
      await $.store.set(STORE_TITULOS, guardados)
      await $.store.set(STORE_FALLO, FALLO_NINGUNO)
    }
    await update($, titulos, () => ({ ...guardados }))
  } catch {
    // Sin titulos del modelo: el panel ya muestra el corte automatico.
  } finally {
    generando = false
  }
}

async function rellenar($: EngineInterface, p: Pendiente): Promise<void> {
  const hecho = await $.prompt.fill({ text: `${p.id}: ${p.texto}`, mode: 'insert' })
  if (!hecho.isFilled) $.ui.toast(`No pude escribir en el prompt (${hecho.cause ?? 'sin motivo'}).`)
}

async function abrir($: EngineInterface): Promise<string> {
  await refrescar($)
  const abre = await $.ui.open({ id: PANE, title: TITULO })
  if (abre.isPlaced) await update($, abierto, () => true)
  return abre.isPlaced
    ? 'Panel de pendientes abierto. Haz clic en un pendiente para pasarlo al prompt.'
    : `El panel espera sitio: ${abre.reason ?? 'ensancha la terminal'}.`
}

export const register: Register = on => {
  on('session.start', async ($, e, next) => {
    await $.command.register({
      name: 'pendientes-ahora',
      description: 'Abre o cierra el panel de pendientes "qué hago ahora"',
    })
    const yaAbierto = (await $.ui.panes()).some(pane => pane.id === PANE)
    await update($, abierto, () => yaAbierto)
    await refrescar($)

    return next(e)
  })

  // Tras cada turno: un /checkpoint-3t o un pendiente resuelto cambian la lista.
  on('turn.complete', async ($, e, next) => {
    const hecho = await next(e)
    await refrescar($)

    return hecho
  })

  // Cerrado por la persona (la marca del panel, Esc) o por nosotros: la banda vuelve.
  on('ui.close', async ($, e, next) => {
    const hecho = await next(e)
    if (e.id === PANE) await update($, abierto, () => false)

    return hecho
  })

  on('command.run', { command: 'pendientes-ahora' }, async $ => {
    const yaAbierto = (await $.ui.panes()).some(pane => pane.id === PANE)
    if (yaAbierto) {
      await $.ui.close({ id: PANE })
      await update($, abierto, () => false)
      return { text: 'Panel de pendientes cerrado.' }
    }
    return { text: await abrir($) }
  })

  // La banda sobre el prompt: solo con el panel cerrado. Un clic lo abre.
  on('ui.render', { component: 'AbovePrompt' }, async ($, e, next) => {
    const a = await read($, ahora)
    const items = a?.ok ? (a.items ?? []) : []
    if (e.props.hasSurvey || (await read($, abierto)) || items.length === 0) return next(e)

    const { Box, Text, Button } = $.ui.resolve(e)
    const r = a?.resumen
    const avisos: { texto: string; color: 'warning' | 'error' }[] = []
    if (r && r.hoy > 0) avisos.push({ texto: `● ${r.hoy} hoy`, color: 'warning' })
    if (r && r.vencidos > 0) avisos.push({ texto: `● ${r.vencidos} vencidos`, color: 'error' })
    // Tarjeta compacta pegada a la derecha: marco redondeado tenue que se ilumina al pasar el
    // raton. Arriba el nombre y los abiertos; abajo los avisos y "abrir".
    const ancho = Math.min(BANDA_ANCHO, Math.max(24, e.props.bodyColumns))

    return (
      <Box flexDirection="row" justifyContent="flex-end" width={e.props.bodyColumns}>
        <Box
          key="tarjeta"
          flexDirection="column"
          borderStyle="round"
          borderDimColor
          hover={{ borderColor: 'claude' }}
          paddingX={1}
          width={ancho}
        >
          <Box flexDirection="row" justifyContent="space-between">
            <Button key="abrir" plain onPress={() => void abrir($)}>
              <Text color="claude">▸ </Text>
              <Text bold>Pendientes 3-tier</Text>
            </Button>
            {r ? <Text dimColor>{`${r.abiertos} abiertos`}</Text> : null}
          </Box>
          <Box flexDirection="row" justifyContent="space-between">
            <Text>
              {'  '}
              {avisos.map(x => (
                <Text color={x.color}>{`${x.texto}  `}</Text>
              ))}
            </Text>
            <Button key="abrir-2" plain dimColor onPress={() => void abrir($)}>
              abrir
            </Button>
          </Box>
        </Box>
      </Box>
    )
  })

  on('ui.render', { component: 'Pane', requestId: PANE }, async ($, e) => {
    const { Box, Text, Button } = $.ui.resolve(e)
    const a = await read($, ahora)
    const cache = await read($, titulos)
    const verTodo = await read($, expandido)
    // paddingX={1} abajo: dos columnas menos que el cuerpo; y no mas ancho que una tarjeta,
    // para que la fecha quede cerca del titulo en un panel ancho.
    const ancho = Math.min(ANCHO_TARJETA, Math.max(24, e.props.bodyColumns - 2))

    if (a === null) return <Text>Cargando…</Text>
    if (!a.ok) {
      return (
        <Box flexDirection="column">
          <Text color="warning">{corta(a.error ?? 'error', ancho * 3)}</Text>
          <Button key="refrescar" onPress={() => refrescar($)}>actualizar</Button>
        </Box>
      )
    }

    // Llena el alto del panel: todos los candidatos que quepan, en el orden del reparto.
    const candidatos = [...(a.items ?? []), ...(a.resto ?? [])]
    const filas = e.props.scroll?.bodyRows ?? 24
    const elegidos = verTodo ? candidatos : queCabe(candidatos, filas)
    const ids = new Set(elegidos.map(p => p.id))
    // Los grupos se pintan en su orden aunque el relleno venga del resto.
    const items = candidatos.filter(p => ids.has(p.id))
    const fuera = candidatos.length - items.length
    // Totales por seccion sobre todos los candidatos: "2 de 6" = 2 a la vista de 6.
    const totales: Record<string, number> = {}
    for (const p of candidatos) totales[seccion(p)] = (totales[seccion(p)] ?? 0) + 1

    // Una tarjeta: titulo (clic = al prompt) con la fecha a la derecha, y debajo los datos (texto).
    const tarjeta = (p: Pendiente, esPaso: boolean) => {
      const barra = esPaso ? '▌ ' : '  '
      const ins = insignia(p)
      const sitio = ancho - barra.length - (ins ? ins.texto.length + 1 : 0)
      // Igual para todos: prioridad, id corto y antiguedad. (El tema "Snippet de cierre:" que
      // traen algunos textos no es una categoria del sistema: no se muestra.)
      const edad = p.edad === null || p.edad === undefined ? null : p.edad === 0 ? 'de hoy' : `hace ${p.edad} d`
      const meta = [p.prio, p.id.slice(0, 8), edad].filter(Boolean).join(' · ')
      return (
        <Box key={`c-${p.id}`} flexDirection="column" width={ancho}>
          <Box flexDirection="row" justifyContent="space-between">
            <Button key={p.id} plain onPress={() => rellenar($, p)}>
              <Text color="claude">{barra}</Text>
              <Text bold={esPaso}>{corta(tituloDe(p, cache), sitio)}</Text>
            </Button>
            {ins ? <Text color={ins.color}>{ins.texto}</Text> : null}
          </Box>
          {/* Solo el titulo es clicable: la linea de datos es texto, para que no parezcan dos botones. */}
          <Text>
            <Text color="claude">{barra}</Text>
            <Text dimColor>{corta(meta, ancho - barra.length)}</Text>
          </Text>
        </Box>
      )
    }

    const bloques: unknown[] = []
    for (const { clave, titulo } of SECCIONES) {
      const del = items.filter(p => seccion(p) === clave)
      if (del.length === 0) continue
      const total = totales[clave] ?? del.length
      // El contador va aparte, a la derecha y tenue: "RELACIONADO … 2" no debe leerse "paso 2".
      const cuenta = clave === 'paso' ? '' : total > del.length ? `${del.length} de ${total}` : `${del.length}`
      bloques.push(
        <Box key={`s-${clave}`} flexDirection="column" marginBottom={1}>
          <Box key={`h-${clave}`} flexDirection="row" justifyContent="space-between" width={ancho}>
            <Text bold color={clave === 'paso' ? 'claude' : undefined}>
              {clave === 'paso' ? '▌ ' : ''}
              {titulo}
            </Text>
            {cuenta ? <Text dimColor>{cuenta}</Text> : null}
          </Box>
          {del.map(p => tarjeta(p, clave === 'paso'))}
        </Box>,
      )
    }

    const pie = a.resumen ? `${a.resumen.abiertos} abiertos · clic: al prompt` : 'clic: al prompt'
    const plegable = verTodo || fuera > 0
    return (
      <Box flexDirection="column" paddingX={1}>
        {items.length === 0 ? <Text>Nada urgente en este proyecto.</Text> : bloques}
        <Box flexDirection="row" justifyContent="space-between" width={ancho}>
          <Box flexDirection="row">
            {plegable ? (
              <Button key="mas" plain onPress={() => update($, expandido, v => !v)}>
                <Text color="claude">{verTodo ? 'ver menos' : `+${fuera} más`}</Text>
              </Button>
            ) : null}
            <Text dimColor>{corta(`${plegable ? ' · ' : ''}${pie}`, ancho - 26)}</Text>
          </Box>
          <Button key="refrescar" plain dimColor hotkey="r" onPress={() => refrescar($)}>
            actualizar
          </Button>
        </Box>
      </Box>
    )
  })
}
