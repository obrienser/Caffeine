import Darwin
import Foundation
import Security
import CaffeineHelperCore
import CaffeineServiceProtocol

/// Read-only inspection of the helper executable on disk. It opens no
/// connection and changes no file, registration or power state.
public struct HelperExecutableFile: HelperExecutableInspecting {
    public let path: String
    private let requirement: String

    public init(path: String,
                requirement: String = CaffeineServiceIdentity.signingRequirement(identifier: CaffeineServiceIdentity.helperIdentifier)) {
        self.path = path
        self.requirement = requirement
    }

    /// launchd passes a bundle-relative argv[0]; ask the kernel for the absolute path.
    public static func currentProcess() -> HelperExecutableFile? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(getpid(), &buffer, UInt32(buffer.count)) > 0 else { return nil }
        let path = FileManager.default.string(withFileSystemRepresentation: buffer, length: strnlen(buffer, buffer.count))
        guard path.hasPrefix("/") else { return nil }
        return HelperExecutableFile(path: path)
    }

    public func identity() -> HelperExecutableIdentity? {
        var info = stat()
        // A symbolic link substituted for the executable is not a replacement helper.
        guard lstat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { return nil }
        return HelperExecutableIdentity(device: UInt64(UInt32(bitPattern: info.st_dev)), inode: UInt64(info.st_ino),
                                        size: Int64(info.st_size), modifiedSeconds: Int64(info.st_mtimespec.tv_sec),
                                        modifiedNanoseconds: Int64(info.st_mtimespec.tv_nsec))
    }

    public func hasValidSignature() -> Bool {
        var code: SecStaticCode?
        var required: SecRequirement?
        guard SecStaticCodeCreateWithPath(URL(fileURLWithPath: path) as CFURL, [], &code) == errSecSuccess,
              SecRequirementCreateWithString(requirement as CFString, [], &required) == errSecSuccess,
              let code, let required else { return false }
        return SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSCheckAllArchitectures), required) == errSecSuccess
    }
}
