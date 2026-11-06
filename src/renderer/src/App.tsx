import { useEffect, useState } from 'react'
import { CheckCircle2, TriangleAlert } from 'lucide-react'
import type { AddonView, ChooseResult, WowState } from '@shared/types'
import logo from './assets/logo.png'
import mark from './assets/mark.png'
import { AddonCard } from './components/AddonCard'
import { FolderPanel } from './components/FolderPanel'

interface Notice {
  tone: 'ok' | 'error'
  text: string
}

function errorText(error: unknown): string {
  const message = error instanceof Error ? error.message : String(error)
  return message.replace(/^Error invoking remote method '[^']+': (Error: )?/, '')
}

export function App() {
  const api = window.installer
  const [wow, setWow] = useState<WowState | null>(null)
  const [addons, setAddons] = useState<AddonView[]>([])
  const [scanning, setScanning] = useState(false)
  const [busyId, setBusyId] = useState<string | null>(null)
  const [notice, setNotice] = useState<Notice | null>(null)

  const load = async (nextWow: WowState): Promise<void> => {
    setWow(nextWow)
    setAddons(await api.listAddons())
  }

  useEffect(() => {
    void api.wowState().then(load)
  }, [])

  const scan = async (): Promise<void> => {
    setScanning(true)
    setNotice(null)
    await load(await api.scan())
    setScanning(false)
  }

  const applyChoice = async (choice: ChooseResult): Promise<void> => {
    setNotice(choice.error ? { tone: 'error', text: choice.error } : null)
    await load(choice.state)
  }

  const runAddonAction = async (id: string, action: () => Promise<AddonView[]>, done: string): Promise<void> => {
    setBusyId(id)
    setNotice(null)
    try {
      setAddons(await action())
      setNotice({ tone: 'ok', text: done })
    } catch (error) {
      setNotice({ tone: 'error', text: errorText(error) })
    }
    setBusyId(null)
  }

  return (
    <div className="flex h-full flex-col">
      <header className="drag flex h-12 shrink-0 items-center gap-2.5 border-b border-border bg-bg pr-[150px] pl-4">
        <img src={mark} alt="RulZ" className="h-6" draggable={false} />
        <span className="font-[family-name:var(--font-display)] text-[13px] font-semibold tracking-[0.2em] text-muted uppercase">
          WoW Forever Addons
        </span>
      </header>

      <main className="min-h-0 flex-1 overflow-y-auto">
        <div className="hero relative overflow-hidden border-b border-border px-8 py-7">
          <div className="hero-slashes pointer-events-none absolute inset-0" />
          <div className="relative mx-auto max-w-[880px]">
            <img src={logo} alt="RulZ" className="h-12" draggable={false} />
            <h1 className="mt-3 font-[family-name:var(--font-display)] text-[28px] leading-tight font-bold">
              WoW Forever Addons
            </h1>
            <p className="mt-1 text-[14px] text-muted">Choose an addon and install it in one click.</p>
          </div>
        </div>

        <div className="mx-auto flex max-w-[944px] flex-col gap-4 px-8 py-6">
          <FolderPanel
            wow={wow}
            scanning={scanning}
            onChange={() => void api.chooseFolder().then(applyChoice)}
            onScan={() => void scan()}
            onSelect={(dir) => void api.selectFolder(dir).then(applyChoice)}
            onOpen={() =>
              void api.openAddonsFolder().catch((error: unknown) => setNotice({ tone: 'error', text: errorText(error) }))
            }
          />

          {notice && (
            <p
              role="status"
              className={`flex items-start gap-2 rounded-lg border px-3 py-2 text-[13px] ${
                notice.tone === 'ok'
                  ? 'border-ok/25 bg-ok/10 text-ok'
                  : 'border-danger-border bg-danger-bg text-danger-text'
              }`}
            >
              {notice.tone === 'ok' ? (
                <CheckCircle2 className="mt-0.5 size-4 shrink-0" />
              ) : (
                <TriangleAlert className="mt-0.5 size-4 shrink-0" />
              )}
              {notice.text}
            </p>
          )}

          {addons.map((addon) => (
            <AddonCard
              key={addon.id}
              addon={addon}
              busy={busyId === addon.id}
              canInstall={!!wow?.dir && !scanning}
              onInstall={() =>
                void runAddonAction(
                  addon.id,
                  () => api.install(addon.id),
                  `${addon.name} is installed. If WoW is open, close it and start it again to load the addon.`
                )
              }
              onUninstall={() =>
                void runAddonAction(
                  addon.id,
                  () => api.uninstall(addon.id),
                  `${addon.name} was moved to the Recycle Bin. Your saved addon data was kept.`
                )
              }
            />
          ))}
        </div>
      </main>
    </div>
  )
}
