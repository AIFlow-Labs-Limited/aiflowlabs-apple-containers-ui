import Foundation

/// Parsers for CLI outputs whose shape is not pinned down by a fixture: tables, empty JSON arrays in 1.5.0,
/// and version banners. Each accepts JSON first and falls back to the table form.
public enum CLIOutputParsing {
    /// `container system dns ls [--format json]`. Accepts `["test"]`, `[{"domain": "test"}]`,
    /// `[{"name": …}]` / `[{"id": …}]`, or the `DOMAIN` table.
    public static func dnsDomains(_ data: Data) -> [DNSDomain] {
        if let values = jsonArray(data) {
            return values.compactMap { value in
                if let name = value.stringValue { return DNSDomain(domain: name) }
                guard let object = value.objectValue,
                    let name = firstString(object, ["domain", "name", "id"])
                else { return nil }
                return DNSDomain(
                    domain: name, localhostAddress: firstString(object, ["localhostAddress", "localhost"]))
            }
        }
        let table = TableParser.parse(String(decoding: data, as: UTF8.self))
        return table.records.compactMap { record in
            guard let name = record["DOMAIN"] ?? record[table.headers.first ?? ""], !name.isEmpty else { return nil }
            let localhost = (record["LOCALHOST"]).flatMap { $0.isEmpty ? nil : $0 }
            return DNSDomain(domain: name, localhostAddress: localhost)
        }
    }

    /// `container registry ls [--format json]`. JSON elements follow Apple's `RegistryResource`
    /// (`id`, `name`, `username`, …); `server` is the first of `name`/`hostname`/`server`/`id`. The table
    /// form is `HOSTNAME USERNAME MODIFIED CREATED`.
    public static func registries(_ data: Data) -> [RegistryLogin] {
        if let values = jsonArray(data) {
            return values.compactMap { value in
                guard let object = value.objectValue,
                    let server = firstString(object, ["name", "hostname", "server", "id"])
                else { return nil }
                return RegistryLogin(
                    server: server, username: firstString(object, ["username", "user"]),
                    scheme: firstString(object, ["scheme"]))
            }
        }
        let table = TableParser.parse(String(decoding: data, as: UTF8.self))
        return table.records.compactMap { record in
            guard let server = record["HOSTNAME"] ?? record["SERVER"] ?? record["NAME"], !server.isEmpty else {
                return nil
            }
            let username = record["USERNAME"].flatMap { $0.isEmpty ? nil : $0 }
            return RegistryLogin(server: server, username: username)
        }
    }

    /// `container k8s ls` table (`CLUSTER NODE ROLE STATE CPUS MEMORY ADDR PORTS`) grouped into clusters,
    /// preserving the order clusters first appear in.
    ///
    /// Real CLI 1.5.0 output leaves CLUSTER blank and names each cluster's control-plane node after the
    /// cluster. So: a named CLUSTER cell wins; a blank cell on a `control-plane` row starts a new cluster
    /// named after its NODE; any other blank row (a worker) joins the current cluster, or becomes its own
    /// cluster when it comes first.
    public static func clusters(_ text: String) -> [KubernetesCluster] {
        var order: [String] = []
        var nodes: [String: [KubernetesCluster.Node]] = [:]
        var current: String?
        for record in TableParser.parse(text).records {
            let nodeName = nonEmpty(record["NODE"])
            let isControlPlane = (record["ROLE"] ?? "").localizedCaseInsensitiveContains("control-plane")
            let cluster: String
            if let named = nonEmpty(record["CLUSTER"]) {
                cluster = named
            } else if isControlPlane, let nodeName {
                cluster = nodeName
            } else if let inherited = current ?? nodeName {
                cluster = inherited
            } else {
                continue
            }
            current = cluster
            if nodes[cluster] == nil { order.append(cluster); nodes[cluster] = [] }
            let node = KubernetesCluster.Node(
                name: nodeName ?? cluster,
                role: record["ROLE"] ?? "",
                state: ContainerState(rawValue: (record["STATE"] ?? "").lowercased()) ?? .unknown,
                cpus: Int(record["CPUS"] ?? "") ?? 0,
                memoryMB: memoryMegabytes(record["MEMORY"] ?? ""),
                address: nonEmpty(record["ADDR"]),
                ports: nonEmpty(record["PORTS"]))
            nodes[cluster]?.append(node)
        }
        return order.map { KubernetesCluster(name: $0, nodes: nodes[$0] ?? []) }
    }

    /// The version number from `container --version` (`container CLI version 1.5.0 (build: …)`).
    public static func cliVersion(_ banner: String) -> String? {
        let words = banner.split(whereSeparator: \.isWhitespace)
        if let index = words.firstIndex(of: "version"), index + 1 < words.count { return String(words[index + 1]) }
        return words.first { $0.first?.isNumber == true && $0.contains(".") }.map(String.init)
    }

    /// `2048`, `2048 MB`, `2g`, `2 GiB` → megabytes. Bare numbers are taken as megabytes.
    static func memoryMegabytes(_ text: String) -> Int64 {
        let compact = text.replacingOccurrences(of: " ", with: "")
        if let plain = Int64(compact) { return plain }
        return MemorySize(parsing: compact).map { $0.bytes / 1_048_576 } ?? 0
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.isEmpty, value != "-" else { return nil }
        return value
    }

    private static func jsonArray(_ data: Data) -> [JSONValue]? {
        guard let first = data.first(where: { !($0 == 0x20 || $0 == 0x0A || $0 == 0x0D || $0 == 0x09) }),
            first == UInt8(ascii: "[")
        else { return nil }
        return try? JSONDecoder().decode([JSONValue].self, from: data)
    }

    private static func firstString(_ object: [String: JSONValue], _ keys: [String]) -> String? {
        for key in keys { if let value = object[key]?.stringValue, !value.isEmpty { return value } }
        return nil
    }
}
