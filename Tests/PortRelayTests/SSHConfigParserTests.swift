import XCTest
@testable import PortRelay

final class SSHConfigParserTests: XCTestCase {
    func testParsesConcreteHostsAndSkipsPatterns() {
        let contents = """
        Host *
          ServerAliveInterval 60

        Host production prod
          HostName 10.0.0.8
          User deploy
          Port 2202
          IdentityFile ~/.ssh/deploy_key

        Host *.internal !blocked.internal
          User root
        """

        let entries = SSHConfigParser.parse(contents)

        XCTAssertEqual(entries.map(\.alias), ["production", "prod"])
        XCTAssertEqual(entries[0].hostName, "10.0.0.8")
        XCTAssertEqual(entries[0].user, "deploy")
        XCTAssertEqual(entries[0].port, 2202)
        XCTAssertTrue(entries[0].identityFile?.hasSuffix("/.ssh/deploy_key") == true)
    }

    func testUsesSafeDefaultsForMinimalHost() {
        let entries = SSHConfigParser.parse("Host staging\n  # no explicit values\n")

        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].alias, "staging")
        XCTAssertEqual(entries[0].hostName, "staging")
        XCTAssertEqual(entries[0].port, 22)
        XCTAssertEqual(entries[0].user, NSUserName())
    }

    func testIgnoresDuplicateAliases() {
        let entries = SSHConfigParser.parse("""
        Host same
          HostName first.example.com
        Host same
          HostName second.example.com
        """)

        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].hostName, "first.example.com")
    }
}
