import XCTest
@testable import QuayCore

final class StatusTests: XCTestCase {
    func testRoundTrip() throws {
        let snap = StatusSnapshot(
            version: 1,
            generatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            daemonHealthy: true,
            containerRuntimeAvailable: true,
            runtimeVersion: "container 0.1.0",
            stacks: [
                StackStatus(stack: "openwebui", services: [
                    ServiceStatus(service: "openwebui", containerName: "quay-openwebui-openwebui",
                                  image: "img", state: .healthy, health: .green, restartCount: 2,
                                  backoffAttempt: 0, nextActionAt: nil, lastError: nil)
                ])
            ],
            orphans: ["quay-old-thing"]
        )
        let data = try StatusStore.encode(snap)
        let decoded = try StatusStore.decode(data)
        XCTAssertEqual(decoded, snap)
    }

    func testAggregateGreenWhenAllHealthy() {
        let snap = makeSnapshot(states: [.healthy, .running])
        XCTAssertEqual(snap.aggregate, .green)
    }

    func testAggregateYellowWhenStarting() {
        let snap = makeSnapshot(states: [.healthy, .starting])
        XCTAssertEqual(snap.aggregate, .yellow)
    }

    func testAggregateRedWhenFailed() {
        let snap = makeSnapshot(states: [.healthy, .failed])
        XCTAssertEqual(snap.aggregate, .red)
    }

    func testAggregateRedWhenUnhealthy() {
        let snap = makeSnapshot(states: [.running, .unhealthy])
        XCTAssertEqual(snap.aggregate, .red)
    }

    func testAggregateRedWhenRuntimeMissing() {
        let snap = StatusSnapshot(containerRuntimeAvailable: false)
        XCTAssertEqual(snap.aggregate, .red)
    }

    private func makeSnapshot(states: [ServiceRunState]) -> StatusSnapshot {
        let svcs = states.enumerated().map { i, st in
            ServiceStatus(service: "s\(i)", containerName: "quay-x-s\(i)", image: "img",
                          state: st, health: .green, restartCount: 0,
                          backoffAttempt: 0, nextActionAt: nil, lastError: nil)
        }
        return StatusSnapshot(stacks: [StackStatus(stack: "x", services: svcs)])
    }
}
