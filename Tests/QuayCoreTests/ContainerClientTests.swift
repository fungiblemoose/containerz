import XCTest
@testable import QuayCore

final class ContainerClientTests: XCTestCase {

    private func client(_ runner: RecordingRunner) -> CLIContainerClient {
        CLIContainerClient(executable: "container", runner: runner, logger: TestFixtures.silentLogger())
    }

    /// Return the argument immediately following `flag` (the flag's value).
    private func value(after flag: String, in args: [String]) -> String? {
        guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    func testRunEmitsAllFlagsIncludingResourceCaps() async throws {
        let runner = RecordingRunner()
        let spec = ContainerSpec(
            name: "quay-dns-pihole",
            image: "pihole/pihole:latest",
            env: ["TZ=UTC"],
            volumes: ["pihole-data:/etc/pihole"],
            publish: [PortPublish(host: 5353, container: 53, proto: .tcp)],
            memory: "256m",
            cpus: 1
        )
        try await client(runner).run(spec)

        let args = try XCTUnwrap(runner.calls.first?.args)
        XCTAssertEqual(args.first, "run")
        XCTAssertTrue(args.contains("--detach"))
        XCTAssertEqual(value(after: "--name", in: args), "quay-dns-pihole")
        XCTAssertEqual(value(after: "--env", in: args), "TZ=UTC")
        XCTAssertEqual(value(after: "--volume", in: args), "pihole-data:/etc/pihole")
        XCTAssertEqual(value(after: "--publish", in: args), "5353:53/tcp")
        XCTAssertEqual(value(after: "--memory", in: args), "256m")
        XCTAssertEqual(value(after: "--cpus", in: args), "1")
        XCTAssertEqual(args.last, "pihole/pihole:latest", "image must be the final positional arg")
    }

    func testRunOmitsResourceFlagsWhenUnset() async throws {
        let runner = RecordingRunner()
        let spec = ContainerSpec(name: "quay-x-y", image: "img:1",
                                 env: [], volumes: [], publish: [])
        try await client(runner).run(spec)

        let args = try XCTUnwrap(runner.calls.first?.args)
        XCTAssertFalse(args.contains("--memory"), "no --memory when memory is nil")
        XCTAssertFalse(args.contains("--cpus"), "no --cpus when cpus is nil")
    }

    func testRunThrowsOnNonZeroExit() async {
        let runner = RecordingRunner(result: CommandResult(exitCode: 1, stdout: "", stderr: "boom"))
        let spec = ContainerSpec(name: "quay-x-y", image: "img:1", env: [], volumes: [], publish: [])
        do {
            try await client(runner).run(spec)
            XCTFail("expected run to throw on non-zero exit")
        } catch {
            // expected
        }
    }
}
