import Foundation
import Testing
@testable import RiftboundScannerApp

@Suite("Feeder messages")
struct FeederMessageTests {
    @Test(arguments: [
        ("CONNECTED", FeederMessage.connected),
        ("FWVER:0.1.5", .firmwareVersion("0.1.5")),
        ("FWVER:", .firmwareVersion("")),
        ("MOTOR:CARDLEN_SET", .cardLengthSet),
        ("MOTOR:COMPLETE", .feedComplete),
        ("MOTOR:JAM", .unrecognized("MOTOR:JAM")),
        ("", .unrecognized("")),
    ])
    func parsesTheObservedVocabulary(text: String, expected: FeederMessage) {
        #expect(FeederMessage(parsing: text) == expected)
    }

    @Test func parsesRawCharacteristicBytes() {
        let bytes = Data([0x4d, 0x4f, 0x54, 0x4f, 0x52, 0x3a, 0x43, 0x4f, 0x4d, 0x50, 0x4c, 0x45, 0x54, 0x45])
        #expect(FeederMessage(parsing: bytes) == .feedComplete)
    }

    @Test func nonASCIIBytesAreKeptAsHex() {
        #expect(FeederMessage(parsing: Data([0xff, 0x00])) == .unrecognized("ff00"))
    }

    @Test func commandsAreTheVendorAppsBytes() {
        #expect(FeederCommand.firmwareVersion.text == "FWVER")
        #expect(FeederCommand.feed(cardLength: 80).text == "MOTOR:START:80")
        #expect(FeederCommand.stop.text == "MOTOR:STOP")
        #expect(FeederCommand.feed(cardLength: FeederCommand.defaultCardLength).data == Data("MOTOR:START:80".utf8))
    }
}
