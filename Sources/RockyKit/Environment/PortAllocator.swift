/// Each workspace owns ten ports, `port` through `port + 9`, like Conductor's CONDUCTOR_PORT (spec Section 3).
/// Blocks start at 41000 and a freed block is reused. Rocky does not check whether another program listens there.
public enum PortAllocator {
    public static let firstPort = 41000
    public static let blockSize = 10

    public static func next(taken: [Int]) -> Int {
        let used = Set(taken)
        var candidate = firstPort
        while used.contains(candidate) { candidate += blockSize }
        return candidate
    }
}
