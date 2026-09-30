import Foundation
import Testing
import CaffeineHelperCore
@testable import CaffeineSystemPower

/// Temporary files and an Apple-signed system tool only; nothing is installed or signed.
@Suite struct HelperExecutableFileTests {
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("CaffeineHelperFile." + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func replacingTheBundleChangesTheFileIdentity() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let bundle = root.appendingPathComponent("Caffeine.app/Contents/MacOS")
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        let helper = bundle.appendingPathComponent("CaffeineHelper")
        try Data("first".utf8).write(to: helper)
        let file = HelperExecutableFile(path: helper.path)
        let launched = try #require(file.identity())
        #expect(file.identity() == launched)

        // Moving the bundle aside takes the launched file away from the launch path.
        try FileManager.default.moveItem(at: root.appendingPathComponent("Caffeine.app"),
                                         to: root.appendingPathComponent("Previous.app"))
        #expect(file.identity() == nil)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        try Data("first".utf8).write(to: helper)
        let replaced = try #require(file.identity())
        #expect(replaced != launched)
        #expect(replaced.size == launched.size)
    }

    @Test func linksAndDirectoriesAreNotExecutables() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("target")
        try Data("fixture".utf8).write(to: target)
        let link = root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        #expect(HelperExecutableFile(path: link.path).identity() == nil)
        #expect(HelperExecutableFile(path: root.path).identity() == nil)
        #expect(HelperExecutableFile(path: root.appendingPathComponent("missing").path).identity() == nil)
    }

    @Test func onlyTheExactSigningRequirementIsAccepted() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(HelperExecutableFile(path: "/bin/ls", requirement: "anchor apple").hasValidSignature())
        // Correctly signed by someone else is still not Caffeine's helper.
        #expect(!HelperExecutableFile(path: "/bin/ls").hasValidSignature())
        #expect(!HelperExecutableFile(path: "/bin/ls", requirement: "not a requirement").hasValidSignature())
        let unsigned = root.appendingPathComponent("CaffeineHelper")
        try Data("partial copy".utf8).write(to: unsigned)
        #expect(!HelperExecutableFile(path: unsigned.path, requirement: "anchor apple").hasValidSignature())
        #expect(!HelperExecutableFile(path: root.appendingPathComponent("missing").path,
                                      requirement: "anchor apple").hasValidSignature())
    }

    @Test func currentProcessResolvesAnAbsoluteExistingFile() throws {
        let file = try #require(HelperExecutableFile.currentProcess())
        #expect(file.path.hasPrefix("/"))
        #expect(file.identity() != nil)
    }

    @Test func monitorAcceptsOnlyASettledValidReplacement() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let helper = root.appendingPathComponent("CaffeineHelper")
        try FileManager.default.copyItem(atPath: "/bin/ls", toPath: helper.path)
        var monitor = HelperReplacementMonitor(executable: HelperExecutableFile(path: helper.path, requirement: "anchor apple"))
        // Swift Testing evaluates expectations through immutable captures.
        func ready() -> Bool { monitor.replacementIsReady() }
        #expect(!ready())

        try FileManager.default.removeItem(at: helper)
        try Data("not a signed helper".utf8).write(to: helper)
        #expect(!ready())
        #expect(!ready())

        try FileManager.default.removeItem(at: helper)
        try FileManager.default.copyItem(atPath: "/bin/cat", toPath: helper.path)
        #expect(!ready())
        #expect(ready())
    }
}
