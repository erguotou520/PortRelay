import XCTest
@testable import PortRelay

final class PortMappingPersistenceTests: XCTestCase {
    func testLegacyMappingDefaultsToDisabled() throws {
        let id = UUID()
        let serverID = UUID()
        let json = """
        {
          "id": "\(id.uuidString)",
          "serverID": "\(serverID.uuidString)",
          "name": "Web",
          "remoteHost": "127.0.0.1",
          "remotePort": 80,
          "localHost": "127.0.0.1",
          "localPort": 8082
        }
        """

        let mapping = try JSONDecoder().decode(PortMapping.self, from: Data(json.utf8))

        XCTAssertFalse(mapping.isEnabled)
    }

    func testEnabledStateRoundTrips() throws {
        let original = PortMapping(
            id: UUID(),
            serverID: UUID(),
            name: "Database",
            remoteHost: "127.0.0.1",
            remotePort: 5432,
            localHost: "127.0.0.1",
            localPort: 15432,
            isEnabled: true
        )

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(PortMapping.self, from: data)

        XCTAssertEqual(decoded, original)
        XCTAssertTrue(decoded.isEnabled)
    }
}
