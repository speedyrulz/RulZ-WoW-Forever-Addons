import { CheckCircle2, FolderOpen, FolderSearch, Loader2, RefreshCw, TriangleAlert } from 'lucide-react'
import type { WowState } from '@shared/types'
import { Badge, Button } from './ui'

export function FolderPanel({
  wow,
  scanning,
  onChange,
  onScan,
  onSelect,
  onOpen
}: {
  wow: WowState | null
  scanning: boolean
  onChange: () => void
  onScan: () => void
  onSelect: (dir: string) => void
  onOpen: () => void
}) {
  const searching = wow === null || scanning
  const others = wow && wow.found.length > 1

  return (
    <section className="rounded-xl border border-border bg-panel p-4">
      <div className="flex items-center justify-between gap-3">
        <h2 className="font-[family-name:var(--font-display)] text-[15px] font-semibold">WoW Forever folder</h2>
        {searching ? (
          <Badge>
            <Loader2 className="size-3 animate-spin" /> Scanning
          </Badge>
        ) : wow.dir ? (
          <Badge tone="ok">
            <CheckCircle2 className="size-3" /> Found
          </Badge>
        ) : (
          <Badge tone="warn">
            <TriangleAlert className="size-3" /> Not found
          </Badge>
        )}
      </div>

      {others ? (
        <select
          aria-label="WoW Forever folder"
          value={wow.dir ?? ''}
          onChange={(event) => onSelect(event.target.value)}
          className="mt-3 h-9 w-full cursor-pointer rounded-lg border border-border bg-panel-2 px-3 font-[family-name:var(--font-mono)] text-[13px] outline-none"
        >
          {wow.found.map((dir) => (
            <option key={dir} value={dir}>
              {dir}
            </option>
          ))}
        </select>
      ) : (
        <p className="mt-3 rounded-lg border border-border bg-black/40 px-3 py-2 font-[family-name:var(--font-mono)] text-[13px] break-all text-body">
          {wow?.dir ?? (searching ? 'Looking for your game…' : "Couldn't find WoW Forever. Choose its folder to continue.")}
        </p>
      )}

      <div className="mt-3 flex flex-wrap gap-2">
        <Button onClick={onChange} disabled={searching}>
          <FolderSearch className="size-4" /> Change folder
        </Button>
        <Button onClick={onScan} disabled={searching}>
          <RefreshCw className="size-4" /> Scan again
        </Button>
        <Button onClick={onOpen} disabled={searching || !wow?.dir}>
          <FolderOpen className="size-4" /> Open AddOns folder
        </Button>
      </div>
    </section>
  )
}
