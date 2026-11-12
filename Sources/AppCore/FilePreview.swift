import Foundation

/// What the Files tab shows for a file's contents. Only a bounded prefix is ever read.
public enum FilePreview: Equatable, Sendable {
    /// Text to show; `truncated` when the file is longer than what was read.
    case text(String, truncated: Bool)
    /// Not text (a NUL byte or invalid UTF-8 in the bytes read).
    case binary
    /// Zero bytes.
    case empty

    /// Bytes read for a preview. Larger files show their beginning only.
    public static let byteLimit = 256 * 1024

    /// Classifies the first bytes of a file. `truncated` says whether the file continues after `data`.
    public static func classify(_ data: Data, truncated: Bool) -> FilePreview {
        if data.isEmpty { return .empty }
        if data.prefix(8192).contains(0) { return .binary }
        // A read that stops mid-file may cut a multi-byte character: allow dropping up to 3 trailing bytes.
        for drop in 0...(truncated ? 3 : 0) where data.count > drop {
            if let text = String(data: data.dropLast(drop), encoding: .utf8) {
                return .text(text, truncated: truncated)
            }
        }
        return .binary
    }
}
