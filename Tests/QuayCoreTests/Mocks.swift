import Foundation
@testable import QuayCore

/// In-memory ContainerClient that records calls and returns a programmable list.
final class MockContainerClient: ContainerClient, @unchecked Sendable {
    private let lock = NSLock()

    private var _available = true
    private var _version: String? = "container test 0.0.0"
    private var _listResult: [ContainerSummary] = []
    private var _runShouldThrow = false
    private var _startShouldThrow = false

    private var runCalls: [ContainerSpec] = []
    private var startCalls: [String] = []
    private var stopCalls: [String] = []
    private var ensureVolumeCalls: [String] = []

    // configuration (set from synchronous test code)
    var available: Bool {
        get { lock.withLock { _available } }
        set { lock.withLock { _available = newValue } }
    }
    var version: String? {
        get { lock.withLock { _version } }
        set { lock.withLock { _version = newValue } }
    }
    var listResult: [ContainerSummary] {
        get { lock.withLock { _listResult } }
        set { lock.withLock { _listResult = newValue } }
    }
    var runShouldThrow: Bool {
        get { lock.withLock { _runShouldThrow } }
        set { lock.withLock { _runShouldThrow = newValue } }
    }
    var startShouldThrow: Bool {
        get { lock.withLock { _startShouldThrow } }
        set { lock.withLock { _startShouldThrow = newValue } }
    }

    func probe() async -> ProbeResult {
        lock.withLock {
            ProbeResult(available: _available, version: _version, detail: _available ? nil : "mock unavailable")
        }
    }

    func listManaged() async throws -> [ContainerSummary] {
        lock.withLock { _listResult }
    }

    func run(_ spec: ContainerSpec) async throws {
        let shouldThrow = lock.withLock { () -> Bool in
            runCalls.append(spec)
            return _runShouldThrow
        }
        if shouldThrow { throw CommandError.nonZeroExit(command: "run", code: 1, stderr: "boom") }
    }

    func start(name: String) async throws {
        let shouldThrow = lock.withLock { () -> Bool in
            startCalls.append(name)
            return _startShouldThrow
        }
        if shouldThrow { throw CommandError.nonZeroExit(command: "start", code: 1, stderr: "boom") }
    }

    func stop(name: String) async throws {
        lock.withLock { stopCalls.append(name) }
    }

    func ensureVolume(name: String) async throws {
        lock.withLock { ensureVolumeCalls.append(name) }
    }

    // test accessors (snapshot copies under lock)
    var runs: [ContainerSpec] { lock.withLock { runCalls } }
    var starts: [String] { lock.withLock { startCalls } }
    var stops: [String] { lock.withLock { stopCalls } }
    var volumes: [String] { lock.withLock { ensureVolumeCalls } }
}

/// Health checker that always returns a fixed result and counts probes.
final class MockHealthChecker: HealthChecking, @unchecked Sendable {
    private let lock = NSLock()
    private var _result: HealthResult
    private var _checkCount = 0
    init(_ result: HealthResult) { self._result = result }
    var result: HealthResult {
        get { lock.withLock { _result } }
        set { lock.withLock { _result = newValue } }
    }
    /// Number of times `check` was actually invoked (used to assert throttling).
    var checkCount: Int { lock.withLock { _checkCount } }
    func check(_ spec: HealthSpec?) async -> HealthResult {
        lock.withLock { _checkCount += 1; return _result }
    }
}

/// Records the argv handed to a CLI so we can assert exactly what `container`
/// would be invoked with, without shelling out.
final class RecordingRunner: CommandRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var _calls: [(executable: String, args: [String])] = []
    private let result: CommandResult
    init(result: CommandResult = CommandResult(exitCode: 0, stdout: "", stderr: "")) { self.result = result }
    var calls: [(executable: String, args: [String])] { lock.withLock { _calls } }
    func run(_ executable: String, _ args: [String]) async throws -> CommandResult {
        lock.withLock { _calls.append((executable, args)) }
        return result
    }
}

enum TestFixtures {
    /// A one-service stack used across reconciler tests.
    static func stack(restart: RestartPolicy = .always,
                      failuresToRestart: Int = 2,
                      failuresToUnhealthy: Int = 1) -> StackFile {
        let health = HealthSpec(type: .http, url: "http://127.0.0.1:3000/health",
                                intervalSeconds: 30, timeoutSeconds: 5,
                                failuresToUnhealthy: failuresToUnhealthy,
                                failuresToRestart: failuresToRestart)
        let svc = Service(image: "img:latest",
                          env: ["A=B"],
                          volumes: ["data:/d"],
                          publish: [PortPublish(host: 3000, container: 8080, proto: .tcp)],
                          restart: restart,
                          health: health)
        return StackFile(version: 1, stack: "demo", services: ["web": svc],
                         volumes: ["data": VolumeSpec()])
    }

    static let containerName = ContainerNaming.name(stack: "demo", service: "web")

    static func tempStatusStore() -> StatusStore {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("quay-test-\(UUID().uuidString)")
            .appendingPathComponent("status.json")
        return StatusStore(url: url)
    }

    static func silentLogger() -> Logger { Logger(subsystem: "test", minLevel: .error) }
}
