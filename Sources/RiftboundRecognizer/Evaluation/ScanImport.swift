import CoreGraphics
import Foundation

/// Reads the batches the iOS app writes (`<batch>/{batch.json, scans.json,
/// photos/}`) as the package sees them: just enough of each record to label a
/// photo, weight it and feed the admission gate. Version 1 files (a bare
/// `verdict`, no `purpose`) and version 2 files (ADR-002: a `decisions` log,
/// `captureQuality`, `analysis`, `engine`) both read; a v1 judgement is a
/// `legacy` decision and an unstated `captureQuality` is `legacy`, exactly as
/// the app's `ScanRecord` decode and `Scripts/summarize-scans.py` treat them,
/// so the three readers of one `scans/` folder agree. Everything the package
/// cannot use (candidate cards, URLs) is skipped on decode.
public enum ScanImport {
    public static let batchFileName = "batch.json"
    public static let scansFileName = "scans.json"
    /// Photos are loaded with their long edge at most this many pixels: above
    /// the recogniser's 2048 default so a guide crop keeps its full resolution.
    public static let photoMaxPixelSize = 4096

    /// What `import-scans` makes of a folder of batches.
    public struct Result: Sendable {
        public let manifest: EvaluationManifest
        public let batches: [ImportedBatch]
        /// Judged scans that produced no case, by reason.
        public let skipped: [SkipReason: Int]
        /// Photos the importer could not read; their cases carry no `imageSize`.
        public let unreadablePhotos: [String]

        public var cases: [EvaluationCase] { manifest.cases }
    }

    /// The folder cannot be imported as it stands.
    public enum ImportError: Error, Hashable, CustomStringConvertible {
        /// One scan id appears in two batch folders (a scan pulled twice, or a
        /// record duplicated after a pull); the gate and the folds key by scan
        /// id, so the importer refuses rather than letting one copy shadow the other.
        case duplicateScan(scanID: UUID, batches: [String])

        public var description: String {
            switch self {
            case .duplicateScan(let scanID, let batches):
                "scan \(scanID.uuidString) appears in more than one batch folder (\(batches.joined(separator: ", "))); remove the duplicate before importing"
            }
        }
    }

    public enum SkipReason: String, Hashable, Sendable, CaseIterable {
        /// No decision yet.
        case pending
        /// Rejected or voided: no card to expect.
        case noCard
        /// Decided by the recogniser, not a person (`autoAccepted`).
        case machineDecided
    }

