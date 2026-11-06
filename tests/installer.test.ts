import { mkdtemp, mkdir, readFile, readdir, rm, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import {
  addonStatus,
  addonsFolder,
  compareVersions,
  installAddon,
  listAddons,
  uninstallAddon,
  type AddonPaths
} from '../src/main/addons'
import { isForeverDir, pathsInBattleNetDb, resolveForeverDir, scanForForever } from '../src/main/wow'

const ID = 'TestAddon'
let root: string
let paths: AddonPaths
let forever: string

async function write(path: string, content: string): Promise<void> {
  await mkdir(join(path, '..'), { recursive: true })
  await writeFile(path, content)
}

function toc(version: string): string {
  return `## Interface: 16001\r\n## Title: Test\r\n## Version: ${version}\r\n\r\nCore.lua\r\n`
}

async function makeGame(dir: string, flavor = 'Product Flavor!STRING:0\nwowf\n'): Promise<void> {
  await write(join(dir, 'Wow.exe'), '')
  await write(join(dir, '.flavor.info'), flavor)
}

beforeEach(async () => {
  root = await mkdtemp(join(tmpdir(), 'rulz-installer-'))
  paths = { addonsDir: join(root, 'bundle', 'addons'), catalogDir: join(root, 'bundle', 'catalog') }
  forever = join(root, 'World of Warcraft', '_forever_')
  await makeGame(forever)
  await write(join(paths.addonsDir, ID, `${ID}.toc`), toc('1.2.0'))
  await write(join(paths.addonsDir, ID, 'Media', 'Icon.tga'), 'image')
  await write(
    join(paths.catalogDir, 'addons.json'),
    JSON.stringify([{ id: ID, name: 'Test', tagline: 't', description: 'd', features: [] }])
  )
  await write(join(paths.catalogDir, 'icons', `${ID}.png`), 'png')
})

afterEach(() => rm(root, { recursive: true, force: true }))

describe('finding the game', () => {
  it('needs the game program and the Forever flavor', async () => {
    expect(await isForeverDir(forever)).toBe(true)
    const retail = join(root, 'World of Warcraft', '_retail_')
    await makeGame(retail, 'Product Flavor!STRING:0\nwow\n')
    expect(await isForeverDir(retail)).toBe(false)
    expect(await isForeverDir(root)).toBe(false)
  })

  it('accepts the WoW folder, the _forever_ folder, or a folder beside it', async () => {
    const wow = join(root, 'World of Warcraft')
    expect(await resolveForeverDir(forever)).toBe(forever)
    expect(await resolveForeverDir(wow)).toBe(forever)
    expect(await resolveForeverDir(join(wow, '_retail_'))).toBe(forever)
    expect(await resolveForeverDir(root)).toBeNull()
  })

  it('reads install paths out of the Battle.net database', () => {
    const data = '\x12\x05wowf\x1a!C:/Program Files (x86)/World of Warcraft\x10\x01\x1aC:/Program Files (x86)/Battle.net\x00'
    expect(pathsInBattleNetDb(data)).toEqual(['C:\\Program Files (x86)\\World of Warcraft'])
  })

  it('finds an extra location once, whatever its case', async () => {
    const found = await scanForForever([forever, forever.toUpperCase()])
    expect(found.filter((dir) => dir.toLowerCase() === forever.toLowerCase())).toHaveLength(1)
  })
})

describe('versions', () => {
  it('compares each number', () => {
    expect(compareVersions('1.9.0', '1.10.0')).toBeLessThan(0)
    expect(compareVersions('1.2', '1.2.0')).toBe(0)
    expect(compareVersions('2.0.0', '1.9.9')).toBeGreaterThan(0)
  })

  it('names the status', () => {
    expect(addonStatus('1.0.0', null)).toBe('not-installed')
    expect(addonStatus('1.0.0', '0.9.0')).toBe('update-available')
    expect(addonStatus('1.0.0', '1.0.0')).toBe('installed')
    expect(addonStatus('1.0.0', '1.1.0')).toBe('installed')
  })
})

describe('installing', () => {
  const installed = () => join(addonsFolder(forever), ID)

  it('shows an addon that is not installed', async () => {
    const [addon] = await listAddons(paths, forever)
    expect(addon).toMatchObject({ status: 'not-installed', version: '1.2.0', installedVersion: null })
    expect(addon?.icon).toMatch(/^data:image\/png;base64,/)
  })

  it('shows the bundled addon when no game folder is known', async () => {
    expect((await listAddons(paths, null))[0]?.status).toBe('not-installed')
  })

  it('copies every file, creating the AddOns folder if needed', async () => {
    await installAddon(paths, forever, ID)
    expect(await readFile(join(installed(), 'Media', 'Icon.tga'), 'utf8')).toBe('image')
    expect((await listAddons(paths, forever))[0]?.status).toBe('installed')
    expect(await readdir(addonsFolder(forever))).toEqual([ID])
  })

  it('updates an older copy and removes files it no longer ships', async () => {
    await write(join(installed(), `${ID}.toc`), toc('1.0.0'))
    await write(join(installed(), 'Old.lua'), 'old')
    expect((await listAddons(paths, forever))[0]).toMatchObject({ status: 'update-available', installedVersion: '1.0.0' })
    await installAddon(paths, forever, ID)
    expect(await readdir(installed())).toEqual(['Media', `${ID}.toc`].sort())
    expect((await listAddons(paths, forever))[0]?.status).toBe('installed')
  })

  it('keeps the current copy when the new files are missing', async () => {
    await write(join(installed(), `${ID}.toc`), toc('1.0.0'))
    await rm(join(paths.addonsDir, ID), { recursive: true })
    await expect(installAddon(paths, forever, ID)).rejects.toThrow()
    expect(await readFile(join(installed(), `${ID}.toc`), 'utf8')).toContain('1.0.0')
    expect(await readdir(addonsFolder(forever))).toEqual([ID])
  })

  it('refuses anything outside the catalog', async () => {
    await expect(installAddon(paths, forever, '..\\..\\Evil')).rejects.toThrow('Unknown addon')
    await expect(uninstallAddon(paths, forever, '..', async () => undefined)).rejects.toThrow('Unknown addon')
  })

  it('moves the addon to the trash on uninstall', async () => {
    let trashed = ''
    await uninstallAddon(paths, forever, ID, async (path) => {
      trashed = path
    })
    expect(trashed).toBe(installed())
  })
})
