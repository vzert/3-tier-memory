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
