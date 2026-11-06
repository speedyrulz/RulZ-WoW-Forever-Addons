import { cp, mkdir, readFile, rename, rm } from 'node:fs/promises'
import { join } from 'node:path'
import type { AddonStatus, AddonView, CatalogEntry } from '@shared/types'

export interface AddonPaths {
  /** Holds one folder per addon, exactly as it goes into the game. */
  addonsDir: string
  /** Holds addons.json and icons/. */
  catalogDir: string
}

export function addonsFolder(wowDir: string): string {
  return join(wowDir, 'Interface', 'AddOns')
}

function versionInToc(toc: string): string | null {
  return toc.match(/^##\s*Version:\s*(\S+)/m)?.[1] ?? null
}

async function readVersion(addonDir: string, id: string): Promise<string | null> {
  try {
    return versionInToc(await readFile(join(addonDir, `${id}.toc`), 'utf8'))
  } catch {
    return null
  }
}

/** Negative when a is older than b. */
export function compareVersions(a: string, b: string): number {
  const left = a.split('.').map(Number)
  const right = b.split('.').map(Number)
  for (let i = 0; i < Math.max(left.length, right.length); i++) {
    const difference = (left[i] ?? 0) - (right[i] ?? 0)
    if (difference !== 0) return difference
  }
  return 0
}

export function addonStatus(version: string, installed: string | null): AddonStatus {
  if (installed === null) return 'not-installed'
  return compareVersions(installed, version) < 0 ? 'update-available' : 'installed'
}

async function readCatalog(paths: AddonPaths): Promise<CatalogEntry[]> {
  return JSON.parse(await readFile(join(paths.catalogDir, 'addons.json'), 'utf8')) as CatalogEntry[]
}

export async function listAddons(paths: AddonPaths, wowDir: string | null): Promise<AddonView[]> {
  const catalog = await readCatalog(paths)
  return Promise.all(
    catalog.map(async (entry) => {
      const version = (await readVersion(join(paths.addonsDir, entry.id), entry.id)) ?? '0'
      const icon = await readFile(join(paths.catalogDir, 'icons', `${entry.id}.png`))
      const installedVersion = wowDir ? await readVersion(join(addonsFolder(wowDir), entry.id), entry.id) : null
      return {
        ...entry,
        version,
        icon: `data:image/png;base64,${icon.toString('base64')}`,
        status: addonStatus(version, installedVersion),
        installedVersion
      }
    })
  )
}

async function requireCatalogId(paths: AddonPaths, id: string): Promise<void> {
  const catalog = await readCatalog(paths)
  if (!catalog.some((entry) => entry.id === id)) throw new Error(`Unknown addon: ${id}`)
}

function friendlyError(error: unknown): Error {
  const code = (error as NodeJS.ErrnoException).code
  if (code === 'EPERM' || code === 'EACCES') {
    return new Error('Windows blocked access to the AddOns folder. Close WoW, then run this installer as administrator.')
  }
  if (code === 'EBUSY') return new Error('A file is in use. Close WoW and try again.')
  return error instanceof Error ? error : new Error(String(error))
}

/**
 * The new copy is fully written before the old one is touched, and the old one
 * comes back if the swap fails, so a failed install never loses the addon.
 * Saved settings live under WTF, so they aren't touched.
 */
export async function installAddon(paths: AddonPaths, wowDir: string, id: string): Promise<void> {
  await requireCatalogId(paths, id)
  const folder = addonsFolder(wowDir)
  const target = join(folder, id)
  const incoming = join(folder, `.${id}.installing`)
  const previous = join(folder, `.${id}.previous`)
  try {
    await mkdir(folder, { recursive: true })
    await rm(incoming, { recursive: true, force: true })
    await rm(previous, { recursive: true, force: true })
    await cp(join(paths.addonsDir, id), incoming, { recursive: true })
    await rename(target, previous).catch((error: NodeJS.ErrnoException) => {
      if (error.code !== 'ENOENT') throw error
    })
    try {
      await rename(incoming, target)
    } catch (error) {
      await rename(previous, target).catch(() => undefined)
      throw error
    }
    await rm(previous, { recursive: true, force: true })
  } catch (error) {
    await rm(incoming, { recursive: true, force: true }).catch(() => undefined)
    throw friendlyError(error)
  }
}

export async function uninstallAddon(
  paths: AddonPaths,
  wowDir: string,
  id: string,
  moveToTrash: (path: string) => Promise<void>
): Promise<void> {
  await requireCatalogId(paths, id)
  try {
    await moveToTrash(join(addonsFolder(wowDir), id))
  } catch (error) {
    throw friendlyError(error)
  }
}
