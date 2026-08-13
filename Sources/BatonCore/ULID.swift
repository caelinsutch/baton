import Foundation

/// Sortable identifier. Lexical order matches creation order.
public enum ULID {
    private static let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")
    private static let lock = NSLock()
    private static var lastMillis: UInt64 = 0
    private static var lastRandom: [UInt8] = []

    public static func generate(date: Date = Date()) -> String {
        let requested = UInt64(max(0, date.timeIntervalSince1970 * 1000))
        lock.lock()
        defer { lock.unlock() }

        // Only a strictly later millisecond earns a fresh random tail.
        //
        // Reseeding whenever the millisecond merely differs is not enough. Two
        // callers interleaving across a millisecond boundary can each reseed and
        // then fall back to the earlier timestamp, which yields a lower id after
        // a higher one. Clamping to `lastMillis` makes the whole process
        // monotonic, and it also survives a clock that steps backwards.
        let millis = max(requested, lastMillis)
        var random: [UInt8]
        if millis == lastMillis, lastRandom.count == 10 {
            // Same millisecond. Increment so the order stays stable.
            random = lastRandom
            var index = random.count - 1
            while index >= 0 {
                if random[index] == 0xFF {
                    random[index] = 0
                    index -= 1
                } else {
                    random[index] += 1
                    break
                }
            }
        } else {
            // Leave headroom in the top byte, so a long run inside a single
            // millisecond cannot overflow the tail.
            random = [UInt8.random(in: 0...0x7F)] + (0..<9).map { _ in UInt8.random(in: 0...255) }
        }
        lastMillis = millis
        lastRandom = random

        return encodeTime(millis) + encodeRandom(random)
    }

    private static func encodeTime(_ millis: UInt64) -> String {
        var out = [Character](repeating: "0", count: 10)
        var value = millis
        for index in stride(from: 9, through: 0, by: -1) {
            out[index] = alphabet[Int(value % 32)]
            value /= 32
        }
        return String(out)
    }

    private static func encodeRandom(_ bytes: [UInt8]) -> String {
        // 10 bytes hold 80 bits. Base32 turns that into 16 characters.
        var bits = 0
        var accumulator: UInt32 = 0
        var out = ""
        for byte in bytes {
            accumulator = (accumulator << 8) | UInt32(byte)
            bits += 8
            while bits >= 5 {
                bits -= 5
                let index = Int((accumulator >> UInt32(bits)) & 0x1F)
                out.append(alphabet[index])
            }
        }
        return out
    }
}
