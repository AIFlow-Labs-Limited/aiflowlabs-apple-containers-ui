import Foundation

/// The one-exec directory listing behind the Files tab: the POSIX `sh` script that runs inside the container
/// and the parser for what it prints.
///
/// ## Why it is safe for any file name
/// The script never interpolates a path or name into shell source: the directory, the entry limit and a
/// random per-call *nonce* arrive as positional parameters (`$1`…`$3`), and names only ever appear as quoted
/// `"$f"` / `"$@"` words after `--`. Every record the script prints starts with the nonce, which a file name
/// cannot guess, so a name containing newlines (or text that looks like a record) can only produce lines
/// *without* the nonce; the parser appends those to the record before them. Fields before the name are
/// numeric or `/`-separated and the name is always last, so spaces, quotes, tabs and unicode need no escaping.
///
/// ## Methods, best first (all inside the same exec)
/// 1. `stat -c` (GNU coreutils, BusyBox, toybox): exact type, size, mode, owner and mtime; symbolic link
///    targets come from `readlink`.
/// 2. `ls -lAn --full-time`, then `ls -lAn`, then `ls -la`: parsed leniently; a name containing a newline or
///    ` -> ` cannot be represented exactly by `ls` and is the documented limit of the fallback.
/// 3. Neither: the listing is reported as unavailable (`noListingTool`), like an image without `sh` (`noShell`).
public enum FileListing {
    /// Exit status the script uses when it cannot enter the directory.
    public static let cannotEnterExitCode: Int32 = 66

    /// The script. `$1` nonce, `$2` directory, `$3` entry limit.
    public static let script = """
        LC_ALL=C; export LC_ALL
        N=$1; L=$3
        cd -- "$2" || exit 66
        echo "$N S"
        if stat -c %f -- . >/dev/null 2>&1; then
          echo "$N M stat"
          c=0; set --
          for f in * .[!.]* ..?*; do
            if [ -e "$f" ] || [ -L "$f" ]; then
              c=$((c+1))
              if [ "$c" -gt "$L" ]; then echo "$N M truncated"; break; fi
              set -- "$@" "$f"
            fi
          done
          if [ $# -gt 0 ]; then
            stat -c "$N E %f/%s/%u/%g/%Y/%U/%G/%n" -- "$@"
            for f in "$@"; do
              if [ -L "$f" ]; then
                k=L; if [ -d "$f" ]; then k=K; fi
                printf '%s %s %s\\n' "$N" "$k" "$f"
                printf '%s T ' "$N"; readlink -- "$f" || echo
              fi
            done
          fi
        else
          { echo "$N M ls-full"; ls -lAn --full-time 2>/dev/null; } ||
          { echo "$N M ls-long"; ls -lAn 2>/dev/null; } ||
          { echo "$N M ls-basic"; ls -la 2>/dev/null; } ||
          echo "$N M none"
        fi
        echo "$N Z"
        """

    /// 16 random hex digits; a fresh one per listing.
    public static func makeNonce() -> String {
        String(UInt64.random(in: 0...UInt64.max), radix: 16).leftPadded(to: 16)
    }

    /// The command to exec inside the container: `sh -c SCRIPT sh NONCE DIRECTORY LIMIT`.
    public static func command(nonce: String, path: String, limit: Int) -> [String] {
        ["sh", "-c", script, "sh", nonce, path, String(limit)]
    }

    /// What one run of the script means.
    public enum Outcome: Hashable, Sendable {
        /// The directory was listed, or the image cannot list files at all (`unavailable` set).
        case listing(ContainerDirectoryListing)
        /// The directory could not be read (missing, not a directory, permission denied, container stopped…).
        case failure(message: String)
    }

    /// Interprets the exit status and output of `command(nonce:path:limit:)`.
    public static func interpret(
        exitCode: Int32, stdout: Data, stderr: String, nonce: String, path: String, limit: Int, now: Date = .now
    ) -> Outcome {
        if let listing = parse(stdout, nonce: nonce, path: path, limit: limit, now: now),
            listing.method != nil || listing.unavailable != nil
        {
            return .listing(listing)
        }
        let message = CLIErrorMapper.cleanMessage(stderr)
        if exitCode == cannotEnterExitCode {
            return .failure(message: message.isEmpty ? "“\(path)” cannot be opened." : message)
        }
        if indicatesMissingShell(exitCode: exitCode, stderr: stderr) {
            return .listing(ContainerDirectoryListing(path: path, method: nil, unavailable: .noShell))
        }
        return .failure(message: message.isEmpty ? "Listing “\(path)” failed with exit code \(exitCode)." : message)
    }

    /// `true` when the exec failed because the image has no `sh` (exit 126/127, or the runtime's
    /// "executable not found" wording), as opposed to the container being stopped or missing.
    static func indicatesMissingShell(exitCode: Int32, stderr: String) -> Bool {
        let lower = stderr.lowercased()
        if lower.contains("is not running") || lower.contains("container not found") { return false }
        if exitCode == 126 || exitCode == 127 { return true }
        let patterns = [
            "failed to find target executable", "executable file not found", "executable not found",
            "not found in $path", "no such file or directory", "sh: not found", "\"sh\" not found",
        ]
        return patterns.contains { lower.contains($0) }
    }

