import XCTest
@testable import PortRelay

final class SSHCommandBuilderTests: XCTestCase {
    func testShellUsesSSHConfigAlias() {
        let server = ServerProfile(
            id: UUID(),
            name: "生产环境",
            source: .sshConfig,
            sshAlias: "production",
            host: "10.0.0.8",
            port: 22,
            username: "deploy",
            authentication: .sshConfig,
            privateKeyPath: nil
        )

        let arguments = SSHCommandBuilder.connectionArguments(server: server)

        XCTAssertEqual(arguments.last, "production")
        XCTAssertFalse(arguments.contains("deploy@10.0.0.8"))
    }

    func testManualShellRetainsPortAndPrivateKey() {
        let server = ServerProfile(
            id: UUID(),
            name: "Test",
            source: .manual,
            sshAlias: nil,
            host: "example.com",
            port: 2202,
            username: "root",
            authentication: .privateKeyFile,
            privateKeyPath: "/tmp/id_ed25519"
        )

        let arguments = SSHCommandBuilder.connectionArguments(server: server)

        XCTAssertTrue(arguments.contains("2202"))
        XCTAssertTrue(arguments.contains("/tmp/id_ed25519"))
        XCTAssertEqual(arguments.last, "root@example.com")
    }
}
