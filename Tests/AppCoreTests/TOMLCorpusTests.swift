import Foundation
import Testing

@testable import AppCore

@Suite struct TOMLCorpusTests {
    /// Realistic configs that must validate cleanly and survive a no-op edit byte-for-byte.
    static let corpus: [String] = [
        "[dns]\ndomain = \"test\"\n",
        "[dns]\r\ndomain = \"test\"\r\n\r\n[container]\r\ncpus = 4\r\n",
        "# top comment\ncontainer.cpus = 2\ncontainer.memory = \"4g\"\n",
        "[build]\nrosetta = true   # needed for amd64\nimage = 'ghcr.io/x/builder:1'\n",
        "[kernel]\nargs = [\n  \"console=hvc0\", # serial\n  \"quiet\",\n]\nurl = \"https://example.com/k\"\n",
        "motd = '''\nline one\nline \"two\"\n'''\n[dns]\ndomain = \"a#b\"\n",
        "notes = \"\"\"\nmulti\n\"\"\"\n\"quoted key\" = 1\n'lit' = 2\n",
        "[[registry]]\nhost = \"a\"\n[[registry]]\nhost = \"b\"\n",
        "[a.b]\nc = 1\n[a.\"d.e\"]\nf = \"esc \\\" # not a comment\"\n",
    ]

    @Test(arguments: corpus.indices)
    func validatesAndRoundTrips(_ index: Int) {
        let text = Self.corpus[index]
        #expect(TOMLValidator.validate(text) == [], "\(text.debugDescription)")
        #expect(TOMLDocument(text).render() == text)
        // Setting a key to its current value (or removing an absent key) leaves the file unchanged.
        #expect(TOMLEditor.setting("nope", to: nil, section: "dns", in: text) == text)
    }

    @Test func crlfIsNotBroken() {
        let text = "[dns]\r\ndomain = \"test\"\r\n"
        #expect(TOMLEditor.stringValue("domain", section: "dns", in: text) == "test")
        let edited = TOMLEditor.setting("domain", to: "\"dev\"", section: "dns", in: text)
        #expect(edited == "[dns]\r\ndomain = \"dev\"\r\n")
        let added = TOMLEditor.setting("cpus", to: "4", section: "container", in: text)
        #expect(added == "[dns]\r\ndomain = \"test\"\r\n\r\n[container]\r\ncpus = 4\r\n")
        #expect(TOMLValidator.validate(added).isEmpty)
    }

    @Test func dottedKeysAreRecognised() {
        let text = "container.cpus = 2\n"
        #expect(TOMLEditor.value("cpus", section: "container", in: text) == "2")
        #expect(TOMLEditor.setting("cpus", to: "6", section: "container", in: text) == "container.cpus = 6\n")
        let added = TOMLEditor.setting("memory", to: "\"8g\"", section: "container", in: text)
        #expect(added == "container.cpus = 2\ncontainer.memory = \"8g\"\n")  // no `[container]` redefinition
        #expect(TOMLValidator.validate(added).isEmpty)
        #expect(
            TOMLValidator.validate("container.cpus = 2\n[container]\nmemory = 1").first?.message
                == "Duplicate section [container]")
        #expect(TOMLValidator.validate("a.b = 1\na.b = 2").first?.message == "Duplicate key “a.b”")
    }

    @Test func inlineCommentAndIndentationSurviveReplace() {
        let text = "[container]\n  cpus = 4  # four cores\n"
        #expect(
            TOMLEditor.setting("cpus", to: "8", section: "container", in: text)
                == "[container]\n  cpus = 8  # four cores\n")
    }

    @Test func multiLineArrayRemovalLeavesNoOrphans() {
        let text = "[kernel]\nargs = [\n  \"a\",\n  \"b\",\n]\nurl = \"x\"\n"
        let removed = TOMLEditor.setting("args", to: nil, section: "kernel", in: text)
        #expect(removed == "[kernel]\nurl = \"x\"\n")
        #expect(TOMLValidator.validate(removed).isEmpty)
        let replaced = TOMLEditor.setting("args", to: "[\"c\"]", section: "kernel", in: text)
        #expect(replaced == "[kernel]\nargs = [\"c\"]\nurl = \"x\"\n")
    }

    @Test func validatorRulesForKeysAndStrings() {
        #expect(TOMLValidator.validate("bad key = 1").first?.message == "Invalid key “bad key”")
        #expect(TOMLValidator.validate("[a b]").first?.message == "Invalid section name “a b”")
        #expect(TOMLValidator.validate("x = '''\nopen").first?.message == "Unterminated multi-line string")
        #expect(TOMLValidator.validate("x = '''one line'''").isEmpty)
        #expect(TOMLValidator.validate("[dns]\ndomain = 1\n[dns]").first?.message == "Duplicate section [dns]")
        #expect(TOMLValidator.validate("x = \"a\\\"b\"").isEmpty)
    }

    @Test func insertGoesIntoExistingSectionBeforeTheNext() {
        let text = "[container]\ncpus = 4\n\n[dns]\ndomain = \"t\"\n"
        let edited = TOMLEditor.setting("memory", to: "\"2g\"", section: "container", in: text)
        #expect(edited == "[container]\ncpus = 4\nmemory = \"2g\"\n\n[dns]\ndomain = \"t\"\n")
    }
}
