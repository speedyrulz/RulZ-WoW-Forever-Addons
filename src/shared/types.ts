export type AddonStatus = 'not-installed' | 'installed' | 'update-available'

export interface CatalogEntry {
  /** The addon's folder name, which is also its name inside Interface\AddOns. */
  id: string
  name: string
  tagline: string
  description: string
  features: string[]
}

export interface AddonView extends CatalogEntry {
  version: string
  /** The icon as a data URL. */
  icon: string
  status: AddonStatus
  installedVersion: string | null
}

export interface WowState {
  /** The selected _forever_ folder, or null when none is known. */
  dir: string | null
  /** Every Forever folder the scan found. */
  found: string[]
}

export interface ChooseResult {
  state: WowState
  /** Set when the folder the user picked isn't a Forever install. */
  error?: string
}

export interface InstallerApi {
  wowState(): Promise<WowState>
  scan(): Promise<WowState>
  chooseFolder(): Promise<ChooseResult>
  selectFolder(dir: string): Promise<ChooseResult>
  openAddonsFolder(): Promise<void>
  listAddons(): Promise<AddonView[]>
  install(id: string): Promise<AddonView[]>
  uninstall(id: string): Promise<AddonView[]>
}
