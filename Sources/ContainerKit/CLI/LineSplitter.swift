import Foundation

/// Incrementally splits raw pipe output into text lines.
///
/// `\n`, `\r\n` and a bare `\r` all end a line: the CLI's progress output rewrites the current terminal
/// line with `\r`, and each rewrite is a meaningful update for a streaming UI. ANSI escape sequences are
/// removed so colored output never leaks into the app.
struct LineSplitter: Sendable {
    /// Longest line kept in memory; a longer run without a line break is split into chunks of this size.
    static let maxLineLength = 64 * 1024

    private var buffer: [UInt8] = []
    /// The previous byte was a `\r` that ended a non-empty line (so a following `\n` is part of `\r\n`).
    private var pendingCRLF = false

    init() {}

    /// Feeds a chunk and returns every line it completed.
    mutating func feed(_ data: Data) -> [String] {
        var lines: [String] = []
        for byte in data {
            switch byte {
            case 0x0A:  // \n
                // `\r\n` is one line break, not a progress rewrite followed by an empty line.
                if !(pendingCRLF && buffer.isEmpty) { lines.append(takeLine()) }
                pendingCRLF = false
            case 0x0D:  // \r
                if !buffer.isEmpty {
                    lines.append(takeLine())
                    pendingCRLF = true
                } else {
                    pendingCRLF = false
                }
            default:
                buffer.append(byte)
                pendingCRLF = false
                if buffer.count >= Self.maxLineLength { lines.append(takeOverlongPrefix()) }
            }
        }
        return lines
    }

    /// Returns the trailing partial line (output that did not end with a newline), if any.
    mutating func flush() -> [String] {
        buffer.isEmpty ? [] : [takeLine()]
    }

    /// Splits an over-long line at the last UTF-8 character boundary, keeping the remainder buffered.
    private mutating func takeOverlongPrefix() -> String {
        var cut = buffer.count
        // Back off over a trailing, possibly incomplete multi-byte sequence (at most 3 bytes).
        while cut > buffer.count - 4, cut > 1, buffer[cut - 1] & 0xC0 == 0x80 { cut -= 1 }
        if cut > 1, buffer[cut - 1] >= 0xC0 { cut -= 1 }
        let prefix = Array(buffer[..<cut])
        buffer.removeFirst(cut)
        return LineSplitter.stripANSI(String(decoding: prefix, as: UTF8.self))
    }

    private mutating func takeLine() -> String {
        defer { buffer.removeAll(keepingCapacity: true) }
        return LineSplitter.stripANSI(String(decoding: buffer, as: UTF8.self))
    }

    /// Removes CSI (`ESC [ … final`) and OSC (`ESC ] … BEL` / `ESC ] … ESC \\`) escape sequences.
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
                // OSC ends with BEL or with ST (`ESC \\`).
                while let next = scalars.next(), next != "\u{07}" {
                    if next == "\u{1B}" { _ = scalars.next(); break }
                }
            }
            // Other two-byte escapes (ESC c, ESC 7, …) are dropped along with the introducer.
        }
        return String(result)
    }
}
