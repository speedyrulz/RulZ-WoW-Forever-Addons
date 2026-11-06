import { execFile } from 'node:child_process'
import { access, readFile } from 'node:fs/promises'
import { basename, dirname, join } from 'node:path'

const FOREVER_FOLDER = '_forever_'
const FOREVER_FLAVOR = 'wowf'
const WOW_FOLDER = 'World of Warcraft'
const BATTLE_NET_DB = 'C:\\ProgramData\\Battle.net\\Agent\\product.db'
const REGISTRY_LOCATIONS = [
  ['HKLM\\SOFTWARE\\WOW6432Node\\Blizzard Entertainment\\World of Warcraft', 'InstallPath'],
  ['HKLM\\SOFTWARE\\WOW6432Node\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\World of Warcraft', 'InstallLocation']
]
const COMMON_FOLDERS = [
  ['Program Files (x86)'],
  ['Program Files'],
  [],
  ['Games'],
  ['Battle.net'],
  ['Games', 'Battle.net'],
  ['Program Files (x86)', 'Battle.net', 'Games']
]

async function exists(path: string): Promise<boolean> {
  try {
    await access(path)
    return true
  } catch {
    return false
  }
}

/** True for a folder holding the Forever client. Its .flavor.info names the game flavor. */
export async function isForeverDir(dir: string): Promise<boolean> {
  if (!(await exists(join(dir, 'Wow.exe')))) return false
  try {
    const flavor = await readFile(join(dir, '.flavor.info'), 'latin1')
    return flavor.includes(FOREVER_FLAVOR)
  } catch {
    return basename(dir).toLowerCase() === FOREVER_FOLDER
  }
}

/** Accepts the _forever_ folder, the World of Warcraft folder above it, or another game folder beside it. */
export async function resolveForeverDir(path: string): Promise<string | null> {
  for (const candidate of [path, join(path, FOREVER_FOLDER), join(dirname(path), FOREVER_FOLDER)]) {
    if (await isForeverDir(candidate)) return candidate
  }
  return null
}

/** Battle.net's install database is binary, but it stores install paths as plain text. */
export function pathsInBattleNetDb(data: string): string[] {
  const paths = data.match(/[A-Za-z]:[\\/][ -~]{3,200}/g) ?? []
  return paths
    .map((path) => {
      const at = path.toLowerCase().indexOf(WOW_FOLDER.toLowerCase())
      return at < 0 ? null : path.slice(0, at + WOW_FOLDER.length).replaceAll('/', '\\')
    })
    .filter((path): path is string => path !== null)
}

async function battleNetPaths(): Promise<string[]> {
  try {
    return pathsInBattleNetDb(await readFile(BATTLE_NET_DB, 'latin1'))
  } catch {
    return []
  }
}

function readRegistryValue(key: string, value: string): Promise<string | null> {
  return new Promise((done) => {
    execFile('reg', ['query', key, '/v', value], { windowsHide: true }, (error, stdout) => {
      done(error ? null : (stdout.match(/REG_(?:EXPAND_)?SZ\s+(.+?)\s*$/m)?.[1] ?? null))
    })
  })
}

async function registryPaths(): Promise<string[]> {
  const values = await Promise.all(REGISTRY_LOCATIONS.map(([key, value]) => readRegistryValue(key, value)))
  return values.filter((path): path is string => path !== null)
}

async function commonPaths(): Promise<string[]> {
  const letters = [...'CDEFGHIJKLMNOPQRSTUVWXYZ']
  const drives = await Promise.all(letters.map(async (l) => ((await exists(`${l}:\\`)) ? `${l}:\\` : null)))
  return drives
    .filter((drive): drive is string => drive !== null)
    .flatMap((drive) => COMMON_FOLDERS.map((parts) => join(drive, ...parts, WOW_FOLDER)))
}

/** Every Forever folder on this PC, in order of how reliable the source is. */
export async function scanForForever(extraPaths: string[] = []): Promise<string[]> {
  const sources = await Promise.all([battleNetPaths(), registryPaths(), commonPaths()])
  const resolved = await Promise.all([...extraPaths, ...sources.flat()].map(resolveForeverDir))
  const unique = new Map<string, string>()
  for (const dir of resolved) {
    if (dir && !unique.has(dir.toLowerCase())) unique.set(dir.toLowerCase(), dir)
  }
  return [...unique.values()]
}
