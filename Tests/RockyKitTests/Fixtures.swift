import Foundation

enum Fixtures {
    static func url(_ name: String) -> URL {
        guard let url = Bundle.module.url(forResource: name, withExtension: "sh", subdirectory: "Fixtures") else {
            fatalError("missing fixture \(name).sh")
        }
        return url
    }

    /// A JSON file of `Fixtures`, such as `github-open.json`.
    static func json(_ name: String) -> Data {
        guard let url = Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"),
              let data = try? Data(contentsOf: url) else {
            fatalError("missing fixture \(name).json")
        }
        return data
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

/// A session with no network: every request fails as offline. `AppModel` tests pass it, so a selected workspace's
/// pull request refresh never reaches GitHub.
final class OfflineURLProtocol: URLProtocol {
    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OfflineURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
    }

    override func stopLoading() {}
}

/// Collects values produced on other tasks for assertions.
actor Recorder<Value: Sendable> {
    private(set) var values: [Value] = []
    func append(_ value: Value) { values.append(value) }
}
