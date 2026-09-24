import Foundation
import Testing
@testable import RockyKit

/// `FIL-06`'s table, from a file's size and first bytes.
struct FileContentTests {
    private let text = Data("hello\n".utf8)

    /// 2 MB and 20 MB exactly and one byte over: text, large text, too large (not looked at).
    @Test func followsTheTableAtItsLimits() {
        #expect(FileContent.classify(size: 0, head: Data()) == .text)
        #expect(FileContent.classify(size: FileContent.editableLimit, head: text) == .text)
        #expect(FileContent.classify(size: FileContent.editableLimit + 1, head: text) == .largeText)
        #expect(FileContent.classify(size: FileContent.readableLimit, head: text) == .largeText)
        #expect(FileContent.classify(size: FileContent.readableLimit + 1, head: text) == .tooLarge)
        #expect(FileContent.classify(size: FileContent.readableLimit + 1, head: Data([0])) == .tooLarge)
        #expect(FileContent.editableLimit == 2_000_000)
        #expect(FileContent.readableLimit == 20_000_000)
        #expect(TextFile.editableLimit == FileContent.editableLimit)
        #expect(TextFile.readableLimit == FileContent.readableLimit)
    }

    @Test func aNULInTheFirst8KBIsBinary() {
        var head = Data(repeating: UInt8(ascii: "a"), count: FileContent.sniffLength)
        head[FileContent.sniffLength - 1] = 0
        #expect(FileContent.classify(size: 100_000, head: head) == .binary)
        #expect(FileContent.classify(size: 4, head: Data([0x89, 0x50, 0x00, 0x47])) == .binary)
        #expect(FileContent.classify(size: FileContent.editableLimit + 1, head: Data([0])) == .binary)
    }

    @Test func aNULAfter8KBIsText() {
        var bytes = Data(repeating: UInt8(ascii: "a"), count: FileContent.sniffLength + 10)
        bytes[FileContent.sniffLength] = 0
        #expect(FileContent.classify(size: bytes.count, head: bytes) == .text)
        #expect(FileContent.classify(size: bytes.count, head: bytes.prefix(FileContent.sniffLength)) == .text)
    }
}
