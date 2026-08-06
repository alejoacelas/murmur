// Murmur — the app process: engine + control server + hotkey tap + menu bar + HUD.
// Launched by exec for tests so env (MURMUR_HOME, MURMUR_TRIGGER) is inherited (SPEC §9).
// LSUIElement in Info.plist keeps it out of the Dock; the UI is a status item + floating pill.
import AppKit
import Foundation
import MurmurKit

do {
    try Paths.ensureTree()
} catch {
    FileHandle.standardError.write(Data("murmur: cannot create state dir: \(error)\n".utf8))
    exit(1)
}

let config = Config.load()
Log.info("app.start", msg: "home=\(Paths.home.path) trigger=\(config.trigger.rawValue) pid=\(getpid())")

let store = SessionStore()
let backend = FluidAudioBackend()
let inserter = PasteInserter(config: config)
let engine = Engine(store: store, backend: backend, inserter: inserter, config: config)
let server = ControlServer(engine: engine, backend: backend)

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var hud: TranscriptHUD!
    var statusMenu: StatusMenu!
    var hotkey: HotkeyEngine?
    let permissionsWindow = PermissionsWindowController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        hud = TranscriptHUD()
        statusMenu = StatusMenu(engine: engine, permissionsWindow: permissionsWindow)

        // Mirror engine HUD state into the pill + status glyph.
        Task {
            await engine.onHUDChange { phase, partial in
                Task { @MainActor in
                    appDelegate.hud.apply(phase: phase, partial: partial)
                    appDelegate.statusMenu.setPhase(phase)
                }
            }
        }

        // Hotkey tap — feature-gated on Input Monitoring (SPEC §8.6): the app is still fully
        // usable via the control socket / menu without it.
        if Permissions.current().inputMonitoring {
            let hk = HotkeyEngine(trigger: config.trigger) {
                Task { await engine.toggle() }
            }
            do {
                try hk.start()
                hotkey = hk
            } catch {
                Log.error("hotkey.start_failed", msg: "\(error)")
            }
        } else {
            Log.warn("hotkey.disabled", msg: "Input Monitoring not granted")
        }

        // Control server, then model warm-up, then launch recovery (needs the model).
        Task {
            do {
                try await server.start()
            } catch {
                Log.error("control.start_failed", msg: "\(error)")
                Log.flush()
                FileHandle.standardError.write(Data("murmur: control server failed: \(error)\n".utf8))
                exit(1)
            }
            do {
                try await backend.ensureModelReady()
            } catch {
                Log.error("model.warmup_failed", msg: "\(error)")
            }
            await engine.recoverAtLaunch()
            Log.info("app.ready", msg: "model=\(await backend.modelReady)")
        }
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)  // menu-bar app: no Dock icon, no app switcher entry
let appDelegate = AppDelegate()
app.delegate = appDelegate
app.run()
