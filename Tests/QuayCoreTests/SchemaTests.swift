import XCTest
@testable import QuayCore

final class SchemaTests: XCTestCase {
    /// The canonical example must parse and round its values correctly.
    func testParsesExampleStack() throws {
        let yaml = """
        version: 1
        stack: openwebui
        services:
          openwebui:
            image: ghcr.io/open-webui/open-webui:main
            env:
              - "WEBUI_AUTH=true"
            volumes:
              - "openwebui-data:/app/backend/data"
            publish:
              - host: 3000
                container: 8080
                protocol: tcp
            restart: always
            health:
              type: http
              url: "http://127.0.0.1:3000/health"
              interval_seconds: 30
              timeout_seconds: 5
              failures_to_unhealthy: 3
              failures_to_restart: 6
        volumes:
          openwebui-data: {}
        """
        let stack = try StackLoader.parse(yaml)
        XCTAssertEqual(stack.version, 1)
        XCTAssertEqual(stack.stack, "openwebui")
        let svc = try XCTUnwrap(stack.services["openwebui"])
        XCTAssertEqual(svc.image, "ghcr.io/open-webui/open-webui:main")
        XCTAssertEqual(svc.env, ["WEBUI_AUTH=true"])
        XCTAssertEqual(svc.volumes, ["openwebui-data:/app/backend/data"])
        XCTAssertEqual(svc.publish.count, 1)
        XCTAssertEqual(svc.publish[0].host, 3000)
        XCTAssertEqual(svc.publish[0].container, 8080)
        XCTAssertEqual(svc.publish[0].proto, .tcp)
        XCTAssertEqual(svc.restart, .always)
        XCTAssertEqual(svc.health?.type, .http)
        XCTAssertEqual(svc.health?.failuresToRestart, 6)
        XCTAssertEqual(stack.volumes["openwebui-data"], VolumeSpec())
    }

    /// Missing keys MUST default rather than throw (custom decoders).
    func testDefaultsForMissingKeys() throws {
        let yaml = """
        stack: minimal
        services:
          web:
            image: nginx:latest
            publish:
              - host: 8080
                container: 80
        """
        let stack = try StackLoader.parse(yaml)
        XCTAssertEqual(stack.version, 1, "version defaults to 1")
        let svc = try XCTUnwrap(stack.services["web"])
        XCTAssertEqual(svc.restart, .always, "restart defaults to always")
        XCTAssertEqual(svc.env, [])
        XCTAssertEqual(svc.volumes, [])
        XCTAssertNil(svc.health)
        XCTAssertEqual(svc.publish[0].proto, .tcp, "protocol defaults to tcp")
    }

    func testHealthDefaultsWhenPartiallySpecified() throws {
        let yaml = """
        stack: h
        services:
          s:
            image: img
            health:
              type: http
              url: "http://localhost/health"
        """
        let stack = try StackLoader.parse(yaml)
        let h = try XCTUnwrap(stack.services["s"]?.health)
        XCTAssertEqual(h.intervalSeconds, 30)
        XCTAssertEqual(h.timeoutSeconds, 5)
        XCTAssertEqual(h.failuresToUnhealthy, 3)
        XCTAssertEqual(h.failuresToRestart, 6)
    }

    func testRestartPolicyLenientDecoding() throws {
        func policy(_ raw: String) throws -> RestartPolicy {
            let yaml = "stack: s\nservices:\n  s:\n    image: i\n    restart: \(raw)\n"
            return try XCTUnwrap(StackLoader.parse(yaml).services["s"]?.restart)
        }
        XCTAssertEqual(try policy("always"), .always)
        XCTAssertEqual(try policy("on-failure"), .onFailure)
        XCTAssertEqual(try policy("never"), .never)
        XCTAssertEqual(try policy("garbage"), .always, "unknown -> always")
    }

    func testUnknownHealthTypeBecomesUnknown() throws {
        let yaml = """
        stack: s
        services:
          s:
            image: i
            health:
              type: dns
              url: "x"
        """
        let stack = try StackLoader.parse(yaml)
        XCTAssertEqual(stack.services["s"]?.health?.type, .unknown)
    }

    func testContainerNaming() {
        XCTAssertEqual(ContainerNaming.name(stack: "openwebui", service: "openwebui"),
                       "quay-openwebui-openwebui")
        XCTAssertTrue(ContainerNaming.isManaged("quay-foo-bar"))
        XCTAssertFalse(ContainerNaming.isManaged("random-container"))
    }
}
