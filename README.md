<p align="center">
  <img src="src/renderer/src/assets/logo.png" alt="RulZ" width="420">
</p>

# RulZ WoW Forever Addons

Addons for World of Warcraft: Forever, with a black-and-red installer that finds your game and installs an addon in
one click.

| Addon | What it does |
| --- | --- |
| [RulZ Level Up Tracker](addons/RulZLevelUpTracker) | Estimates the time to your next level from the rate you earn XP, based on the past hour, this session, your current level or all time |

## Installing addons

1. Download `RulZ-WoW-Forever-Addons-Installer-<version>.exe` from the
   [latest release](https://github.com/speedyrulz/RulZ-WoW-Forever-Addons/releases/latest) and run it. There's nothing
   to set up; it runs as it is.
2. Check the **WoW Forever folder**. The installer scans for it. Use **Change folder** if it found the wrong one or
   none at all. You can pick either your `World of Warcraft` folder or the `_forever_` folder inside it.
3. Press **Install** on the addon you want.
4. If WoW is open, close it and start it again.

**Update** appears when the installer has a newer version than the one in your game. **Uninstall** moves the addon to
the Recycle Bin. Installing, updating and uninstalling all leave your saved addon data alone, because the game stores
it under `WTF`.

The scan looks in Battle.net's install records, then the Windows registry, then the usual game folders on every
drive. A folder only counts when it holds `Wow.exe` and its `.flavor.info` says it's the Forever client, so `_retail_`
is never picked by mistake. Your choice is remembered.

Windows may warn about the installer because it isn't code-signed.

## Running from source

Needs [Node.js](https://nodejs.org) 22 or newer.

```bat
install.bat
run.bat
```

| Command | What it does |
| --- | --- |
| `run.bat dev` | Start with hot reload |
| `npm test` | Run the tests |
| `npm run typecheck` | Check the types |
| `npm run build:win` | Build the installer `.exe` into `dist` |

## Adding an addon

1. Put the addon's folder in `addons/`, named the same as its `.toc` file. Its `## Version:` line sets the version
   shown in the installer.
2. Add an entry to [catalog/addons.json](catalog/addons.json). Its `id` is the folder name.
3. Add a square PNG icon at `catalog/icons/<id>.png`.

## Releases

Every push to `main` publishes a release with the installer attached. It uses the version in `package.json`, or the
next patch version if that one already has a release. Raise `package.json` only for a bigger jump.

## License

MIT, except the RulZ name and logo: see [LOGO-NOTICE.md](LOGO-NOTICE.md).