    /// Every batch folder directly under `root` (or `root` itself), by start time.
    public static func batchFolders(under root: URL) throws -> [URL] {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: root.appendingPathComponent(batchFileName).path) {
            return [root]
        }
        let names = try fileManager.contentsOfDirectory(atPath: root.path)
        return names.sorted().map { root.appendingPathComponent($0) }.filter {
            fileManager.fileExists(atPath: $0.appendingPathComponent(batchFileName).path)
        }
    }

    public static func readBatch(at folder: URL) throws -> ImportedBatch {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let batch = try decoder.decode(BatchFile.self, from: try Data(contentsOf: folder.appendingPathComponent(batchFileName)))
        let scansURL = folder.appendingPathComponent(scansFileName)
        let scans = FileManager.default.fileExists(atPath: scansURL.path)
            ? try decoder.decode([ScanFile].self, from: try Data(contentsOf: scansURL)).map(ImportedScan.init)
            : []
        return ImportedBatch(
            id: batch.id,
            label: batch.label,
            startedAt: batch.startedAt,
            purpose: batch.purpose ?? "calibration",
            trainingQuality: batch.trainingQuality ?? .legacy,
            folder: folder,
            scans: scans.sorted { $0.capturedAt < $1.capturedAt }
        )
    }

    /// Builds the evaluation manifest for every batch under `root`: one case
    /// per scan whose latest decision was made by a person (`human`, `audit`,
    /// `spotCheck`, or the `legacy` decision a v1 verdict stands for) and
    /// confirms a card. Audit cases weigh `1 / auditRate`; the rest weigh 1.
    /// `file` paths are relative to `manifestFolder`. `imageSize` loads each
    /// photo (the live one at 4096 px) to record its size; a `nil` result marks
    /// the photo unreadable. Each case carries the record's capture quality as
    /// the app decodes it (`legacy` when unstated) and, separately, the quality
    /// the crop record and photo size would derive, for `build-overlay
    /// --derive-capture-quality`. A scan id met in two batch folders throws
    /// ``ImportError/duplicateScan(scanID:batches:)``.
    public static func importCases(
        under root: URL,
        manifestFolder: URL,
        auditRate: Double,
        now: Date = Date(),
        imageSize: (URL) -> PixelSize? = { url in (try? ImageFile.load(url, maxPixelSize: Self.photoMaxPixelSize)).map { PixelSize(width: $0.width, height: $0.height) } }
    ) throws -> Result {
        var cases: [EvaluationCase] = []
        var batches: [ImportedBatch] = []
        var skipped: [SkipReason: Int] = [:]
        var unreadable: [String] = []
        var batchByScan: [UUID: String] = [:]
        for folder in try batchFolders(under: root) {
            let batch = try readBatch(at: folder)
            batches.append(batch)
            for scan in batch.scans {
                if let other = batchByScan[scan.id] {
                    throw ImportError.duplicateScan(scanID: scan.id, batches: [other, folder.lastPathComponent])
                }
                batchByScan[scan.id] = folder.lastPathComponent
                guard let decision = scan.decision else {
                    skipped[.pending, default: 0] += 1
                    continue
                }
                guard decision.kind.confirmsACard, let expected = decision.cardID else {
                    skipped[.noCard, default: 0] += 1
                    continue
                }
                guard decision.source != .autoAccepted else {
                    skipped[.machineDecided, default: 0] += 1
                    continue
                }
                let photoURL = folder.appendingPathComponent(scan.photoFileName)
                let size = imageSize(photoURL)
                if size == nil {
                    unreadable.append(scan.photoFileName)
                }
                cases.append(EvaluationCase(
                    file: relativePath(to: photoURL, from: manifestFolder),
                    expected: expected,
                    group: batch.displayName,
                    samplingWeight: decision.source == .audit ? 1 / auditRate : 1,
                    scanID: scan.id,
                    batchID: batch.id,
                    decisionSource: decision.source,
                    captureQuality: scan.captureQuality,
                    derivedCaptureQuality: scan.derivedCaptureQuality(photoSize: size),
                    imageSize: size
                ))
            }
        }
        let manifest = EvaluationManifest(generatedAt: now, seed: nil, cases: cases, platform: RecognizerInfo.platform, auditRate: auditRate)
        return Result(manifest: manifest, batches: batches, skipped: skipped, unreadablePhotos: unreadable)
    }

    /// `target` as a path relative to `folder` (`../scans/<batch>/photos/x.jpg`).
    /// Neither path is resolved through symbolic links or `/private`
    /// aliases (a `scans` link in a worktree stays `../scans/...`), so both
    /// should be spelled from the same root; `.` and `..` segments are folded.
    public static func relativePath(to target: URL, from folder: URL) -> String {
        let targetParts = foldedComponents(of: target)
        let folderParts = foldedComponents(of: folder)
        var common = 0
        while common < targetParts.count, common < folderParts.count, targetParts[common] == folderParts[common] {
            common += 1
        }
        let ups = Array(repeating: "..", count: folderParts.count - common)
        return (ups + targetParts[common...]).joined(separator: "/")
    }

    private static func foldedComponents(of url: URL) -> [String] {
        var parts: [String] = []
        for part in url.absoluteURL.pathComponents where part != "/" && part != "." {
            if part == ".." {
                if !parts.isEmpty { parts.removeLast() }
            } else {
                parts.append(part)
            }
        }
        return parts
    }

    // MARK: File shapes

    /// `batch.json`, the keys the package reads.
    struct BatchFile: Decodable {
        let id: UUID
        let label: String
        let startedAt: Date
        let purpose: String?
        let trainingQuality: AdmissionInput.CaptureQuality?
    }

    /// `scans.json` entries, the keys the package reads; everything else is ignored.
    struct ScanFile: Decodable {
        struct Placement: Decodable {
            let kind: String
            let confidence: Double?
        }

        struct Verdict: Decodable {
            let kind: AdmissionInput.DecisionKind
            let cardID: Card.ID?
        }

        struct Decision: Decodable {
            let seq: Int
            let verdict: Verdict
            let cardID: Card.ID?
            let source: AdmissionInput.DecisionSource
            let decidedAt: Date
        }

        struct Candidate: Decodable {
            struct CardRef: Decodable {
                let id: Card.ID
            }

            let card: CardRef
        }

        struct CodeReading: Decodable {
            let code: PrintedCode
            let confidence: Double
        }

        struct Crop: Decodable {
            let photoWidth: Int
            let photoHeight: Int
        }

        struct Analysis: Decodable {
            struct Descriptor: Decodable {
                struct Inner: Decodable {
                    let featurePrint: FeaturePrint
                }

                let descriptor: Inner
                let orientation: CardOrientation
            }

            struct Alternative: Decodable {
                let code: PrintedCode
                let origin: CodeOrigin
                let referenceSimilarity: Double?
            }

            let descriptor: Descriptor
            let codeSource: CodeSource?
            let codeAlternatives: [Alternative]?
        }

        struct Engine: Decodable {
            let calibrationHash: String
        }

        let id: UUID
        let batchID: UUID
        let capturedAt: Date
        let photoFileName: String
        let rectifiedFileName: String?
        let placement: Placement
        let codeReading: CodeReading?
        let candidates: [Candidate]
        let decisions: [Decision]?
        let verdict: Verdict?
        let verdictAt: Date?
        let crop: Crop?
        let captureQuality: AdmissionInput.CaptureQuality?
        let analysis: Analysis?
        let engine: Engine?
    }
}

