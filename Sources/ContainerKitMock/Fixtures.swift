import ContainerKit
import Foundation

/// Recorded `container … --format json` output from CLI 1.5.0 on macOS 26.6.2.
/// Re-record with `scripts/record-fixtures.sh` when the CLI changes.
public enum Fixtures {
    public static let cliVersion = "1.5.0"

    public static func url(_ name: String) -> URL {
        guard let url = Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "cli-1.5.0") else {
            preconditionFailure("Missing fixture \(name)")
        }
        return url
    }

    public static func data(_ name: String) -> Data {
        guard let d = try? Data(contentsOf: url(name)) else { preconditionFailure("Unreadable fixture \(name)") }
        return d
    }

    public static func text(_ name: String) -> String { String(decoding: data(name), as: UTF8.self) }

    public static func decode<T: Decodable>(_ type: T.Type, _ name: String) throws -> T {
        try CLIJSON.decode(type, from: data(name))
    }

    public static func containers() throws -> [Container] { try decode([Container].self, "containers.json") }
    public static func images() throws -> [Image] { try decode([Image].self, "images.json") }
    public static func volumes() throws -> [Volume] { try decode([Volume].self, "volumes.json") }
    public static func networks() throws -> [Network] { try decode([Network].self, "networks.json") }
    public static func stats() throws -> [ContainerStats] { try decode([ContainerStats].self, "stats.json") }
    public static func machines() throws -> [Machine] { try decode([Machine].self, "machines.json") }
    public static func builder() throws -> [Container] { try decode([Container].self, "builder.json") }
    public static func diskUsage() throws -> DiskUsage { try decode(DiskUsage.self, "system-df.json") }
    public static func systemStatus() throws -> SystemStatus { try decode(SystemStatus.self, "system-status.json") }
    public static func systemProperties() throws -> SystemProperties {
        try decode(SystemProperties.self, "system-properties.json")
    }
}
