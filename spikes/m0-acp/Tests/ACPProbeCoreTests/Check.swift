import Foundation

nonisolated(unsafe) var failures = 0

func check(_ condition: @autoclosure () -> Bool, _ message: String, file: StaticString = #filePath, line: UInt = #line) {
    if !condition() {
        failures += 1
        print("FAIL \(file):\(line) \(message)")
    }
}

func test(_ name: String, _ body: () throws -> Void) {
    do { try body(); print("ran \(name)") } catch { failures += 1; print("FAIL \(name) threw \(error)") }
}