/// A batch folder as imported.
public struct ImportedBatch: Hashable, Sendable, Identifiable {
    public let id: UUID
    public let label: String
    public let startedAt: Date
    /// `collection` or `calibration`; a v1 file is `calibration`.
    public let purpose: String
    /// The batch's training override; a v1 file is `legacy`.
    public let trainingQuality: AdmissionInput.CaptureQuality
    public let folder: URL
    public let scans: [ImportedScan]

    /// The label, or the id's first eight characters for an unlabelled batch.
    public var displayName: String {
        label.isEmpty ? String(id.uuidString.prefix(8)) : label
    }

    public var judgedScans: [ImportedScan] {
        scans.filter { $0.decision?.kind.confirmsACard == true }
    }
}

/// One scan record as imported: its photo, its latest decision, and what the
/// phone recorded about the recognition.
public struct ImportedScan: Hashable, Sendable, Identifiable {
    public struct Decision: Hashable, Sendable {
        public let seq: Int
        public let source: AdmissionInput.DecisionSource
        public let kind: AdmissionInput.DecisionKind
        /// The card the decision confirmed; `nil` for pending, rejected and voided.
        public let cardID: Card.ID?
        public let decidedAt: Date
    }

    /// The phone's own analysis (v2 records), when present.
    public struct Analysis: Hashable, Sendable {
        public let featurePrint: FeaturePrint
        public let orientation: CardOrientation
        public let codeSource: CodeSource?
        public let codeAlternatives: [AdmissionInput.CodeAlternative]
    }

    public let id: UUID
    public let batchID: UUID
    public let capturedAt: Date
    public let photoFileName: String
    public let rectifiedFileName: String?
    public let placement: AdmissionInput.Placement
    public let placementConfidence: Double?
    /// The code the phone read, if any.
    public let codeRead: PrintedCode?
    public let codeConfidence: Double?
    /// The phone's ranked printings, best first.
    public let candidateIDs: [Card.ID]
    /// The latest decision; a v1 judged record yields a synthesised `legacy` one.
    public let decision: Decision?
    public let hasCrop: Bool
    /// The quality the record states; `nil` for a v1 record, which the app and
    /// this importer both read as `legacy` (see ``captureQuality``).
    public let recordedCaptureQuality: AdmissionInput.CaptureQuality?
    public let analysis: Analysis?
    public let calibrationHash: String?