    // MARK: - Parsing

    private enum Pending { case none, entryName(Int), linkName(Int), linkTarget(Int) }

    /// Parses the script's stdout. Returns `nil` when the script never started (no start record).
    public static func parse(
        _ stdout: Data, nonce: String, path: String, limit: Int, now: Date = .now
    ) -> ContainerDirectoryListing? {
        let prefix = Array((nonce + " ").utf8)
        var started = false, truncated = false
        var method: String?
        var entries: [ContainerFileEntry] = []
        var links: [(name: String, isDirectory: Bool, target: String)] = []
        var pending = Pending.none

        // Split on the LF byte, not on Characters: a name may end in CR, and "\r\n" is one Character.
        var lines = stdout.split(separator: 0x0A, omittingEmptySubsequences: false)
        if lines.last?.isEmpty == true { lines.removeLast() }
        for raw in lines {
            guard raw.starts(with: prefix) else {
                let text = String(decoding: raw, as: UTF8.self)
                if let method, method.hasPrefix("ls-") {
                    if let entry = parseLsLine(text, now: now) { entries.append(entry) }
                    continue
                }
                switch pending {  // a newline inside a name or link target
                case .entryName(let i): entries[i].name += "\n" + text
                case .linkName(let i): links[i].name += "\n" + text
                case .linkTarget(let i): links[i].target += "\n" + text
                case .none: break
                }
                continue
            }
            let body = String(decoding: raw.dropFirst(prefix.count), as: UTF8.self)
            let payload = String(body.unicodeScalars.dropFirst(2))
            pending = .none
            switch body.unicodeScalars.first {
            case "S": started = true
            case "M":
                if payload == "truncated" {
                    truncated = true
                } else {
                    method = payload
                    entries.removeAll()  // a failed `ls` attempt may have printed a partial listing
                }
            case "E":
                if let entry = parseStatRecord(payload) {
                    entries.append(entry)
                    pending = .entryName(entries.count - 1)
                }
            case "L", "K":
                links.append((payload, body.unicodeScalars.first == "K", ""))
                pending = .linkName(links.count - 1)
            case "T":
                if !links.isEmpty {
                    links[links.count - 1].target = payload
                    pending = .linkTarget(links.count - 1)
                }
            default: break
            }
        }
        guard started else { return nil }

        let byName = Dictionary(links.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        for index in entries.indices where entries[index].kind == .symlink {
            guard let link = byName[entries[index].name] else { continue }
            entries[index].linkTarget = link.target.isEmpty ? entries[index].linkTarget : link.target
            entries[index].linkPointsToDirectory = link.isDirectory
        }
        if entries.count > limit {
            entries.removeLast(entries.count - limit)
            truncated = true
        }
        let resolved: ContainerDirectoryListing.Method?
        switch method {
        case "stat": resolved = .stat
        case "ls-full": resolved = .lsFullTime
        case "ls-long": resolved = .lsLong
        case "ls-basic": resolved = .lsBasic
        default: resolved = nil
        }
        return ContainerDirectoryListing(
            path: path, entries: entries, isTruncated: truncated, method: resolved,
            unavailable: method == "none" ? .noListingTool : nil)
    }

    /// `%f/%s/%u/%g/%Y/%U/%G/%n`: hex mode, size, uid, gid, mtime (epoch seconds), user, group, name.
    static func parseStatRecord(_ payload: String) -> ContainerFileEntry? {
        let fields = payload.split(separator: "/", maxSplits: 7, omittingEmptySubsequences: false)
        guard fields.count == 8, let mode = UInt32(fields[0], radix: 16), let size = Int64(fields[1]),
            !fields[7].isEmpty
        else { return nil }
        func named(_ field: Substring) -> String? { field.isEmpty || field == "UNKNOWN" ? nil : String(field) }
        return ContainerFileEntry(
            name: String(fields[7]), kind: kind(ofMode: mode), size: size, permissions: UInt16(mode & 0o7777),
            uid: Int(fields[2]), gid: Int(fields[3]), owner: named(fields[5]), group: named(fields[6]),
            modified: Double(fields[4]).map { Date(timeIntervalSince1970: $0) })
    }

    /// File type from the `S_IFMT` bits.
    static func kind(ofMode mode: UInt32) -> ContainerFileEntry.Kind {
        switch mode & 0xF000 {
        case 0x8000: return .file
        case 0x4000: return .directory
        case 0xA000: return .symlink
        case 0x2000: return .characterDevice
        case 0x6000: return .blockDevice
        case 0x1000: return .fifo
        case 0xC000: return .socket
        default: return .unknown
        }
    }
}

extension String {
    /// Left-pads with `0` to `width` characters.
    fileprivate func leftPadded(to width: Int) -> String {
        count >= width ? self : String(repeating: "0", count: width - count) + self
    }
}
