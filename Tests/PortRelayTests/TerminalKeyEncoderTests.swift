import AppKit
import XCTest
@testable import PortRelay

final class TerminalKeyEncoderTests: XCTestCase {
    func testRegularTextAndReturnAreSentAsTerminalBytes() {
        XCTAssertEqual(
            TerminalKeyEncoder.data(keyCode: 0, characters: "ls", modifiers: []),
            Data("ls".utf8)
        )
        XCTAssertEqual(
            TerminalKeyEncoder.data(keyCode: 36, characters: "\r", modifiers: []),
            Data([0x0D])
        )
    }

    func testControlAndNavigationKeysUseTerminalSequences() {
        XCTAssertEqual(
            TerminalKeyEncoder.data(keyCode: 8, characters: "c", modifiers: [.control]),
            Data([0x03])
        )
        XCTAssertEqual(
            TerminalKeyEncoder.data(keyCode: 123, characters: nil, modifiers: []),
            Data("\u{001B}[D".utf8)
        )
        XCTAssertEqual(
            TerminalKeyEncoder.data(keyCode: 51, characters: nil, modifiers: []),
            Data([0x7F])
        )
    }
}
