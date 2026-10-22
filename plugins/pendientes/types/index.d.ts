export type Pendiente = {
  id: string
  prio: string
  texto: string
  corto: string
  etiqueta: string | null
  titulo_auto: string
  dias: number | null
  // Alguien ya lo esta haciendo: aqui, en otra sesion viva, o hay commits tras el ultimo checkpoint.
  en_curso?: { donde: 'aqui' | 'otra sesion' | 'commits'; n: number; hace_min?: number } | null
  // Dias desde _creado.
  edad?: number | null
  grupo: 'hilo' | 'vence' | 'alta'
  motivo: string
  revisar: string | null
  creado: string | null
  // Que leer para retomarlo: rutas memory/... de su _origen que existen; si ninguna, el _origen
  // tal cual; y los valores de su _relacionado. Opcionales: un estado anterior a 0.2.1 no los trae.
  origen?: string[]
  origen_texto?: string | null
  relacionado?: string[]
  // `_retomar` (3-tier-memory 2.62.8): el paso de un snippet `Retomamos:` de esa ficha. El clic pega
  // `retomar_snippet` (el bloque de la ficha, sin fence) en vez del pendiente. Opcionales: un estado
  // anterior a 0.2.3 no los trae.
  retomar?: string | null
  retomar_ficha?: string | null
  retomar_snippet?: string | null
}

// Un plan activo (0.3.0): una ficha con un snippet `Retomamos` sin cerrar, de las marcas `_retomar`.
export type Ventana = {
  // "abierta"/"cerrada": hay registro de procesos de Claude Code. "activa"/"sin actividad": solo la
  // transcripcion. null: la ficha no dice que sesion la escribio.
  estado: 'abierta' | 'cerrada' | 'activa' | 'sin actividad' | null
  dias: number | null
  fuente: 'proceso' | 'transcripcion' | null
  aqui: boolean
  // Abierta porque otra ventana viva pego su paso (un relevo, un snippet pegado a mano), no porque
  // siga la que escribio la ficha. Opcional: el primer estado de 0.3.0 no lo traia.
  retomada?: boolean
}

export type Plan = {
  ficha: string
  slug: string
  fecha: string | null
  desde: string
  proximo_paso: string | null
  snippet: string | null
  session_id: string | null
  ventana: Ventana
  pendientes: { id: string; prio: string; texto: string; titulo_auto: string; revisar: string | null }[]
}

export type Ahora = {
  ok: boolean
  error?: string
  hoy?: string
  ficha?: string | null
  proximo_paso?: string | null
  items?: Pendiente[]
  resto?: Pendiente[]
  // Opcional: un estado anterior a 0.3.0 no lo trae.
  planes?: Plan[]
  quedan?: number
  candidatos?: number
  totales?: { hilo: number; vence: number; alta: number }
  resumen?: { abiertos: number; vencidos: number; hoy: number; alta: number; bloqueados: number; sin_id?: number; planes?: number }
}

// Titulos cortos que resumio el modelo, por id; `h` es la huella del texto que resumio.
export type Titulos = Record<string, { h: string; t: string }>

declare module 'claude-code' {
  interface PluginState {
    pendientes: { ahora: Ahora | null; titulos: Titulos; abierto: boolean; expandido: boolean }
  }
}
