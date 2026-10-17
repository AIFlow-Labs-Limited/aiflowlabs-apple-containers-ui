import Foundation

/// Incrementally splits raw pipe output into text lines.
///
/// `\n`, `\r\n` and a bare `\r` all end a line: the CLI's progress output rewrites the current terminal
/// line with `\r`, and each rewrite is a meaningful update for a streaming UI. ANSI escape sequences are
/// removed so colored output never leaks into the app.
struct LineSplitter: Sendable {
    private var buffer: [UInt8] = []
    private var lastWasCarriageReturn = false

    init() {}

    /// Feeds a chunk and returns every line it completed.
    mutating func feed(_ data: Data) -> [String] {
        var lines: [String] = []
        for byte in data {
            switch byte {
            case 0x0A:  // \n
                // `\r\n` is one line break, not a progress rewrite followed by an empty line.
                if !(lastWasCarriageReturn && buffer.isEmpty) { lines.append(takeLine()) }
                lastWasCarriageReturn = false
            case 0x0D:  // \r
                if !buffer.isEmpty { lines.append(takeLine()) }
                lastWasCarriageReturn = true
            default:
                buffer.append(byte)
                lastWasCarriageReturn = false
            }
        }
        return lines
    }

    /// Returns the trailing partial line (output that did not end with a newline), if any.
    mutating func flush() -> [String] {
        buffer.isEmpty ? [] : [takeLine()]
    }

    private mutating func takeLine() -> String {
        defer { buffer.removeAll(keepingCapacity: true) }
        return LineSplitter.stripANSI(String(decoding: buffer, as: UTF8.self))
    }

    /// Removes CSI (`ESC [ … final`) and OSC (`ESC ] … BEL`) escape sequences.
    static func stripANSI(_ text: String) -> String {
        guard text.contains("\u{1B}") else { return text }
        var result = String.UnicodeScalarView()
        var scalars = text.unicodeScalars.makeIterator()
        while let scalar = scalars.next() {
            guard scalar == "\u{1B}" else { result.append(scalar); continue }
            guard let introducer = scalars.next() else { break }
            if introducer == "[" {
                // Parameters and intermediates until a final byte in 0x40...0x7E.
                while let next = scalars.next(), !(0x40...0x7E).contains(next.value) {}
            } else if introducer == "]" {
                while let next = scalars.next(), next != "\u{07}" {}
            }
            // Other two-byte escapes (ESC c, ESC 7, …) are dropped along with the introducer.
        }
        return String(result)
    }
}