    init(_ file: ScanImport.ScanFile) {
        id = file.id
        batchID = file.batchID
        capturedAt = file.capturedAt
        photoFileName = file.photoFileName
        rectifiedFileName = file.rectifiedFileName
        placement = file.placement.kind == "wholeImage" ? .wholeImage : .detected
        placementConfidence = file.placement.confidence
        codeRead = file.codeReading?.code
        codeConfidence = file.codeReading?.confidence
        candidateIDs = file.candidates.map(\.card.id)
        hasCrop = file.crop != nil
        recordedCaptureQuality = file.captureQuality
        analysis = file.analysis.map { analysis in
            Analysis(
                featurePrint: analysis.descriptor.descriptor.featurePrint,
                orientation: analysis.descriptor.orientation,
                codeSource: analysis.codeSource,
                codeAlternatives: (analysis.codeAlternatives ?? []).map {
                    AdmissionInput.CodeAlternative(code: $0.code, origin: $0.origin, referenceSimilarity: $0.referenceSimilarity)
                }
            )
        }
        calibrationHash = file.engine?.calibrationHash
        if let last = file.decisions?.last {
            decision = Decision(seq: last.seq, source: last.source, kind: last.verdict.kind, cardID: last.cardID ?? last.verdict.cardID, decidedAt: last.decidedAt)
        } else if let verdict = file.verdict, verdict.kind != .pending {
            // A v1 judgement: the app synthesises a legacy seq-1 decision whose
            // card is the top candidate for `correct` and the named card for `corrected`.
            let cardID: Card.ID? = switch verdict.kind {
            case .correct: file.candidates.first?.card.id
            case .corrected: verdict.cardID
            case .pending, .rejected, .voided: nil
            }
            decision = Decision(seq: 1, source: .legacy, kind: verdict.kind, cardID: cardID, decidedAt: file.verdictAt ?? file.capturedAt)
        } else {
            decision = nil
        }
    }

    /// The card the latest decision confirmed.
    public var confirmedCardID: Card.ID? { decision?.cardID }

    /// The capture quality as the app decodes the record: what it states, else
    /// `legacy` (every pre-v2 record). This is what the gate sees on the phone
    /// and what the strict evaluation uses.
    public var captureQuality: AdmissionInput.CaptureQuality { recordedCaptureQuality ?? .legacy }

    /// The long edge a guide crop produces at full resolution, within tolerance
    /// (the app's `CaptureQuality` rule).
    public static let standardLongEdge = 1800...2200
    /// How far the photo's aspect may sit from the card's 63 : 88.
    public static let aspectTolerance = 0.03

    /// The quality the record would state had it been written by an app that
    /// knew the rule: what it states when it does, else `standard` iff the
    /// photo was a guide crop (`crop` present) at the standard size (the app's
    /// `CaptureQuality(crop:photoSize:)` rule), else `legacy`. Without a photo
    /// size nothing can be verified, so an unstated quality stays `legacy`.
    /// A measurement assumption (`build-overlay --derive-capture-quality`),
    /// never what the app or the strict gate uses.
    public func derivedCaptureQuality(photoSize: PixelSize?) -> AdmissionInput.CaptureQuality {
        if let recordedCaptureQuality { return recordedCaptureQuality }
        guard hasCrop, let photoSize, Self.isStandardSize(photoSize) else { return .legacy }
        return .standard
    }

    /// Portrait, card-shaped and at guide-crop resolution.
    public static func isStandardSize(_ size: PixelSize) -> Bool {
        guard size.width > 0, size.height > 0, size.height >= size.width else { return false }
        guard standardLongEdge.contains(size.height) else { return false }
        let cardAspect = 63.0 / 88.0
        let aspect = Double(size.width) / Double(size.height)
        return abs(aspect - cardAspect) / cardAspect <= aspectTolerance
    }
}

// MARK: - Gate inputs from a Mac recognition

/// A scan recognised on the Mac for the learning evaluation: the gate input
/// built from the result plus the reference standing the gate does not see,
/// which `admission-report` needs for the impostor distribution and the floor
/// ROC. Written by `build-overlay`.
public struct AnalysedScan: Hashable, Sendable, Codable, Identifiable {
    public let input: AdmissionInput
    /// The photo's path as the manifest names it.
    public let file: String
    public let group: String
    /// The best feature-print cosine to a reference of a *different* art group:
    /// the impostor side of the reference floor.
    public let bestOtherReferenceSimilarity: Double
    public let bestOtherArtGroup: ArtGroup?
    /// The recogniser's winner on the Mac, for the record.
    public let topCardID: Card.ID?
    public let codeRead: PrintedCode?
    /// What the crop record and photo size say the capture quality would be
    /// (``ImportedScan/derivedCaptureQuality(photoSize:)``); `input` carries
    /// the quality as the app decodes it. `AdmissionDump.Assumptions`
    /// substitutes this under `--derive-capture-quality`.
    public let derivedCaptureQuality: AdmissionInput.CaptureQuality?

