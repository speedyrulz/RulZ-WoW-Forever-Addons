import { contextBridge, ipcRenderer } from 'electron'
import type { InstallerApi } from '@shared/types'

const api: InstallerApi = {
  wowState: () => ipcRenderer.invoke('wow:state'),
  scan: () => ipcRenderer.invoke('wow:scan'),
  chooseFolder: () => ipcRenderer.invoke('wow:choose'),
  selectFolder: (dir) => ipcRenderer.invoke('wow:select', dir),
  openAddonsFolder: () => ipcRenderer.invoke('wow:openAddons'),
  listAddons: () => ipcRenderer.invoke('addons:list'),
  install: (id) => ipcRenderer.invoke('addons:install', id),
  uninstall: (id) => ipcRenderer.invoke('addons:uninstall', id)
}

contextBridge.exposeInMainWorld('installer', api)
