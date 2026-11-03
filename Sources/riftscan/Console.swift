import Foundation

enum Console {
    nonisolated static func line(_ text: String = "") {
        print(text)
        fflush(stdout)   // stream progress when stdout is a file or a pipe
    }

    nonisolated static func error(_ text: String) {
        FileHandle.standardError.write(Data((text + "\n").utf8))
    }

    nonisolated static func percent(_ value: Double) -> String {
        String(format: "%5.1f%%", value * 100)
    }

    nonisolated static func seconds(_ duration: Duration) -> String {
        let seconds = Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
        return String(format: "%.2f s", seconds)
    }

    nonisolated static func pad(_ text: String, _ width: Int) -> String {
        text.count >= width ? text : text + String(repeating: " ", count: width - text.count)
    }
}
