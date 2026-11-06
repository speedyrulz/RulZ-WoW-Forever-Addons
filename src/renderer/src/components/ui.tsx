import type { ButtonHTMLAttributes, ReactNode } from 'react'

type Variant = 'primary' | 'secondary' | 'danger'

const VARIANTS: Record<Variant, string> = {
  primary: 'bg-accent text-white hover:bg-accent-hover shadow-[0_6px_20px_-8px_rgb(237_0_13/0.8)] disabled:shadow-none',
  secondary: 'bg-panel-2 text-text border border-border hover:bg-hover hover:border-border-strong',
  danger: 'text-muted border border-border hover:bg-danger-bg hover:border-danger-border hover:text-danger-text'
}

export function Button({
  variant = 'secondary',
  className = '',
  ...props
}: ButtonHTMLAttributes<HTMLButtonElement> & { variant?: Variant }) {
  return (
    <button
      className={`inline-flex h-9 shrink-0 cursor-pointer items-center justify-center gap-2 rounded-lg px-4 text-sm font-medium whitespace-nowrap transition-colors select-none disabled:cursor-not-allowed disabled:opacity-45 ${VARIANTS[variant]} ${className}`}
      {...props}
    />
  )
}

type Tone = 'neutral' | 'accent' | 'ok' | 'warn'

const TONES: Record<Tone, string> = {
  neutral: 'bg-white/6 text-muted border-white/8',
  accent: 'bg-accent-soft text-accent-text border-accent/40',
  ok: 'bg-ok/10 text-ok border-ok/25',
  warn: 'bg-warn/10 text-warn border-warn/25'
}

export function Badge({ children, tone = 'neutral' }: { children: ReactNode; tone?: Tone }) {
  return (
    <span
      className={`inline-flex h-6 items-center gap-1 rounded-full border px-2.5 text-[11.5px] font-medium whitespace-nowrap ${TONES[tone]}`}
    >
      {children}
    </span>
  )
}
