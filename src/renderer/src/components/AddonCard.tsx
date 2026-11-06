import { ArrowUpCircle, Check, CheckCircle2, Download, Loader2, Trash2 } from 'lucide-react'
import type { AddonView } from '@shared/types'
import { Badge, Button } from './ui'

const INSTALL_LABELS = { 'not-installed': 'Install', installed: 'Reinstall', 'update-available': 'Update' }

function StatusBadge({ addon }: { addon: AddonView }) {
  if (addon.status === 'update-available') {
    return (
      <Badge tone="accent">
        <ArrowUpCircle className="size-3" /> Update available
      </Badge>
    )
  }
  if (addon.status === 'installed') {
    return (
      <Badge tone="ok">
        <CheckCircle2 className="size-3" /> Installed
      </Badge>
    )
  }
  return <Badge>Not installed</Badge>
}

export function AddonCard({
  addon,
  busy,
  canInstall,
  onInstall,
  onUninstall
}: {
  addon: AddonView
  busy: boolean
  canInstall: boolean
  onInstall: () => void
  onUninstall: () => void
}) {
  const installed = addon.status !== 'not-installed'
  const version =
    addon.status === 'update-available' ? `Version ${addon.installedVersion} → ${addon.version}` : `Version ${addon.version}`

  return (
    <article className="rounded-xl border border-border bg-panel p-5">
      <div className="flex items-start gap-4">
        <img src={addon.icon} alt="" draggable={false} className="size-14 shrink-0" />
        <div className="min-w-0 flex-1">
          <div className="flex flex-wrap items-center justify-between gap-2">
            <h3 className="font-[family-name:var(--font-display)] text-[18px] leading-snug font-semibold">{addon.name}</h3>
            <StatusBadge addon={addon} />
          </div>
          <p className="mt-0.5 text-[13.5px] text-accent-text">{addon.tagline}</p>
        </div>
      </div>

      <p className="mt-4 text-[13.5px] leading-relaxed text-body">{addon.description}</p>

      <ul className="mt-3 grid gap-x-6 gap-y-1.5 text-[13px] text-muted min-[820px]:grid-cols-2">
        {addon.features.map((feature) => (
          <li key={feature} className="flex items-start gap-2">
            <Check className="mt-0.5 size-3.5 shrink-0 text-accent" />
            {feature}
          </li>
        ))}
      </ul>

      <div className="mt-5 flex flex-wrap items-center justify-between gap-3 border-t border-border pt-4">
        <span className="text-xs text-faint">{version}</span>
        <div className="flex gap-2">
          {installed && (
            <Button variant="danger" onClick={onUninstall} disabled={busy || !canInstall}>
              <Trash2 className="size-4" /> Uninstall
            </Button>
          )}
          <Button variant="primary" onClick={onInstall} disabled={busy || !canInstall}>
            {busy ? <Loader2 className="size-4 animate-spin" /> : <Download className="size-4" />}
            {INSTALL_LABELS[addon.status]}
          </Button>
        </div>
      </div>
    </article>
  )
}
