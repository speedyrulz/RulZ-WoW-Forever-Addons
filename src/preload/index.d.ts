import type { InstallerApi } from '@shared/types'

declare global {
  interface Window {
    installer: InstallerApi
  }
}
