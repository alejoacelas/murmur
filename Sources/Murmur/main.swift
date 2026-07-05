// Murmur — the app process. Through M3 this runs headless (engine + control server); M4 adds
// the menu bar + HUD on top. Launched by exec for tests so env (MURMUR_HOME, MURMUR_TRIGGER)
// is inherited (SPEC §9).
//
// Top level stays synchronous (async top-level + dispatchMain() traps); async setup runs in a
// Task and the real main thread parks in the run loop AppKit will later own.
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

Task {
    do {
        try await server.start()
    } catch {
        Log.error("control.start_failed", msg: "\(error)")
        Log.flush()
        FileHandle.standardError.write(Data("murmur: control server failed: \(error)\n".utf8))
        exit(1)
    }
    // Warm the model, then run launch recovery (recovery may need to transcribe).
    do {
        try await backend.ensureModelReady()
    } catch {
        Log.error("model.warmup_failed", msg: "\(error)")
    }
    await engine.recoverAtLaunch()
    Log.info("app.ready", msg: "model=\(await backend.modelReady)")
}

RunLoop.main.run()
