import Foundation
import Testing
@testable import RiftboundScannerApp

@Suite("Finish policy")
struct FinishPolicyTests {
    private func card(hasNormal: Bool, hasFoil: Bool) -> VaultCard {
        VaultCard(
            code: "OGN-001", name: "Vi", set: "OGN", setName: "Origins", rarity: "Rare", type: "Unit", supertype: nil,
            domains: [], energy: nil, might: nil, power: nil, text: nil, flavor: nil, tags: [], tcgplayerID: nil,
            marketNormal: nil, marketFoil: nil, hasNormal: hasNormal, hasFoil: hasFoil, promo: false, banned: false,
            cardmarketURL: nil, image: URL(string: "https://example.invalid/OGN-001.webp")!
        )
    }

    @Test("the four flag combinations", arguments: [
        (hasNormal: true, hasFoil: false, expected: FinishPolicy.Resolution.forced(.normal)),
        (hasNormal: false, hasFoil: true, expected: .forced(.foil)),
        (hasNormal: true, hasFoil: true, expected: .prompt(default: .foil)),
        (hasNormal: false, hasFoil: false, expected: .unknown),
    ])
    func resolvesFromAvailability(hasNormal: Bool, hasFoil: Bool, expected: FinishPolicy.Resolution) {
        #expect(FinishPolicy.resolve(card: card(hasNormal: hasNormal, hasFoil: hasFoil), batchDefault: .foil) == expected)
    }

    @Test func bothFinishPrintingsTakeTheBatchDefault() {
        #expect(FinishPolicy.resolve(card: card(hasNormal: true, hasFoil: true), batchDefault: .normal) == .prompt(default: .normal))
        #expect(FinishPolicy.resolve(card: card(hasNormal: true, hasFoil: true), batchDefault: .foil) == .prompt(default: .foil))
    }

    @Test func singleFinishPrintingsIgnoreTheBatchDefault() {
        #expect(FinishPolicy.resolve(card: card(hasNormal: false, hasFoil: true), batchDefault: .normal) == .forced(.foil))
        #expect(FinishPolicy.resolve(card: card(hasNormal: true, hasFoil: false), batchDefault: .foil) == .forced(.normal))
    }

    @Test func aPrintingTheVaultLacksIsUnknown() {
        #expect(FinishPolicy.resolve(card: nil, batchDefault: .normal) == .unknown)
    }

    @Test func resolutionsTellTheUIWhatToPreselectAndWhetherToAsk() {
        #expect(FinishPolicy.Resolution.forced(.foil).preselectedFinish == .foil)
        #expect(!FinishPolicy.Resolution.forced(.foil).asksUser)
        #expect(FinishPolicy.Resolution.prompt(default: .normal).preselectedFinish == .normal)
        #expect(FinishPolicy.Resolution.prompt(default: .normal).asksUser)
        #expect(FinishPolicy.Resolution.unknown.preselectedFinish == nil)
        #expect(FinishPolicy.Resolution.unknown.asksUser)
    }

    @Test func finishEncodesAsItsName() throws {
        #expect(String(decoding: try JSONEncoder().encode([Finish.normal, .foil]), as: UTF8.self) == #"["normal","foil"]"#)
    }
}
