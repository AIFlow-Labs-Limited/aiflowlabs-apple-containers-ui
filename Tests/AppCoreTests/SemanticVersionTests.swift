import Foundation
import Testing

@testable import AppCore

@Suite struct SemanticVersionTests {
    private func v(_ text: String) -> SemanticVersion { SemanticVersion(text)! }

    @Test func comparesNumericallyNotLexically() {
        #expect(v("1.10.0") > v("1.9.0"))
        #expect(v("1.9.10") > v("1.9.9"))
        #expect(v("2.0.0") > v("1.99.99"))
        #expect(v("0.10.0") > v("0.9.9"))
        #expect(v("1.5.0") == v("1.5.0"))
        #expect(!(v("1.5.0") < v("1.5.0")))
    }

    @Test func ignoresLeadingVAndFillsMissingParts() {
        #expect(v("v1.7.1") == v("1.7.1"))
        #expect(v("V0.2.0") == SemanticVersion(0, 2, 0))
        #expect(v("1.7") == SemanticVersion(1, 7, 0))
        #expect(v("2") == SemanticVersion(2, 0, 0))
        #expect(v(" 1.7.1\n") == SemanticVersion(1, 7, 1))
        #expect(v("1.7.1+build.5") == SemanticVersion(1, 7, 1))
        #expect(v("v1.7.1").description == "1.7.1")
    }

    @Test func rejectsWhatIsNotAVersion() {
        for text in ["", "v", "latest", "dev", "1.2.3.4", "1..2", "1.x.0", "-1.0.0", "1.0.0-", "+1.2.3", "１.２.３"] {
            #expect(SemanticVersion(text) == nil, "\(text) should not parse")
        }
    }

    @Test func prereleasesSortBelowTheirRelease() {
        #expect(v("1.8.0-beta.1").isPrerelease)
        #expect(!v("1.8.0").isPrerelease)
        #expect(v("1.8.0-beta.1") < v("1.8.0"))
        #expect(v("1.8.0-beta.1") > v("1.7.1"))
        #expect(v("1.8.0-alpha") < v("1.8.0-beta"))
        #expect(v("1.8.0-beta.2") < v("1.8.0-beta.10"))
        #expect(v("1.8.0-beta") < v("1.8.0-beta.1"))
        #expect(v("1.8.0-1") < v("1.8.0-rc"))
        #expect(v("v0.2.0-beta.1").description == "0.2.0-beta.1")
    }

    @Test func releaseIsNewerOnlyForStableHigherVersions() {
        let page = URL(string: "https://github.com/apple/container/releases/latest")!
        let stable = ReleaseInfo(version: "1.10.0", pageURL: page)
        #expect(stable.isNewer(than: "1.9.0"))
        #expect(stable.isNewer(than: "v1.9.0"))
        #expect(!stable.isNewer(than: "1.10.0"))
        #expect(!stable.isNewer(than: "1.11.0"))
        #expect(!stable.isNewer(than: nil))
        #expect(!stable.isNewer(than: "dev"))
        #expect(!ReleaseInfo(version: "2.0.0-rc.1", pageURL: page).isNewer(than: "1.0.0"))
    }
}

@Suite struct RuntimeSupportTests {
    @Test func rangeIsDefinedOnce() {
        #expect(RuntimeSupport.minimum == SemanticVersion(1, 5, 0))
        #expect(RuntimeSupport.testedUpTo == SemanticVersion(1, 7, 1))
        #expect(RuntimeSupport.rangeDescription == "1.5.0 to 1.7.1")
    }

    @Test func classifiesInstalledVersions() {
        #expect(RuntimeSupport.compatibility(of: "1.5.0") == .supported)
        #expect(RuntimeSupport.compatibility(of: "1.6.3") == .supported)
        #expect(RuntimeSupport.compatibility(of: "1.7.1") == .supported)
        #expect(RuntimeSupport.compatibility(of: "1.4.9") == .tooOld(installed: SemanticVersion(1, 4, 9)))
        #expect(RuntimeSupport.compatibility(of: "0.9.0") == .tooOld(installed: SemanticVersion(0, 9, 0)))
        #expect(RuntimeSupport.compatibility(of: "1.7.2") == .newerThanTested(installed: SemanticVersion(1, 7, 2)))
        #expect(RuntimeSupport.compatibility(of: "1.10.0") == .newerThanTested(installed: SemanticVersion(1, 10, 0)))
        #expect(RuntimeSupport.compatibility(of: "2.0.0") == .newerThanTested(installed: SemanticVersion(2, 0, 0)))
        #expect(RuntimeSupport.compatibility(of: nil) == .unknown)
        #expect(RuntimeSupport.compatibility(of: "") == .unknown)
        #expect(RuntimeSupport.compatibility(of: "unknown") == .unknown)
    }

    @Test func noticesOnlyOutsideTheRange() {
        #expect(RuntimeSupport.notice(for: .supported) == nil)
        #expect(RuntimeSupport.notice(for: .unknown) == nil)
        let old = RuntimeSupport.notice(for: RuntimeSupport.compatibility(of: "1.4.0"))
        #expect(old?.contains("1.4.0") == true && old?.contains("older than 1.5.0") == true)
        let new = RuntimeSupport.notice(for: RuntimeSupport.compatibility(of: "1.8.0"))
        #expect(new?.contains("newer than 1.7.1") == true && new?.contains("should work") == true)
    }
}
