/**
 * after-pack.cjs — electron-builder afterPack hook.
 *
 * Stamps the Hermes icon + identity onto the packed Windows Hermes.exe via
 * rcedit (delegated to set-exe-identity.cjs). This runs for EVERY packed build
 * — first install, `hermes desktop`, the installer's --update rebuild, and a
 * dev's manual `npm run pack` — so the branded exe can never silently revert
 * to the stock "Electron" icon/name (the bug when the stamp lived only in
 * install.ps1, which the update path doesn't use).
 *
 * Windows-only: rcedit edits PE resources, irrelevant on macOS/Linux where the
 * app identity comes from the bundle Info.plist / desktop entry. Best-effort:
 * a stamp failure must never fail an otherwise-good build (worst case is the
 * stock icon, not a broken app), so we log and resolve rather than throw.
 *
 * electron-builder passes a context with:
 *   - electronPlatformName: 'win32' | 'darwin' | 'linux'
 *   - appOutDir:            the unpacked app directory for this target
 *   - packager.appInfo.productFilename: the exe basename (e.g. 'Hermes')
 */

const path = require('node:path')

const { stampExeIdentity } = require('./set-exe-identity.cjs')
const { execFileSync } = require('node:child_process')

exports.default = async function afterPack(context) {
  // macOS: electron-builder skips signing when identity is null (no Apple
  // cert). But an arm64 app — and especially the nested standalone Python under
  // Resources/hermes-runtime — MUST be at least ad-hoc signed or macOS kills
  // it on launch. Deep ad-hoc sign here so the produced .app (and the dmg built
  // from it) runs. Users still clear quarantine once (`xattr -cr <App>`), but
  // the binaries themselves are valid.
  if (context.electronPlatformName === 'darwin') {
    const productName = context.packager?.appInfo?.productFilename || 'Hermes'
    const appPath = path.join(context.appOutDir, `${productName}.app`)
    try {
      execFileSync('codesign', ['--force', '--deep', '--sign', '-', appPath], { stdio: 'ignore' })
      console.log(`[after-pack] deep ad-hoc signed ${appPath}`)
    } catch (err) {
      console.warn(`[after-pack] ad-hoc codesign failed: ${err.message}`)
    }
    return
  }

  if (context.electronPlatformName !== 'win32') {
    return
  }

  const productName = context.packager?.appInfo?.productFilename || 'Hermes'
  const exe = path.join(context.appOutDir, `${productName}.exe`)
  const desktopRoot = path.resolve(__dirname, '..')

  try {
    await stampExeIdentity(exe, desktopRoot)
  } catch (err) {
    // Never fail the build over a cosmetic stamp.
    console.warn(`[after-pack] exe identity stamp failed (${err.message}); Hermes.exe keeps the stock Electron icon`)
  }
}
