import { expect, mock, test } from 'claude-code/testing'
import type { On } from 'claude-code'

const base = { corto: '', revisar: null, creado: '2026-09-01', etiqueta: null, dias: null, edad: 42 }
const it = (id: string, grupo: string, motivo: string, extra: Record<string, unknown> = {}) => ({
  ...base, id, prio: 'Media', texto: `Texto ${id}`, titulo_auto: `Titulo ${id}`, grupo, motivo, ...extra,
})
const AHORA = {
  ok: true,
  hoy: '2026-10-13',
  items: [
    it('p-aaaaaaaaaa', 'hilo', 'proximo paso', { prio: 'Alta', texto: 'Snippet de cierre: paso del hilo largo', etiqueta: 'Snippet de cierre', titulo_auto: 'Paso del hilo largo', edad: 0 }),
    it('p-dddddddddd', 'hilo', 'ligado al paso', { etiqueta: 'Snippet de cierre' }),
    it('p-ffffffffff', 'hilo', 'ligado al paso', { etiqueta: 'Snippet de cierre' }),
    it('p-bbbbbbbbbb', 'vence', 'vencido 2026-09-26', { texto: 'Algo que vencio', titulo_auto: 'Algo que vencio', dias: 17 }),
    it('p-eeeeeeeeee', 'vence', 'vence hoy', { prio: 'Alta', dias: 0 }),
    it('p-cccccccccc', 'alta', 'Alta libre', { prio: 'Alta', titulo_auto: 'Una Alta libre' }),
    it('p-gggggggggg', 'alta', 'Alta libre', { prio: 'Alta', en_curso: { donde: 'otra sesion', n: 3, hace_min: 41 } }),
  ],
  resto: [
    it('p-1111111111', 'vence', 'vencido 2026-10-01', { dias: 12 }),
    it('p-2222222222', 'alta', 'Alta libre', { prio: 'Alta' }),
    it('p-3333333333', 'alta', 'Alta libre', { prio: 'Alta' }),
  ],
  quedan: 3,
  candidatos: 8,
  totales: { hilo: 3, vence: 3, alta: 3 },
  resumen: { abiertos: 20, vencidos: 2, hoy: 1, alta: 4, bloqueados: 2 },
}

type Visto = { fills: string[]; argv: string[][]; prompts: string[]; abiertos: number; status: number }

function motor(on: On, salida: string, exitCode = 0, respuesta: string | string[] = '{}', hayMemoria = true): Visto {
  const visto: Visto = { fills: [], argv: [], prompts: [], abiertos: 0, status: 0 }
  let paneles: { id: string }[] = []
  on('session.root', () => ({ value: '/proyecto' }))
  on('fs.exists', () => ({ value: hayMemoria }))
  on('session.id', () => ({ value: 'sesion-x' }))
  on('process.run', (_$, e) => {
    visto.argv.push([...e.argv])
    return { value: { exitCode, stdout: salida, stderr: exitCode ? 'boom' : '' } }
  })
  on('ui.status', () => {
    visto.status += 1
    return { value: undefined }
  })
  on('ui.toast', () => ({ value: undefined }))
  on('ui.panes', () => ({ value: paneles }))
  on('ui.open', (_$, e) => {
    visto.abiertos += 1
    paneles = [{ id: e.id }]
    return { value: { isPlaced: true } }
  })
  on('ui.close', () => {
    paneles = []
    return { value: undefined }
  })
  on('command.register', (_$, e) => ({ value: { command: e.name } }))
  on('prompt.fill', (_$, e) => {
    visto.fills.push(e.text)
    return { isFilled: true }
  })
  on('model.complete', (_$, e) => {
    visto.prompts.push(e.prompt)
    const text = Array.isArray(respuesta) ? (respuesta[visto.prompts.length - 1] ?? '{}') : respuesta
    return { value: { isAnswered: true, text, usage: { input_tokens: 1, output_tokens: 1, cache_creation_input_tokens: 0, cache_read_input_tokens: 0 } } }
  })
  on('ui.render', { component: 'AbovePrompt' }, ($, e) => {
    const { Box } = $.ui.resolve(e)
    return <Box />
  })
  return visto
}

const pane = (filas: number) =>
  ({ plugin: 'pendientes', component: 'Pane', requestId: 'pendientes-ahora', props: { bodyColumns: 60, scroll: { offset: 0, bodyRows: filas } } }) as const
