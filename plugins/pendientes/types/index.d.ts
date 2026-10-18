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

export type Ahora = {
  ok: boolean
  error?: string
  hoy?: string
  ficha?: string | null
  proximo_paso?: string | null
  items?: Pendiente[]
  resto?: Pendiente[]
  quedan?: number
  candidatos?: number
  totales?: { hilo: number; vence: number; alta: number }
  resumen?: { abiertos: number; vencidos: number; hoy: number; alta: number; bloqueados: number }
}

// Titulos cortos que resumio el modelo, por id; `h` es la huella del texto que resumio.
export type Titulos = Record<string, { h: string; t: string }>

declare module 'claude-code' {
  interface PluginState {
    pendientes: { ahora: Ahora | null; titulos: Titulos; abierto: boolean; expandido: boolean }
  }
}
