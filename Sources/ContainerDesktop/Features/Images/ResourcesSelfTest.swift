#if DEBUG
import Foundation
import ContainerKit
import AppCore

/// DEBUG-only end-to-end check against the real engine, driven through the same store calls the UI buttons make.
/// Creates and removes only `cd-ui-test*` resources. Prints `SELFTEST …` lines to stdout.
@MainActor
enum ResourcesSelfTest {
    static func run(model: AppModel) async {
        func log(_ s: String) { print("SELFTEST \(s)"); fflush(stdout) }
        model.navigation.open(.images)
        let pull = model.images.pull("alpine:3.22")
        await pull.wait()
        log("pull alpine:3.22 -> \(pull.state.label) (\(pull.lines.count) lines)")
        guard let source = model.images.items.first(where: { ImageReferenceName.same($0.reference, "alpine:3.22") }) else {
            log("FAIL alpine:3.22 not listed"); return
        }
        await model.images.tag(source.reference, as: "cd-ui-test:1")
        let tagged = model.images.items.first { ImageReferenceName.same($0.reference, "cd-ui-test:1") }
        log("tag -> \(tagged?.reference ?? "MISSING") error=\(model.images.lastError?.errorDescription ?? "none")")
        if let tagged {
            await model.images.delete([tagged.reference])
            log("delete tag -> gone=\(!model.images.items.contains { $0.reference == tagged.reference })")
        }
        model.navigation.open(.volumes)
        let vok = await model.volumes.create(name: "cd-ui-test-vol", size: MemorySize(parsing: "1g"), journal: "ordered", labels: ["cd": "test"])
        log("volume create -> \(vok) listed=\(model.volumes.items.contains { $0.name == "cd-ui-test-vol" })")
        await model.volumes.delete(["cd-ui-test-vol"])
        log("volume delete -> gone=\(!model.volumes.items.contains { $0.name == "cd-ui-test-vol" })")
        model.navigation.open(.networks)
        let nok = await model.networks.create(name: "cd-ui-test-net", labels: ["cd": "test"])
        let net = model.networks.items.first { $0.name == "cd-ui-test-net" }
        log("network create -> \(nok) subnet=\(net?.status?.ipv4Subnet ?? "?")")
        await model.networks.delete(["cd-ui-test-net"])
        log("network delete -> gone=\(!model.networks.items.contains { $0.name == "cd-ui-test-net" })")
        model.navigation.open(.images)
        log("DONE")
    }
}
#endif