    public var id: UUID { input.scanID }

    public init(input: AdmissionInput, file: String, group: String, bestOtherReferenceSimilarity: Double, bestOtherArtGroup: ArtGroup?, topCardID: Card.ID?, codeRead: PrintedCode?, derivedCaptureQuality: AdmissionInput.CaptureQuality? = nil) {
        self.input = input
        self.file = file
        self.group = group
        self.bestOtherReferenceSimilarity = bestOtherReferenceSimilarity
        self.bestOtherArtGroup = bestOtherArtGroup
        self.topCardID = topCardID
        self.codeRead = codeRead
        self.derivedCaptureQuality = derivedCaptureQuality
    }

    /// Builds the gate input for `evaluationCase` from what the Mac recogniser
    /// made of its photo. Placement, code and descriptor come from `result`;
    /// the decision, capture quality and batch override from the imported
    /// record; reference similarities are measured against `index` under the
    /// ``SimilarityContract``. The code's origin is the reading's own
    /// (``CodeReading/origin``), and every code the reading could name
    /// (``CodeReading/alternatives``: the literal reading when the index knows
    /// it, then the parser's digit alternatives) becomes a `CodeAlternative`
    /// with the best reference similarity among the printings it names exactly.
    public init(
        _ evaluationCase: EvaluationCase,
        scan: ImportedScan,
        batch: ImportedBatch,
        result: RecognitionResult,
        index: CardIndex
    ) {
        let print = result.descriptor.descriptor.featurePrint
        let expectedGroup = ArtGroup(evaluationCase.expected)
        let confirmed = index.entries.first { $0.id == evaluationCase.expected }
        var bestOther = (similarity: 0.0, group: ArtGroup?.none)
        var similarityByEntry: [Card.ID: Double] = [:]
        for entry in index.entries {
            let similarity = SimilarityContract.similarity(print, entry.descriptor.featurePrint)
            similarityByEntry[entry.id] = similarity
            if entry.artGroup != expectedGroup, similarity > bestOther.similarity {
                bestOther = (similarity, entry.artGroup)
            }
        }
        var alternatives: [AdmissionInput.CodeAlternative] = []
        var code: AdmissionInput.CodeEvidence?
        if let reading = result.codeReading {
            // `alternatives` starts with `code`; it is the literal reading only
            // when the reading itself is literal, every later entry is a repair.
            for (offset, candidate) in reading.alternatives.enumerated() {
                let named = index.entries.filter { CodeAgreement(reading: candidate, candidate: $0.card.code) == .exact }
                alternatives.append(AdmissionInput.CodeAlternative(
                    code: candidate,
                    origin: offset == 0 ? reading.origin : .alternative,
                    referenceSimilarity: named.compactMap { similarityByEntry[$0.id] }.max()
                ))
            }
            code = AdmissionInput.CodeEvidence(
                source: reading.source,
                origin: reading.origin,
                agreement: confirmed.map { CodeAgreement(reading: reading.code, candidate: $0.card.code) } ?? .unrelated
            )
        }
        let decision = scan.decision
        input = AdmissionInput(
            scanID: scan.id,
            batchID: batch.id,
            decisionSource: decision?.source ?? .legacy,
            decisionKind: decision?.kind ?? .pending,
            cardID: decision?.cardID,
            placement: result.quad == nil ? .wholeImage : .detected,
            calibrationHash: result.engine.calibrationHash,
            captureQuality: evaluationCase.captureQuality ?? scan.captureQuality,
            trainingQuality: batch.trainingQuality,
            code: code,
            referenceSimilarity: confirmed.flatMap { similarityByEntry[$0.id] } ?? 0,
            codeAlternatives: alternatives,
            featurePrint: print
        )
        file = evaluationCase.file
        group = evaluationCase.group
        bestOtherReferenceSimilarity = bestOther.similarity
        bestOtherArtGroup = bestOther.group
        topCardID = result.best?.id
        codeRead = result.codeReading?.code
        derivedCaptureQuality = evaluationCase.derivedCaptureQuality ?? scan.derivedCaptureQuality(photoSize: evaluationCase.imageSize)
    }
}
