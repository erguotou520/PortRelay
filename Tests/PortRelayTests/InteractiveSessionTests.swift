import XCTest
@testable import PortRelay

final class InteractiveSessionTests: XCTestCase {
    @MainActor
    func testPreparingKubernetesSessionImmediatelySelectsVisibleConnectingSession() {
        let manager = GlobalSessionManager()

        let session = manager.prepareKubernetesSession(
            kind: .kubernetesLogs,
            namespace: "production",
            sourceName: "api"
        )

        XCTAssertEqual(manager.sessions.map(\.id), [session.id])
        XCTAssertEqual(manager.selectedSessionID, session.id)
        XCTAssertFalse(manager.isPanelCollapsed)
        XCTAssertEqual(session.status, .connecting)
        XCTAssertEqual(session.subtitle, "production / 正在获取 Pod…")
    }

    @MainActor
    func testPseudoTerminalAcceptsInputAndStreamsOutput() async throws {
        let session = CommandSession(kind: .sshShell, title: "Test", subtitle: "Local")
        session.start(
            executable: "/bin/sh",
            arguments: ["-i"],
            pseudoTerminal: true
        )
        defer { session.stop() }

        try await Task.sleep(for: .milliseconds(150))
        session.send(Data("echo PORTRELAY_INTERACTIVE_OK\n".utf8))

        for _ in 0..<20 where !session.output.contains("PORTRELAY_INTERACTIVE_OK") {
            try await Task.sleep(for: .milliseconds(100))
        }

        XCTAssertTrue(session.output.contains("PORTRELAY_INTERACTIVE_OK"), session.output)
    }
}
