import Foundation
import QuayCore

// quayd — the headless supervisor loop. Runs under a per-user LaunchAgent.
// Logs to stderr (launchd captures it). Re-reads stack files every tick.
//
// Usage:
//   quayd [--stacks <dir>] [--interval <sec>] [--once] [--verbose]
//
// Defaults: --stacks ~/.config/quay/stacks   --interval 15

struct Options {
    var stacksDir: URL = QuayPaths.defaultStacksDir
    var interval: TimeInterval = 15
    var once = false
    var verbose = false
}

func parseArgs(_ argv: [String]) -> Options {
    var opts = Options()
    var i = 1
    func next(_ flag: String) -> String? {
        guard i + 1 < argv.count else {
            FileHandle.standardError.write(Data("quayd: \(flag) requires a value\n".utf8))
            return nil
        }
        i += 1
        return argv[i]
    }
    while i < argv.count {
        let arg = argv[i]
        switch arg {
        case "--stacks", "-s":
            if let v = next(arg) { opts.stacksDir = URL(fileURLWithPath: (v as NSString).expandingTildeInPath, isDirectory: true) }
        case "--interval", "-i":
            if let v = next(arg), let n = Double(v), n > 0 { opts.interval = n }
        case "--once":
            opts.once = true
        case "--verbose", "-v":
            opts.verbose = true
        case "--help", "-h":
            printUsage(); exit(0)
        default:
            FileHandle.standardError.write(Data("quayd: unknown argument '\(arg)'\n".utf8))
            printUsage(); exit(2)
        }
        i += 1
    }
    return opts
}

func printUsage() {
    let usage = """
    quayd — Quay supervisor daemon

    USAGE:
      quayd [--stacks <dir>] [--interval <sec>] [--once] [--verbose]

    OPTIONS:
      -s, --stacks <dir>     Directory of *.quay.yaml stack files
                             (default: ~/.config/quay/stacks)
      -i, --interval <sec>   Reconcile interval in seconds (default: 15)
          --once             Run a single reconcile pass and exit
      -v, --verbose          Debug logging
      -h, --help             Show this help

    """
    FileHandle.standardError.write(Data(usage.utf8))
}

let opts = parseArgs(CommandLine.arguments)
let logger = Logger(subsystem: "quayd", minLevel: opts.verbose ? .debug : .info)

logger.info("quayd starting — stacks=\(opts.stacksDir.path) interval=\(Int(opts.interval))s")
logger.info("NOTE: Quay requires Apple's `container` CLI and only works at runtime on macOS 26+.")

try? QuayPaths.ensureConfigDir()

let loader = StackLoader(logger: logger)
let client = CLIContainerClient(logger: logger)
let health = HTTPHealthChecker()
let reconciler = Reconciler(client: client, health: health,
                            status: StatusStore(), logger: logger)

// One-time probe so the operator sees immediately whether the runtime is present.
let probe = await client.probe()
if probe.available {
    logger.info("container runtime: \(probe.version ?? "available")")
} else {
    logger.warn("container runtime NOT available: \(probe.detail ?? "unknown"). quayd will keep retrying; install apple/container (macOS 26+).")
}

// TODO: add an FSEvents watch on the stacks dir to reconcile immediately on edit
// instead of waiting for the next interval. For now we re-read every tick.

func runOnce() async {
    let stacks = loader.load(from: opts.stacksDir)
    if stacks.isEmpty {
        logger.warn("no stacks loaded from \(opts.stacksDir.path)")
    } else {
        logger.debug("loaded \(stacks.count) stack(s): \(stacks.map(\.stack).joined(separator: ", "))")
    }
    let snap = await reconciler.tick(stacks: stacks)
    logger.debug("tick complete — aggregate=\(snap.aggregate.rawValue) orphans=\(snap.orphans.count)")
}

if opts.once {
    await runOnce()
    exit(0)
}

// Graceful shutdown on SIGTERM/SIGINT (launchd sends SIGTERM on unload).
let shouldStop = StopFlag()
for sig in [SIGTERM, SIGINT] {
    signal(sig, SIG_IGN)
    let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
    src.setEventHandler { shouldStop.set() }
    src.resume()
    signalSources.append(src)
}

while !shouldStop.isSet {
    await runOnce()
    // Sleep in small slices so a stop signal is honored promptly.
    let deadline = Date().addingTimeInterval(opts.interval)
    while Date() < deadline && !shouldStop.isSet {
        try? await Task.sleep(nanoseconds: 200_000_000)
    }
}

logger.info("quayd stopping")
exit(0)
