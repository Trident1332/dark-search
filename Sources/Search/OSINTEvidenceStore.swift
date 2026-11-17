import Foundation

/// Serialize evidence I/O away from the window's thread. A bookmark updates
/// one report, without rereading every saved report after each click.
final class OSINTEvidenceStore: @unchecked Sendable {
    private let queue = DispatchQueue(label: "Search.OSINTEvidence", qos: .utility)
    private var revisions: [UUID: Int] = [:]

    private func perform<Value>(_ work: @escaping () throws -> Value) async throws -> Value {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { continuation.resume(with: Result { try work() }) }
        }
    }
    func load(folder: URL) async throws -> [OSINTReport] {
        try await perform {
            let fm = FileManager.default
            guard fm.fileExists(atPath: folder.path) else { return [] }
            return try fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
                .filter { $0.pathExtension == "json" }
                .map { OSINTFacts.upgrade(try JSONDecoder().decode(OSINTReport.self, from: Data(contentsOf: $0))) }
                .sorted { $0.started > $1.started }
        }
    }
    func save(_ input: OSINTReport, image: Data?, folder: URL, revision: Int) async throws -> OSINTReport? {
        try await perform {
            guard revision >= self.revisions[input.id, default: 0] else { return nil }
            self.revisions[input.id] = revision
            let fm = FileManager.default
            var report = input
            try fm.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let file = folder.appendingPathComponent(report.id.uuidString + ".json")
            let imageFile = folder.appendingPathComponent(report.id.uuidString + ".image")
            guard report.findings.contains(where: \.saved) else {
                if fm.fileExists(atPath: file.path) { try fm.removeItem(at: file) }
                if fm.fileExists(atPath: imageFile.path) { try fm.removeItem(at: imageFile) }
                return nil
            }
            if let image {
                try image.write(to: imageFile, options: .atomic)
                try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: imageFile.path)
                report.imagePath = imageFile.path
            }
            try JSONEncoder().encode(report).write(to: file, options: .atomic)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            return report
        }
    }
    func restore(_ report: OSINTReport) async throws -> (OSINTReport, Data?) {
        try await perform {
            let upgraded = OSINTFacts.upgrade(report)
            let image = upgraded.imagePath.flatMap { try? Data(contentsOf: URL(fileURLWithPath: $0)) }
            return (upgraded, image)
        }
    }
}
