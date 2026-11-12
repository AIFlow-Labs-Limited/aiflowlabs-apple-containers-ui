import Foundation

// Lenient parser for `ls -l` long-format lines (the fallback when the image has no usable `stat`).
//
// Accepted shapes (GNU coreutils, BusyBox, toybox; numeric or named owners):
//   -rw-r--r--    1 0        0             1234 2024-01-15 10:30:00 +0000 name       (BusyBox --full-time)
//   -rw-r--r-- 1 0 0 1234 2024-01-15 10:30:00.000000000 +0000 name                   (GNU --full-time)
//   -rw-r--r-- 1 root root 1234 Jan 15 10:30 name          lrwxrwxrwx 1 0 0 7 Jan 15  2023 bin -> usr/bin
//   crw-rw-rw- 1 0 0 1, 3 Jan 15 10:30 null                                           (device: major, minor)
// Dates carry no zone unless `--full-time` printed one; they are read as UTC.

extension FileListing {
    private static let months = [
        "jan": 1, "feb": 2, "mar": 3, "apr": 4, "may": 5, "jun": 6, "jul": 7, "aug": 8, "sep": 9, "oct": 10,
        "nov": 11, "dec": 12,
    ]

    private static let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        return calendar
    }()

    /// Cursor over a line's unicode scalars (not Characters: a name may start with a combining mark).
    private struct Scanner {
        let scalars: [Unicode.Scalar]
        var position = 0

        init(_ line: String) { scalars = Array(line.unicodeScalars) }

        /// Next run of non-space scalars, skipping leading spaces.
        mutating func token() -> String? {
            while position < scalars.count, scalars[position] == " " { position += 1 }
            let start = position
            while position < scalars.count, scalars[position] != " " { position += 1 }
            guard position > start else { return nil }
            return string(start..<position)
        }

        /// The next token without consuming it.
        func peek() -> String? {
            var copy = self
            return copy.token()
        }

        /// Everything after the single space that follows the last token.
        func rest() -> String {
            position + 1 <= scalars.count ? string(min(position + 1, scalars.count)..<scalars.count) : ""
        }

        private func string(_ range: Range<Int>) -> String {
            var view = String.UnicodeScalarView()
            view.append(contentsOf: scalars[range])
            return String(view)
        }
    }

    /// Parses one long-format line. Returns `nil` for `total N`, `.`/`..` and anything that is not an entry.
    static func parseLsLine(_ line: String, now: Date = .now) -> ContainerFileEntry? {
        var scanner = Scanner(line)
        guard let modeToken = scanner.token(), let (kind, permissions) = parseModeString(modeToken),
            let links = scanner.token(), Int(links) != nil,
            let owner = scanner.token(), let group = scanner.token(), let sizeToken = scanner.token()
        else { return nil }
        var size: Int64 = 0
        if sizeToken.hasSuffix(",") {
            guard scanner.token() != nil else { return nil }  // device minor number
        } else {
            guard let parsed = Int64(sizeToken) else { return nil }
            size = parsed
        }
        guard let first = scanner.token(), let second = scanner.token() else { return nil }
        var modified: Date?
        if let day = isoDay(first) {
            var offset = 0
            if let zone = scanner.peek(), let seconds = zoneOffset(zone) {
                _ = scanner.token()
                offset = seconds
            }
            modified = date(day: day, time: second).map { $0.addingTimeInterval(-Double(offset)) }
        } else if let month = months[first.lowercased()], let day = Int(second), let third = scanner.token() {
            modified = date(month: month, day: day, timeOrYear: third, now: now)
        } else {
            return nil
        }
        var name = scanner.rest()
        var target: String?
        if kind == .symlink, let arrow = name.range(of: " -> ") {
            target = String(name[arrow.upperBound...])
            name = String(name[..<arrow.lowerBound])
        }
        guard !name.isEmpty, name != ".", name != ".." else { return nil }
        return ContainerFileEntry(
            name: name, kind: kind, size: size, permissions: permissions, uid: Int(owner), gid: Int(group),
            owner: Int(owner) == nil ? owner : nil, group: Int(group) == nil ? group : nil, modified: modified,
            linkTarget: target)
    }

    /// `drwxr-xr-x` (optionally followed by `+`, `.` or `@`) → kind and permission bits.
    static func parseModeString(_ text: String) -> (ContainerFileEntry.Kind, UInt16)? {
        let scalars = Array(text.unicodeScalars)
        guard scalars.count >= 10 else { return nil }
        let kind: ContainerFileEntry.Kind
        switch scalars[0] {
        case "-": kind = .file
        case "d": kind = .directory
        case "l": kind = .symlink
        case "c": kind = .characterDevice
        case "b": kind = .blockDevice
        case "p": kind = .fifo
        case "s": kind = .socket
        default: return nil
        }
        var bits: UInt16 = 0
        for index in 1...9 {
            let bit = UInt16(1) << UInt16(9 - index)
            let special: UInt16 = index == 3 ? 0o4000 : (index == 6 ? 0o2000 : 0o1000)
            switch (scalars[index], index % 3) {
            case ("-", _): break
            case ("r", 1), ("w", 2), ("x", 0): bits |= bit
            case ("s", 0) where index != 9, ("t", 0) where index == 9: bits |= bit | special
            case ("S", 0) where index != 9, ("T", 0) where index == 9: bits |= special
            default: return nil
            }
        }
        return (kind, bits)
    }

    /// `2024-01-15` → year, month, day.
    private static func isoDay(_ text: String) -> (Int, Int, Int)? {
        let parts = text.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].count == 4, let year = Int(parts[0]), let month = Int(parts[1]),
            let day = Int(parts[2])
        else { return nil }
        return (year, month, day)
    }

    /// `+0100` / `-0530` → seconds east of UTC.
    private static func zoneOffset(_ text: String) -> Int? {
        guard text.count == 5, let sign = text.first, sign == "+" || sign == "-", let value = Int(text.dropFirst())
        else { return nil }
        return (sign == "-" ? -1 : 1) * ((value / 100) * 3600 + (value % 100) * 60)
    }

    /// `10:30`, `10:30:00` or `10:30:00.123456789` → hour, minute, second.
    private static func clock(_ text: String) -> (Int, Int, Int)? {
        let parts = text.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2 || parts.count == 3, let hour = Int(parts[0]), let minute = Int(parts[1]) else {
            return nil
        }
        let second = parts.count == 3 ? Int(parts[2].prefix { $0 != "." }) : 0
        guard let second else { return nil }
        return (hour, minute, second)
    }

    private static func date(day: (Int, Int, Int), time: String) -> Date? {
        guard let (hour, minute, second) = clock(time) else { return nil }
        return utc.date(
            from: DateComponents(
                year: day.0, month: day.1, day: day.2, hour: hour, minute: minute, second: second))
    }

    /// `Jan 15 10:30` (within the last year: the year is inferred) or `Jan 15  2023`.
    private static func date(month: Int, day: Int, timeOrYear: String, now: Date) -> Date? {
        if let (hour, minute, _) = clock(timeOrYear) {
            let year = utc.component(.year, from: now)
            let candidate = utc.date(
                from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))
            // `ls` prints a time only for files from the last six months, so a future date is last year's.
            if let candidate, candidate > now.addingTimeInterval(86_400) {
                return utc.date(
                    from: DateComponents(year: year - 1, month: month, day: day, hour: hour, minute: minute))
            }
            return candidate
        }
        guard let year = Int(timeOrYear), year > 1900 else { return nil }
        return utc.date(from: DateComponents(year: year, month: month, day: day))
    }
}
