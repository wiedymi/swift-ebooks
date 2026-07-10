import Foundation

enum DeterministicIdentifier {
    static func make(namespace: String, data: Data) -> String {
        var first: UInt64 = 0xcbf29ce484222325
        var second: UInt64 = 0x84222325cbf29ce4

        func consume(_ byte: UInt8) {
            first ^= UInt64(byte)
            first &*= 0x100000001b3
            second ^= UInt64(byte)
            second &*= 0x100000001b3
            second = (second << 7) | (second >> 57)
        }

        for byte in namespace.utf8 {
            consume(byte)
        }
        consume(0)
        for byte in data {
            consume(byte)
        }

        return String(
            format: "%@-%016llx%016llx",
            namespace.lowercased(),
            first,
            second
        )
    }
}
