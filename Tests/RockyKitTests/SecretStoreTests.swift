import Foundation
import Testing
@testable import RockyKit

struct SecretStoreTests {
    @Test func inMemoryStoreReadsWritesAndDeletes() throws {
        let store = InMemorySecretStore()
        #expect(try store.read(account: "repo/TOKEN") == nil)
        try store.write("s3cret", account: "repo/TOKEN")
        #expect(try store.read(account: "repo/TOKEN") == "s3cret")
        try store.delete(account: "repo/TOKEN")
        try store.delete(account: "repo/TOKEN")
        #expect(try store.read(account: "repo/TOKEN") == nil)
    }

    /// Uses the real login Keychain, under a service unique to this run.
    @Test func keychainRoundTrip() throws {
        let store = KeychainSecretStore(service: "dev.jhzl.rocky.tests.\(UUID().uuidString)")
        defer { try? store.delete(account: "repo/TOKEN") }
        #expect(try store.read(account: "repo/TOKEN") == nil)
        try store.write("s3cret", account: "repo/TOKEN")
        try store.write("s3cret-2", account: "repo/TOKEN")
        #expect(try store.read(account: "repo/TOKEN") == "s3cret-2")
        try store.delete(account: "repo/TOKEN")
        #expect(try store.read(account: "repo/TOKEN") == nil)
    }
}