const BANDA = { plugin: 'pendientes', component: 'AbovePrompt', props: { bodyColumns: 100, hasSurvey: false, isWorking: false, maxRows: 10 } } as const

for (const surface of ['terminal', 'desktop'] as const) {
  test(`${surface}: tarjetas por seccion, fechas como texto, clic rellena el prompt sin enviar`, async ($, on) => {
    const reloj = mock.clock(on)
    mock.store(on)
    const visto = motor(on, JSON.stringify(AHORA))
    const abre = await $.command.run({ command: 'pendientes-ahora' })
    expect(abre.text).toContain('abierto')
    expect(visto.argv[0]).toEqual([
      'python3', '-I', expect.stringContaining('/bin/pendientes-ahora.py'), '--memory-dir', '/proyecto/memory', '--session-id', 'sesion-x',
    ])
    await reloj.advance(1)

    const ui = await $.ui.mount({ ...pane(40), surface })
    expect(await ui.find({ text: /SIGUIENTE/ })).toBeDefined()
    expect((await ui.find({ key: 'h-hilo' }))?.text).toMatch(/^RELACIONADO AL TRABAJO ACTUAL\s*2$/)
    expect((await ui.find({ key: 'h-vence' }))?.text).toMatch(/^VENCEN\s*3$/)
    expect(await ui.find({ text: '● 17 d' })).toBeDefined()
    expect(await ui.find({ text: '● hoy' })).toBeDefined()
    // Linea de datos igual para todos: prioridad, id corto, antiguedad. Sin el tema del texto.
    expect(await ui.find({ text: 'Alta · p-aaaaaa · de hoy' })).toBeDefined()
    expect(await ui.find({ text: 'Media · p-dddddd · hace 42 d' })).toBeDefined()
    expect(await ui.find({ text: /Snippet de cierre/ })).toBeUndefined()

    // En curso: fuera de su seccion, al final, con donde y cuantos commits.
    expect((await ui.find({ key: 'h-curso' }))?.text).toMatch(/^EN CURSO\s*1$/)
    expect(await ui.find({ text: '◐ otra sesión hace 41 min · 3 commits' })).toBeDefined()
    expect((await ui.find({ key: 'h-alta' }))?.text).toMatch(/^ALTA PRIORIDAD\s*3$/)

    await ui.press({ key: 'p-bbbbbbbbbb' })
    expect(visto.fills).toEqual(['p-bbbbbbbbbb: Algo que vencio'])
    // La linea de datos ya no es un boton: un solo clicable por tarjeta (10 candidatos, 10 botones).
    expect(await ui.find({ key: 'p-bbbbbbbbbb-meta' })).toBeUndefined()
    expect((await ui.findAll({ type: 'Button' })).filter(b => b.key?.startsWith('p-'))).toHaveLength(10)
    // Sin status line: la banda la sustituye.
    expect(visto.status).toBe(0)
  })
}

test('el panel llena el alto: con sitio entran los del resto; sin sitio, "+N más" y se despliega', async ($, on) => {
  const reloj = mock.clock(on)
  mock.store(on)
  motor(on, JSON.stringify(AHORA))
  await $.command.run({ command: 'pendientes-ahora' })
  await reloj.advance(1)

  const alto = await $.ui.mount({ ...pane(40), surface: 'terminal' })
  expect(await alto.find({ text: /Titulo p-3333333333/ })).toBeDefined()
  expect(await alto.find({ text: /más/ })).toBeUndefined()
  expect((await alto.find({ key: 'h-alta' }))?.text).toMatch(/^ALTA PRIORIDAD\s*3$/)
  await alto.unmount()

  // 14 filas, 1 de pie: paso + hilo (2 secciones x 2) + 3 tarjetas x 2 = 10; la cuarta abre
  // VENCEN (3 x 2 + 4 x 2 = 14 > 13). Caben 3 de 10: "+7 más".
  const bajo = await $.ui.mount({ ...pane(14), surface: 'terminal' })
  expect(await bajo.find({ text: /\+7 más/ })).toBeDefined()
  expect(await bajo.find({ text: /Titulo p-eeeeeeeeee/ })).toBeUndefined()
  expect(await bajo.find({ text: /Titulo p-3333333333/ })).toBeUndefined()
  await bajo.press({ key: 'mas' })
  expect(await bajo.find({ text: /Titulo p-3333333333/ })).toBeDefined()
  expect(await bajo.find({ text: /ver menos/ })).toBeDefined()
})

