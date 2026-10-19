import Foundation
import Testing
@testable import ContainerKit
import ContainerKitMock

@Suite("Lenient decoding")
struct LenientDecodingTests {
    static func volume(_ name: String, date: String = "2026-10-17T18:41:50Z") -> String {
        #"{"id":"\#(name)","configuration":{"name":"\#(name)","creationDate":"\#(date)","sizeInBytes":1024,"source":"/x"}}"#
    }

    @Test func lossyArraySkipsOneCorruptElement() throws {
        let json = "[\(Self.volume("a")), {\"id\": 42}, \(Self.volume("c"))]"
        let list = try CLIJSON.decode(LossyArray<Volume>.self, from: Data(json.utf8))
        #expect(list.elements.map(\.name) == ["a", "c"])
        #expect(list.droppedCount == 1)
        #expect(list.errors.count == 1)
    }

    @Test func listVolumesSurvivesACorruptElement() async throws {
        let json = "[\(Self.volume("a")), \"garbage\", \(Self.volume("c"))]"
        let runner = RecordingRunner { _ in ProcessResult(stdout: json) }
        let volumes = try await CLIBackend.recording(runner).listVolumes()
        #expect(volumes.map(\.name) == ["a", "c"])
    }

    @Test func listContainersSurvivesACorruptElement() async throws {
        let good = try JSONSerialization.jsonObject(with: Fixtures.data("containers.json")) as? [Any] ?? []
        try #require(good.count >= 2)
        let mixed: [Any] = [good[0], ["configuration": "broken"], good[1]]
        let data = try JSONSerialization.data(withJSONObject: mixed)
        let runner = RecordingRunner { _ in ProcessResult(stdout: data) }
        #expect(try await CLIBackend.recording(runner).listContainers(includeStopped: true).count == 2)
    }

    @Test func volumeMissingSecondaryFieldsAndBadDateStillDecodes() throws {
        let json = #"[{"id":"v","configuration":{"name":"v","creationDate":"yesterday"}}]"#
        let volume = try #require(try CLIJSON.decode([Volume].self, from: Data(json.utf8)).first)
        #expect(volume.configuration.labels.isEmpty)
        #expect(volume.configuration.options.isEmpty)
        #expect(volume.configuration.driver == "local")
        #expect(volume.configuration.sizeInBytes == 0)
        #expect(volume.configuration.creationDate == Date(timeIntervalSince1970: 0))
    }

    @Test func networkWithoutLabelsOptionsOrModeDecodes() throws {
        let json = #"[{"id":"n","configuration":{"name":"n"},"status":"weird"}]"#
        let network = try #require(try CLIJSON.decode([Network].self, from: Data(json.utf8)).first)
        #expect(network.configuration.mode == "nat")
        #expect(network.configuration.labels.isEmpty)
        #expect(network.status == nil)
    }

    @Test func statsAndDiskUsageDefaultMissingCounters() throws {
        let stats = try CLIJSON.decode([ContainerStats].self, from: Data(#"[{"id":"s","cpuUsageUsec":5}]"#.utf8))
        #expect(stats.first?.cpuUsageUsec == 5)
        #expect(stats.first?.memoryLimitBytes == 0)
        let df = try CLIJSON.decode(DiskUsage.self, from: Data(#"{"images":{"total":3}}"#.utf8))
        #expect(df.images.total == 3)
        #expect(df.containers == .empty)
    }

    @Test func imageWithBadDateAndCorruptVariantDecodes() throws {
        let json = #"""
        {"id":"abc","configuration":{"name":"x:1","creationDate":"nope","descriptor":{"digest":"sha256:abc","mediaType":"m","size":1}},
         "variants":[{"platform":{"architecture":"arm64","os":"linux"},"digest":"d","size":2},{"bad":true}]}
        """#
        let image = try CLIJSON.decode(Image.self, from: Data(json.utf8))
        #expect(image.variants.count == 1)
        #expect(image.configuration.creationDate == Date(timeIntervalSince1970: 0))
    }

    @Test func fixturesStillDecodeCompletely() throws {
        #expect(try Fixtures.volumes().count == (try CLIJSON.decode(LossyArray<Volume>.self, from: Fixtures.data("volumes.json"))).elements.count)
        let images = try CLIJSON.decode(LossyArray<Image>.self, from: Fixtures.data("images.json"))
        #expect(images.droppedCount == 0)
        #expect(images.elements.count == (try Fixtures.images()).count)
    }
}
