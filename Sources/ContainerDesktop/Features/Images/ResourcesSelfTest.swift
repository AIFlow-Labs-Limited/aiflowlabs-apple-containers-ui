#if DEBUG
import Foundation
import ContainerKit
import AppCore

/// DEBUG-only end-to-end check against the real engine, driven through the same store calls the UI buttons make.
/// Uses run-unique `cd-ui-test-<id>` names and deletes only resources this run created (a name that already exists
/// is never touched). Prints `SELFTEST …` lines to stdout. The pulled `alpine:3.22` is left in place.
@MainActor
enum ResourcesSelfTest {
    static func run(model: AppModel) async {
        func log(_ s: String) { print("SELFTEST \(s)"); fflush(stdout) }
        let runID = String(UUID().uuidString.prefix(8)).lowercased()
        let tag = "cd-ui-test:\(runID)", volume = "cd-ui-test-vol-\(runID)", network = "cd-ui-test-net-\(runID)"
        let backend = model.backend

        model.navigation.open(.images)
        let pull = model.images.pull("alpine:3.22")
        await pull.wait()
        log("pull alpine:3.22 -> \(pull.state.label) (\(pull.lines.count) lines)")
        guard let source = model.images.items.first(where: { ImageReferenceName.same($0.reference, "alpine:3.22") }) else {
            log("FAIL alpine:3.22 not listed"); return
        }
        if model.images.items.contains(where: { ImageReferenceName.same($0.reference, tag) }) {
            log("SKIP tag: \(tag) already exists, not touching it")
        } else {
            let ok = await model.images.perform { try await backend.tagImage(source.reference, newReference: tag) }
            let tagged = model.images.items.first { ImageReferenceName.same($0.reference, tag) }
            log("tag -> ok=\(ok) \(tagged?.reference ?? "MISSING")")
            if ok, let tagged {
                await model.images.delete([tagged.reference])
                log("delete tag -> gone=\(!model.images.items.contains { $0.reference == tagged.reference })")
            }
        }

        model.navigation.open(.volumes)
        if model.volumes.items.contains(where: { $0.name == volume }) {
            log("SKIP volume: \(volume) already exists, not touching it")
        } else {
            let created = await model.volumes.create(name: volume, size: MemorySize(parsing: "1g"), journal: "ordered", labels: ["cd": "test"])
            log("volume create -> \(created) listed=\(model.volumes.items.contains { $0.name == volume })")
            if created {
                await model.volumes.delete([volume])
                log("volume delete -> gone=\(!model.volumes.items.contains { $0.name == volume })")
            }
        }

        model.navigation.open(.networks)
        if model.networks.items.contains(where: { $0.name == network }) {
            log("SKIP network: \(network) already exists, not touching it")
        } else {
            let created = await model.networks.create(name: network, labels: ["cd": "test"])
            log("network create -> \(created) subnet=\(model.networks.items.first { $0.name == network }?.status?.ipv4Subnet ?? "?")")
            if created {
                await model.networks.delete([network])
                log("network delete -> gone=\(!model.networks.items.contains { $0.name == network })")
            }
        }
        model.navigation.open(.images)
        log("DONE")
    }
}
#endif
