import Foundation
import RiftboundRecognizer

/// Asks the server's gate the same questions the Swift gate answered and
/// reports every disagreement (ADR-002, open risk: the gate exists twice).
/// Input is either the shared fixture (`Tests/Fixtures/admission-cases.json`,
/// one request per case) or a `build-overlay --dump` (every gate call of a
/// fold, replayed in order with the exemplars as they stood). Each request is
/// posted to `POST /api/learning/admit/dry-run` and the decoded
/// `AdmissionOutcome` is compared with the local one. Exit 1 on any mismatch.
enum GateDiffCommand {
    static func run(_ arguments: ArraySlice<String>) async throws {
        let options = try CommandLineOptions(arguments, booleanFlags: ["verbose"])
        let path = try options.positional(0, named: "admission-cases.json | admissions.json")
        let server = options.string("server", default: Defaults.serverURL)
        guard let base = URL(string: server) else { throw UsageError("--server is not a URL: \(server)") }
        let token = options.string("token")
        let limit = try options.int("limit", default: Int.max)
        let foldName = options.string("fold")

        let requests = try Self.requests(at: URL(fileURLWithPath: path), fold: foldName)
        guard !requests.isEmpty else { throw UsageError("nothing to diff in \(path)") }
        let client = DryRunClient(base: base, token: token)
        var mismatches = 0
        var failures = 0
        for (number, (name, request)) in requests.prefix(limit).enumerated() {
            let local = request.decide()
            do {
                let remote = try await client.decide(request)
                if remote == local {
                    if options.bool("verbose") {
                        Console.line("[\(number + 1)/\(min(limit, requests.count))] same   \(name): \(BuildOverlayCommand.describe(local))")
                    }
                } else {
                    mismatches += 1
                    Console.line("[\(number + 1)/\(min(limit, requests.count))] DIFFER \(name): swift \(BuildOverlayCommand.describe(local)) | server \(BuildOverlayCommand.describe(remote))")
                }
            } catch {
                failures += 1
                let message = (error as? URLError)?.localizedDescription ?? "\(error)"
                Console.line("[\(number + 1)/\(min(limit, requests.count))] ERROR  \(name): \(message)")
            }
        }
        let compared = min(limit, requests.count)
        Console.line("\(compared) requests against \(server): \(compared - mismatches - failures) agree, \(mismatches) differ, \(failures) failed")
        if mismatches > 0 || failures > 0 {
            throw MismatchError(mismatches: mismatches, failures: failures)
        }
    }

    struct MismatchError: Error, CustomStringConvertible {
        let mismatches: Int
        let failures: Int

        var description: String { "gate-diff found \(mismatches) mismatch(es) and \(failures) failed request(s)" }
    }

    /// The named requests a file holds: fixture cases, or a dump's folds replayed.
    static func requests(at url: URL, fold: String?) throws -> [(name: String, request: AdmissionRequest)] {
        let dump: AdmissionDump
        switch try AdmissionFile.read(from: url) {
        case .fixture(let fixture):
            return fixture.cases.map { ($0.name, fixture.request(for: $0)) }
        case .dump(let read):
            dump = read
        }
        let gate = ExemplarAdmission(policy: dump.policy, calibrationHash: dump.engine.calibrationHash)
        var requests: [(String, AdmissionRequest)] = []
        for current in dump.folds where fold == nil || current.name == fold {
            for step in gate.replay(dump.inputs(for: current)) {
                requests.append(("\(current.name)/\(step.request.candidate.scanID.uuidString.prefix(8))", step.request))
            }
        }
        return requests
    }

    /// Posts gate requests to the server's dry-run route.
    struct DryRunClient {
        let base: URL
        let token: String?
        let session = URLSession(configuration: {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.urlCache = nil
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            configuration.timeoutIntervalForRequest = 15
            return configuration
        }())

        struct ServerError: Error, CustomStringConvertible {
            let status: Int
            let body: String

            var description: String { "server answered \(status): \(body.prefix(200))" }
        }

        func decide(_ request: AdmissionRequest) async throws -> AdmissionOutcome {
            var urlRequest = URLRequest(url: base.appendingPathComponent("api/learning/admit/dry-run"))
            urlRequest.httpMethod = "POST"
            urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
            urlRequest.setValue("riftscan/\(RecognizerInfo.version)", forHTTPHeaderField: "X-Client")
            if let token {
                urlRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            urlRequest.httpBody = try encoder.encode(request)
            let (data, response) = try await session.data(for: urlRequest)
            guard let http = response as? HTTPURLResponse else { throw ServerError(status: 0, body: "no HTTP response") }
            guard (200..<300).contains(http.statusCode) else {
                throw ServerError(status: http.statusCode, body: String(decoding: data, as: UTF8.self))
            }
            return try JSONDecoder().decode(AdmissionOutcome.self, from: data)
        }
    }
}