test('la banda: solo con el panel cerrado, muestra el nombre, los abiertos y los avisos, y un clic abre el panel', async ($, on) => {
  const reloj = mock.clock(on)
  mock.store(on)
  const visto = motor(on, JSON.stringify(AHORA))
  // Abre y cierra: deja el estado cargado y el panel cerrado, como tras un arranque.
  await $.command.run({ command: 'pendientes-ahora' })
  await $.command.run({ command: 'pendientes-ahora' })
  await reloj.advance(1)

  const banda = await $.ui.mount({ ...BANDA, surface: 'terminal' })
  expect(await banda.find({ text: 'Pendientes 3-tier' })).toBeDefined()
  expect(await banda.find({ text: '20 abiertos' })).toBeDefined()
  expect(await banda.find({ text: '● 1 hoy  ' })).toBeDefined()
  expect(await banda.find({ text: '● 2 vencidos  ' })).toBeDefined()
  await banda.press({ key: 'abrir' })
  expect(visto.abiertos).toBe(2)
  await banda.unmount()

  const conPanel = await $.ui.mount({ ...BANDA, surface: 'terminal' })
  expect(await conPanel.find({ key: 'abrir' })).toBeUndefined()
  await conPanel.unmount()

  // Cerrarlo con el comando devuelve la banda. (El cierre por la marca del panel o Esc pasa por
  // el hook de ui.close; el kit no deja levantar ese evento desde una prueba: se verifica en vivo.)
  await $.command.run({ command: 'pendientes-ahora' })
  const otraVez = await $.ui.mount({ ...BANDA, surface: 'terminal' })
  expect(await otraVez.find({ key: 'abrir' })).toBeDefined()
})

test('el titulo del modelo sustituye al corte automatico; cada pendiente se pide una sola vez', async ($, on) => {
  const reloj = mock.clock(on)
  mock.store(on)
  const largo = 'x'.repeat(90)
  const visto = motor(on, JSON.stringify(AHORA), 0, `Aqui va: {"p-aaaaaaaaaa": "Implementar el paso", "p-cccccccccc": "${largo}"}`)
  await $.command.run({ command: 'pendientes-ahora' })
  await reloj.advance(1)
  expect(visto.prompts).toHaveLength(1)
  expect(visto.prompts[0]).toContain('p-aaaaaaaaaa\tSnippet de cierre: paso del hilo largo')
  expect(visto.prompts[0]).toContain('p-3333333333')

  const ui = await $.ui.mount({ ...pane(40), surface: 'terminal' })
  expect(await ui.find({ text: /Implementar el paso/ })).toBeDefined()
  expect(await ui.find({ text: /Paso del hilo largo/ })).toBeUndefined()
  // Un titulo de mas de 80 caracteres se descarta: queda el corte automatico.
  expect(await ui.find({ text: /Una Alta libre/ })).toBeDefined()

  // Siguiente refresco: todos quedaron guardados (los que no sirvieron, como corte automatico):
  // no se vuelve a llamar al modelo.
  await $.command.run({ command: 'pendientes-ahora' })
  await $.command.run({ command: 'pendientes-ahora' })
  await reloj.advance(1)
  expect(visto.prompts).toHaveLength(1)
})

test('si el modelo falla, el panel sigue con el corte automatico y no reintenta hasta 30 min despues', async ($, on) => {
  const reloj = mock.clock(on)
  mock.store(on)
  const visto = motor(on, JSON.stringify(AHORA), 0, 'no es json')
  await $.command.run({ command: 'pendientes-ahora' })
  await reloj.advance(1)
  expect(visto.prompts).toHaveLength(1)
  const ui = await $.ui.mount({ ...pane(40), surface: 'terminal' })
  expect(await ui.find({ text: /Paso del hilo largo/ })).toBeDefined()

  await $.command.run({ command: 'pendientes-ahora' })
  await $.command.run({ command: 'pendientes-ahora' })
  await reloj.advance(10 * 60 * 1000)
  expect(visto.prompts).toHaveLength(1)

  await reloj.advance(21 * 60 * 1000)
  await $.command.run({ command: 'pendientes-ahora' })
  await $.command.run({ command: 'pendientes-ahora' })
  await reloj.advance(1)
  expect(visto.prompts).toHaveLength(2)
})

