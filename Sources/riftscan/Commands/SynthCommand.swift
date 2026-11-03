import Foundation
import RiftboundRecognizer

enum SynthCommand {
    static func run(_ arguments: ArraySlice<String>) throws {
        let options = try CommandLineOptions(arguments)
        let catalogURL = options.url("cards", default: Defaults.catalogPath)
        let imagesURL = options.url("images", default: Defaults.imagesPath)
        let outputURL = options.url("output", default: Defaults.syntheticPath)
        let count = try options.int("count", default: 100)
        let seed = try options.uint64("seed", default: 42)
        let severities = try options.string("severities", default: "mild,moderate,harsh")
            .split(separator: ",")
            .map { name throws(UsageError) -> Severity in
                guard let severity = Severity(rawValue: String(name)) else { throw UsageError("unknown severity '\(name)'") }
                return severity
            }

        let catalog = try CardCatalog.load(from: catalogURL)
        let available = catalog.cards.filter {
            FileManager.default.fileExists(atPath: ReferenceImageCache.url(for: $0.id, in: imagesURL).path)
        }
        guard !available.isEmpty else { throw UsageError("no reference images under \(imagesURL.path); run Scripts/fetch-images.py") }

        let renderer = ImageRenderer()
        let rectifier = CardRectifier(renderer: renderer, canvas: .standard)
        let synthesizer = SyntheticPhotoRenderer(renderer: renderer)
        var generator = SeededRandomNumberGenerator(seed: seed)
        var cases: [EvaluationCase] = []
        let clock = ContinuousClock()
        let start = clock.now

        for severity in severities {
            let folder = outputURL.appendingPathComponent(severity.rawValue)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            for number in 0..<count {
                let card = available[Int.random(in: 0..<available.count, using: &generator)]
                let reference = try ImageFile.load(ReferenceImageCache.url(for: card.id, in: imagesURL), maxPixelSize: nil)
                let canvasImage = try rectifier.canonicalImage(fromReference: reference, orientation: card.orientation)
                let parameters = SyntheticPhotoParameters.random(severity: severity, using: &generator)
                let photo = try synthesizer.render(card: canvasImage, parameters: parameters)
                let fileName = String(format: "%03d-", number) + ReferenceImageCache.fileName(for: card.id).replacingOccurrences(of: ".png", with: ".jpg")
                let relativePath = "\(severity.rawValue)/\(fileName)"
                try ImageFile.write(photo.image, to: outputURL.appendingPathComponent(relativePath), as: .jpeg(quality: parameters.jpegQuality))
                cases.append(EvaluationCase(file: relativePath, expected: card.id, group: severity.rawValue, parameters: parameters))
            }
            Console.line("  \(severity.rawValue): \(count) photos")
        }
        try EvaluationManifest(generatedAt: Date(), seed: seed, cases: cases).write(to: outputURL)
        Console.line("Wrote \(cases.count) synthetic photos and \(EvaluationManifest.fileName) to \(outputURL.path) in \(Console.seconds(clock.now - start))")
    }
}
