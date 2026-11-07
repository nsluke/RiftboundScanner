import Foundation
import RiftboundRecognizer

enum BuildIndexCommand {
    static func run(_ arguments: ArraySlice<String>) async throws {
        let options = try CommandLineOptions(arguments)
        let catalogURL = options.url("cards", default: Defaults.catalogPath)
        let imagesURL = options.url("images", default: Defaults.imagesPath)
        let outputURL = options.url("output", default: Defaults.indexPath)
        let concurrency = try options.int("concurrency", default: ProcessInfo.processInfo.activeProcessorCount)

        let catalog = try CardCatalog.load(from: catalogURL)
        Console.line("Catalog: \(catalog.cards.count) printings (\(catalog.skipped.count) skipped)")
        for skipped in catalog.skipped.prefix(10) {
            Console.line("  skipped \(skipped.id): \(skipped.reason)")
        }

        let renderer = ImageRenderer()
        let canvas = CanvasSpecification.standard
        let builder = CardIndexBuilder(
            rectifier: CardRectifier(renderer: renderer, canvas: canvas),
            extractor: CardDescriptorExtractor(featurePrinter: VisionFeaturePrintGenerator(), canvas: canvas),
            maxConcurrency: concurrency
        )
        let clock = ContinuousClock()
        let start = clock.now
        let outcome = await builder.build(
            cards: catalog.cards,
            image: { card in
                let url = ReferenceImageCache.url(for: card.id, in: imagesURL)
                guard FileManager.default.fileExists(atPath: url.path) else { return nil }
                return try ImageFile.load(url, maxPixelSize: nil)
            },
            progress: { completed, total in
                if completed % 100 == 0 || completed == total {
                    Console.line("  \(completed)/\(total)")
                }
            }
        )
        if let failure = outcome.calibrationFailure {
            throw UsageError("could not compute the calibration print, so the index would not record its embedding: \(failure)")
        }
        try outcome.index.write(to: outputURL)
        let size = (try? FileManager.default.attributesOfItem(atPath: outputURL.path)[.size] as? Int) ?? 0
        Console.line("Indexed \(outcome.index.entries.count) printings in \(Console.seconds(clock.now - start)) → \(outputURL.path) (\(size / 1024) KB)")
        if let hash = outcome.index.calibrationHash {
            Console.line("Calibration print recorded: hash \(hash.hex) (\(RecognizerInfo.platform) \(RecognizerInfo.osVersion)); compare with `riftscan check-revision` on the phone")
        }
        if !outcome.missingImages.isEmpty {
            Console.line("Missing images: \(outcome.missingImages.count) (run Scripts/fetch-images.py)")
        }
        for failure in outcome.failures {
            Console.error("  failed \(failure.id): \(failure.reason)")
        }
    }
}