test('un estado de la version anterior (sin titulo_auto) no rompe el dibujo', async ($, on) => {
  const reloj = mock.clock(on)
  mock.store(on)
  const viejo = { ...AHORA, items: [{ id: 'p-9999999999', prio: 'Alta', texto: 'Texto viejo', corto: 'Texto viejo', grupo: 'alta', motivo: 'Alta libre' }], resto: undefined }
  motor(on, JSON.stringify(viejo))
  await $.command.run({ command: 'pendientes-ahora' })
  await reloj.advance(1)
  const ui = await $.ui.mount({ ...pane(40), surface: 'terminal' })
  expect(await ui.find({ text: /Texto viejo/ })).toBeDefined()
})

test('sin memoria 3-tier no hay banda ni status line, y no se lanza python', async ($, on) => {
  const reloj = mock.clock(on)
  mock.store(on)
  const visto = motor(on, JSON.stringify(AHORA), 0, '{}', false)
  await $.command.run({ command: 'pendientes-ahora' })
  await $.command.run({ command: 'pendientes-ahora' })
  await reloj.advance(1)
  const banda = await $.ui.mount({ ...BANDA, surface: 'terminal' })
  expect(await banda.find({ key: 'abrir' })).toBeUndefined()
  expect(visto.status).toBe(0)
  expect(visto.argv).toHaveLength(0)
})

test('los titulos se piden en tandas de 12; una tanda rota guarda las anteriores y para', async ($, on) => {
  const reloj = mock.clock(on)
  mock.store(on)
  const muchos = { ...AHORA, items: Array.from({ length: 30 }, (_, i) => it(`p-${String(i).padStart(10, 'a')}`, 'alta', 'Alta libre', { prio: 'Alta', titulo_auto: `Auto ${i}` })), resto: [] }
  const primera = JSON.stringify(Object.fromEntries(muchos.items.slice(0, 12).map(p => [p.id, `Hecho ${p.id}`])))
  const visto = motor(on, JSON.stringify(muchos), 0, [primera, 'cortado {"p-'])
  await $.command.run({ command: 'pendientes-ahora' })
  await reloj.advance(1)
  expect(visto.prompts).toHaveLength(2)
  expect(visto.prompts[0]?.split('\n')).toHaveLength(13)
  const ui = await $.ui.mount({ ...pane(80), surface: 'terminal' })
  expect(await ui.find({ text: /Hecho p-aaaaaaaaa0/ })).toBeDefined()
  expect(await ui.find({ text: /Auto 12/ })).toBeDefined()
})

test('el clic pega tambien que leer: la ficha de origen, o su texto, y lo relacionado', async ($, on) => {
  const reloj = mock.clock(on)
  mock.store(on)
  const conContexto = {
    ...AHORA,
    items: [
      it('p-aaaaaaaaaa', 'alta', 'Alta libre', { prio: 'Alta', texto: 'Con ficha', origen: ['memory/sessions/2026-10-13-b.md', 'memory/plans/plan-x.md'], origen_texto: null, relacionado: ['p-bbbbbbbbbb', 'plan-x'] }),
      it('p-cccccccccc', 'alta', 'Alta libre', { prio: 'Alta', texto: 'Sin archivo', origen: [], origen_texto: 'barrido A04', relacionado: [] }),
      it('p-dddddddddd', 'alta', 'Alta libre', { prio: 'Alta', texto: 'Sin nada', origen: [], origen_texto: null, relacionado: [] }),
    ],
    resto: [],
  }
  const visto = motor(on, JSON.stringify(conContexto))
  await $.command.run({ command: 'pendientes-ahora' })
  await reloj.advance(1)
  const ui = await $.ui.mount({ ...pane(40), surface: 'terminal' })
  await ui.press({ key: 'p-aaaaaaaaaa' })
  await ui.press({ key: 'p-cccccccccc' })
  await ui.press({ key: 'p-dddddddddd' })
  expect(visto.fills).toEqual([
    'p-aaaaaaaaaa: Con ficha\n\nLee memory/sessions/2026-10-13-b.md, memory/plans/plan-x.md para el contexto.\nRelacionado: p-bbbbbbbbbb, plan-x',
    'p-cccccccccc: Sin archivo\n\nOrigen: barrido A04',
    'p-dddddddddd: Sin nada',
  ])
})
