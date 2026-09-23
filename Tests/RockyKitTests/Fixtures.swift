import Foundation

enum Fixtures {
    static func url(_ name: String) -> URL {
        guard let url = Bundle.module.url(forResource: name, withExtension: "sh", subdirectory: "Fixtures") else {
            fatalError("missing fixture \(name).sh")
        }
        return url
    }

    static func temporaryDirectory(_ label: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("rocky-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.resolvingSymlinksInPath()
    }

    static func stderrLog() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("rocky-agent-\(UUID().uuidString).log")
    }
}

/// Collects values produced on other tasks for assertions.
actor Recorder<Value: Sendable> {
    private(set) var values: [Value] = []
    func append(_ value: Value) { values.append(value) }
}
