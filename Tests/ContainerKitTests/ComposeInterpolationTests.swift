import Foundation
import Testing

@testable import ContainerKit

@Suite("Compose interpolation")
struct ComposeInterpolationTests {
    private let variables = ["TAG": "2.1", "EMPTY": "", "HOST": "db"]

    @Test(arguments: [
        ("plain text", "plain text"),
        ("$TAG", "2.1"),
        ("${TAG}", "2.1"),
        ("img:${TAG}-alpine", "img:2.1-alpine"),
        ("${TAG:-9}", "2.1"),
        ("${MISSING:-9}", "9"),
        ("${EMPTY:-9}", "9"),  // `:-` treats empty as unset
        ("${EMPTY-9}", ""),  // `-` only applies when unset
        ("${MISSING-9}", "9"),
        ("${MISSING:-}", ""),
        ("${TAG:+yes}", "yes"),
        ("${EMPTY:+yes}", ""),
        ("${EMPTY+yes}", "yes"),
        ("${MISSING+yes}", ""),
        ("${MISSING:-${TAG}}", "2.1"),
        ("${MISSING:-${ALSO_MISSING:-deep}}", "deep"),
        ("${MISSING:-a}b}", "ab}"),
        ("$$TAG", "$TAG"),
        ("cost: $$5 and $5", "cost: $5 and $5"),
        ("trailing $", "trailing $"),
        ("${", "${"),
        ("${1BAD}", "${1BAD}"),
        ("${TAG", "${TAG"),
        ("postgres://u:p@${HOST}:5432/x", "postgres://u:p@db:5432/x"),
    ])
    func substitution(input: String, expected: String) throws {
        #expect(try ComposeInterpolation.interpolate(input, variables: variables) == expected)
    }

    @Test func unsetVariablesAreReportedAndBecomeEmpty() throws {
        var unset = Set<String>()
        let text = try ComposeInterpolation.interpolate("a${NOPE}b$ALSO_NOPE", variables: variables, unset: &unset)
        #expect(text == "ab")
        #expect(unset == ["NOPE", "ALSO_NOPE"])
    }

    @Test func requiredVariables() throws {
        #expect(try ComposeInterpolation.interpolate("${TAG:?needed}", variables: variables) == "2.1")
        #expect(try ComposeInterpolation.interpolate("${EMPTY?needed}", variables: variables).isEmpty)
        #expect(throws: ComposeError.requiredVariable(name: "EMPTY", message: "must not be empty")) {
            try ComposeInterpolation.interpolate("${EMPTY:?must not be empty}", variables: variables)
        }
        #expect(throws: ComposeError.requiredVariable(name: "MISSING", message: "")) {
            try ComposeInterpolation.interpolate("${MISSING?}", variables: variables)
        }
    }

    @Test func referencesListNamesDefaultsAndRequired() {
        let refs = ComposeInterpolation.references(in: "${A:-1} $B ${C:?need} ${A} ${D:-${E}} $$F")
        #expect(refs.map(\.name) == ["A", "B", "C", "D", "E"])
        #expect(refs[0].defaultValue == "1")
        #expect(refs[1].defaultValue == nil)
        #expect(refs[2].isRequired)
        #expect(refs[3].defaultValue == "${E}")
    }

    @Test func fixtureWithDotEnvValues() throws {
        // The values of `interpolation/dot.env`.
        let file = try ComposeFixtures.parse(
            "interpolation/compose.yaml", variables: ["TAG": "2.1", "HOST_PORT": "9090", "EMPTY": ""])
        #expect(file.name == "demo")
        let app = try #require(file.service(named: "app"))
        #expect(app.image == "example/app:2.1")
        #expect(app.ports == [ComposePort(published: 9090, target: 80)])
        #expect(
            app.environment == [
                "GREETING=hello", "EMPTY_OK=fallback", "EMPTY_KEPT=", "PRICE=$5", "NESTED=2.1-nested", "PLAIN=2.1",
                "UNSET_ONE=", "ONLY_IF_SET=tagged",
            ])
        #expect(app.mounts == [ComposeMount(source: .bind("./data"), target: "/data")])
        #expect(file.unsetVariables == ["NOT_SET_ANYWHERE"])
    }

    @Test func overridesWinAndReferencesAreDiscoverable() throws {
        let file = try ComposeFixtures.parse(
            "interpolation/compose.yaml",
            variables: ["TAG": "3", "PROJECT": "prod", "DATA_DIR": "/srv/data", "NOT_SET_ANYWHERE": "x"])
        #expect(file.name == "prod")
        #expect(file.services[0].mounts == [ComposeMount(source: .bind("/srv/data"), target: "/data")])
        #expect(file.unsetVariables.isEmpty)

        let refs = try ComposeParser.variableReferences(in: ComposeFixtures.text("interpolation/compose.yaml"))
        #expect(
            refs.map(\.name) == [
                "PROJECT", "TAG", "HOST_PORT", "GREETING", "EMPTY", "MISSING", "NOT_SET_ANYWHERE", "DATA_DIR",
            ])
        #expect(refs.first { $0.name == "HOST_PORT" }?.defaultValue == "8080")
    }

    @Test func requiredVariableFailsTheParseButReferencesStillWork() throws {
        let yaml = "services:\n  a:\n    image: \"app:${VERSION:?set VERSION in .env}\"\n"
        #expect(throws: ComposeError.requiredVariable(name: "VERSION", message: "set VERSION in .env")) {
            try ComposeParser.parse(yaml)
        }
        #expect(try ComposeParser.variableReferences(in: yaml).first?.isRequired == true)
        #expect(try ComposeParser.parse(yaml, variables: ["VERSION": "1"]).services[0].image == "app:1")
    }
}
