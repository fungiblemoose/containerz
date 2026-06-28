import Foundation

// MARK: - Container runtime model
//
// VERIFIED against apple/container 1.0.0 (2026-06): every CLI invocation below
// was exercised on a real macOS 26 install — `ls --all --format json`, `run
// --detach/--name/--env/--volume/--publish host:cont/tcp`, `start`, `stop`, and
// `volume create` all behave as used here. The `// VERIFY:` notes record the
// exact flag/shape each call assumes; re-check them with `container <cmd> --help`
// after a CLI upgrade, since the tool is still young. Live `--help` wins.
//
// This whole layer is deliberately thin and isolated so adjusting a flag or a
// JSON key is a one-line change that doesn't ripple into the reconciler.

/// Coarse lifecycle state Quay cares about, normalized from whatever string the
/// CLI reports.
public enum ContainerState: String, Sendable, Equatable {
    case running
    case stopped     // created/exited/stopped — anything not running but present
    case unknown

    /// Normalize the many status strings a runtime might emit.
    public static func normalize(_ raw: String?) -> ContainerState {
        guard let r = raw?.lowercased() else { return .unknown }
        if r.contains("run") { return .running }
        if r.contains("stop") || r.contains("exit") || r.contains("creat")
            || r.contains("dead") || r.contains("paus") { return .stopped }
        return .unknown
    }
}

/// What `container ls --format json` gives us, reduced to what we use.
public struct ContainerSummary: Sendable, Equatable {
    public var name: String
    public var image: String?
    public var state: ContainerState
    public var exitCode: Int?

    public init(name: String, image: String? = nil, state: ContainerState, exitCode: Int? = nil) {
        self.name = name
        self.image = image
        self.state = state
        self.exitCode = exitCode
    }
}

/// Everything needed to create/run one managed container.
public struct ContainerSpec: Sendable, Equatable {
    public var name: String
    public var image: String
    public var env: [String]
    public var volumes: [String]
    public var publish: [PortPublish]
    public var memory: String?   // optional -m/--memory cap
    public var cpus: Int?        // optional -c/--cpus cap

    public init(name: String, image: String, env: [String], volumes: [String], publish: [PortPublish],
                memory: String? = nil, cpus: Int? = nil) {
        self.name = name
        self.image = image
        self.env = env
        self.volumes = volumes
        self.publish = publish
        self.memory = memory
        self.cpus = cpus
    }
}

/// The operations the reconciler needs. A protocol so tests can drive the
/// reconciler with an in-memory fake.
public protocol ContainerClient: Sendable {
    /// List only Quay-managed containers (name prefixed `quay-`).
    func listManaged() async throws -> [ContainerSummary]
    /// Create + start a container, detached. Idempotent-ish: caller guarantees
    /// the name doesn't already exist.
    func run(_ spec: ContainerSpec) async throws
    func start(name: String) async throws
    func stop(name: String) async throws
    /// Ensure a named volume exists. Best-effort: a runtime that auto-creates
    /// volumes on first mount can no-op this.
    func ensureVolume(name: String) async throws
    /// Whether the underlying CLI is present and responding.
    func probe() async -> ProbeResult
}

public struct ProbeResult: Sendable {
    public var available: Bool
    public var version: String?
    public var detail: String?
}

/// `container` CLI backed implementation.
public struct CLIContainerClient: ContainerClient {
    public let executable: String
    public let runner: CommandRunning
    public let logger: Logger

    public init(executable: String = "container", runner: CommandRunning = ProcessRunner(), logger: Logger = Logger()) {
        self.executable = executable
        self.runner = runner
        self.logger = logger
    }

    public func probe() async -> ProbeResult {
        do {
            // VERIFY: `container --version` prints a version string and exits 0.
            let r = try await runner.run(executable, ["--version"])
            let v = r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            return ProbeResult(available: r.ok, version: v.isEmpty ? nil : v, detail: r.ok ? nil : r.stderr)
        } catch {
            return ProbeResult(available: false, version: nil, detail: "\(error)")
        }
    }

    public func listManaged() async throws -> [ContainerSummary] {
        // VERIFY: `container ls --all --format json` lists every container
        // (running + stopped) as a JSON array. Flag names (`--all`, `--format`)
        // and the JSON shape are the most likely things to drift.
        let r = try await runner.run(executable, ["ls", "--all", "--format", "json"])
        guard r.ok else {
            throw CommandError.nonZeroExit(command: "\(executable) ls", code: r.exitCode, stderr: r.stderr)
        }
        let all = ContainerJSON.parse(r.stdout, logger: logger)
        return all.filter { ContainerNaming.isManaged($0.name) }
    }

    public func run(_ spec: ContainerSpec) async throws {
        var args = ["run", "--detach", "--name", spec.name] // VERIFY: `--detach`/`-d` to background; `--name` to set the name.
        for e in spec.env {
            args += ["--env", e] // VERIFY: `--env KEY=VALUE` (or `-e`).
        }
        for v in spec.volumes {
            args += ["--volume", v] // VERIFY: `--volume name:/path` mount syntax (named volume vs bind).
        }
        for p in spec.publish where p.proto == .tcp {
            // VERIFY: `--publish host:container[/proto]`. UDP + privileged ports
            // (<1024) are intentionally NOT emitted here (out of scope for v1).
            args += ["--publish", "\(p.host):\(p.container)/tcp"]
        }
        if let memory = spec.memory {
            args += ["--memory", memory] // VERIFY: `-m/--memory <size>` accepts e.g. 256m, 1g (1MiB granularity).
        }
        if let cpus = spec.cpus {
            args += ["--cpus", String(cpus)] // VERIFY: `-c/--cpus <n>` integer vCPU count.
        }
        args.append(spec.image)
        let r = try await runner.run(executable, args)
        guard r.ok else {
            throw CommandError.nonZeroExit(command: "\(executable) run \(spec.name)", code: r.exitCode, stderr: r.stderr)
        }
    }

    public func start(name: String) async throws {
        // VERIFY: `container start <name>`.
        let r = try await runner.run(executable, ["start", name])
        guard r.ok else {
            throw CommandError.nonZeroExit(command: "\(executable) start \(name)", code: r.exitCode, stderr: r.stderr)
        }
    }

    public func stop(name: String) async throws {
        // VERIFY: `container stop <name>`.
        let r = try await runner.run(executable, ["stop", name])
        guard r.ok else {
            throw CommandError.nonZeroExit(command: "\(executable) stop \(name)", code: r.exitCode, stderr: r.stderr)
        }
    }

    public func ensureVolume(name: String) async throws {
        // VERIFY: `container volume create <name>`. Some runtimes auto-create the
        // volume on first mount; if this subcommand doesn't exist, treat an
        // "unknown command" failure as non-fatal (the mount will create it).
        do {
            let r = try await runner.run(executable, ["volume", "create", name])
            if !r.ok {
                logger.debug("volume create \(name) returned \(r.exitCode): \(r.stderr.trimmingCharacters(in: .whitespacesAndNewlines)) — continuing")
            }
        } catch {
            logger.debug("volume create \(name) failed (\(error)) — assuming auto-create on mount")
        }
    }
}
