import { mkdir, readFile, writeFile } from 'node:fs/promises'
import { dirname, join } from 'node:path'
import { app, BrowserWindow, dialog, ipcMain, shell } from 'electron'
import type { ChooseResult, WowState } from '@shared/types'
import { addonsFolder, installAddon, listAddons, uninstallAddon, type AddonPaths } from './addons'
import { resolveForeverDir, scanForForever } from './wow'

const TITLE = 'RulZ WoW Forever Addons'
const WINDOW_BACKGROUND = '#050505'
const NOT_FOREVER_MESSAGE =
  "That folder doesn't contain World of Warcraft: Forever. Choose your World of Warcraft folder or the _forever_ folder inside it."

const isDev = !app.isPackaged && !!process.env.ELECTRON_RENDERER_URL

if (!app.requestSingleInstanceLock()) app.quit()

let mainWindow: BrowserWindow | null = null
let wowState: WowState = { dir: null, found: [] }

function settingsFile(): string {
  return join(app.getPath('userData'), 'settings.json')
}

async function loadSavedDir(): Promise<string | null> {
  try {
    const { wowDir } = JSON.parse(await readFile(settingsFile(), 'utf8')) as { wowDir?: string }
    return wowDir ? await resolveForeverDir(wowDir) : null
  } catch {
    return null
  }
}

async function saveDir(wowDir: string | null): Promise<void> {
  await mkdir(dirname(settingsFile()), { recursive: true })
  await writeFile(settingsFile(), JSON.stringify({ wowDir }, null, 2))
}

/** A saved folder that still exists wins over whatever the scan finds first. */
async function refreshWowState(): Promise<WowState> {
  const saved = await loadSavedDir()
  const found = await scanForForever(saved ? [saved] : [])
  wowState = { dir: saved ?? found[0] ?? null, found }
  return wowState
}

async function selectFolder(path: string): Promise<ChooseResult> {
  const dir = await resolveForeverDir(path)
  if (!dir) return { state: wowState, error: NOT_FOREVER_MESSAGE }
  await saveDir(dir)
  const known = wowState.found.some((found) => found.toLowerCase() === dir.toLowerCase())
  wowState = { dir, found: known ? wowState.found : [dir, ...wowState.found] }
  return { state: wowState }
}

function requireWowDir(): string {
  if (!wowState.dir) throw new Error('Choose your WoW Forever folder first.')
  return wowState.dir
}

function registerHandlers(paths: AddonPaths): void {
  const addons = () => listAddons(paths, wowState.dir)

  ipcMain.handle('wow:state', () => wowState)
  ipcMain.handle('wow:scan', refreshWowState)
  ipcMain.handle('wow:select', (_event, dir: string) => selectFolder(dir))
  ipcMain.handle('wow:choose', async (): Promise<ChooseResult> => {
    const result = await dialog.showOpenDialog(mainWindow!, {
      title: 'Choose your World of Warcraft or _forever_ folder',
      defaultPath: wowState.dir ?? undefined,
      properties: ['openDirectory']
    })
    const path = result.filePaths[0]
    return result.canceled || !path ? { state: wowState } : selectFolder(path)
  })
  ipcMain.handle('wow:openAddons', async () => {
    const error = await shell.openPath(addonsFolder(requireWowDir()))
    if (error) throw new Error(error)
  })
  ipcMain.handle('addons:list', addons)
  ipcMain.handle('addons:install', async (_event, id: string) => {
    await installAddon(paths, requireWowDir(), id)
    return addons()
  })
  ipcMain.handle('addons:uninstall', async (_event, id: string) => {
    await uninstallAddon(paths, requireWowDir(), id, (path) => shell.trashItem(path))
    return addons()
  })
}

function createWindow(): BrowserWindow {
  const win = new BrowserWindow({
    width: 1040,
    height: 760,
    minWidth: 760,
    minHeight: 560,
    show: false,
    title: TITLE,
    backgroundColor: WINDOW_BACKGROUND,
    titleBarStyle: 'hidden',
    titleBarOverlay: { color: WINDOW_BACKGROUND, symbolColor: '#e5e5e5', height: 48 },
    // Packaged builds take the icon from the .exe; dev runs need it explicitly.
    ...(app.isPackaged ? {} : { icon: join(__dirname, '../../build/icon.png') }),
    webPreferences: {
      preload: join(__dirname, '../preload/index.js'),
      contextIsolation: true,
      nodeIntegration: false,
      sandbox: true
    }
  })
  win.once('ready-to-show', () => win.show())
  win.webContents.setWindowOpenHandler(() => ({ action: 'deny' }))
  win.webContents.on('will-navigate', (event, url) => {
    if (!isDev || !url.startsWith(process.env.ELECTRON_RENDERER_URL!)) event.preventDefault()
  })

  if (isDev) void win.loadURL(process.env.ELECTRON_RENDERER_URL!)
  else void win.loadFile(join(__dirname, '../renderer/index.html'))
  return win
}

async function main(): Promise<void> {
  await app.whenReady()
  app.setAppUserModelId('com.rulz.wowforeveraddons')

  const resources = app.isPackaged ? process.resourcesPath : app.getAppPath()
  registerHandlers({ addonsDir: join(resources, 'addons'), catalogDir: join(resources, 'catalog') })
  await refreshWowState()
  mainWindow = createWindow()

  app.on('second-instance', () => {
    if (mainWindow?.isMinimized()) mainWindow.restore()
    mainWindow?.focus()
  })
  app.on('window-all-closed', () => app.quit())
}

if (app.hasSingleInstanceLock()) void main()
