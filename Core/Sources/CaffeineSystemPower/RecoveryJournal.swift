import Foundation
import Darwin

struct RecoveryRecord: Codable, Equatable, Sendable {
    enum Phase: String, Codable { case prepared, active, releasing }
    enum Baseline: String, Codable { case explicitZero, defaultFalse }
    var schema = 1
    let operation: UUID
    let boot: String
    let baseline: Baseline
    var phase: Phase
}

protocol RecoveryJournal: Sendable {
    func load() throws -> RecoveryRecord?
    func save(_ record: RecoveryRecord) throws
    func remove() throws
}

/// Descriptor-relative operations avoid following a replaced journal symlink.
/// Production uses the fixed root-owned path; configurable ownership is internal
/// solely so tests can exercise the same file rules in a temporary directory.
struct FileRecoveryJournal: RecoveryJournal {
    static let productionDirectory = URL(fileURLWithPath: "/Library/Application Support/com.serhiital.Caffeine", isDirectory: true)
    let directory: URL
    let owner: uid_t

    init(directory: URL = Self.productionDirectory, owner: uid_t = 0) {
        self.directory = directory; self.owner = owner
    }
    private var file: SecureRecoveryFile<RecoveryRecord> {
        .init(directory: directory, owner: owner, filename: "sleep-recovery.json")
    }
    func load() throws -> RecoveryRecord? {
        guard let record = try file.load() else { return nil }
        guard record.schema == 1, UUID(uuidString: record.boot) != nil else {
            throw NSError(domain: "CaffeineRecoveryJournal", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "The sleep recovery record is invalid."])
        }
        return record
    }
    func save(_ record: RecoveryRecord) throws { _ = try load(); try file.save(record) }
    func remove() throws { _ = try load(); try file.remove() }
}

/// Hardened storage for the sleep recovery transaction.
struct SecureRecoveryFile<Record: Codable & Sendable>: Sendable {
    let directory: URL
    let owner: uid_t
    let filename: String

    init(directory: URL, owner: uid_t, filename: String) {
        self.directory = directory; self.owner = owner; self.filename = filename
    }

    func load() throws -> Record? {
        let dir = try openDirectory(); defer { close(dir) }
        let fd = openat(dir, filename, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        if fd < 0 && errno == ENOENT { return nil }
        guard fd >= 0 else { throw failure() }; defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == owner, info.st_mode & 0o777 == 0o600,
              info.st_nlink == 1, info.st_size > 0, info.st_size <= 8192,
              hasNoExtendedACL(fd) else { throw failure() }
        var bytes = [UInt8](repeating: 0, count: Int(info.st_size))
        var offset = 0
        while offset < bytes.count {
            let amount = bytes.withUnsafeMutableBytes { ptr in
                Darwin.read(fd, ptr.baseAddress!.advanced(by: offset), ptr.count - offset)
            }
            if amount < 0 && errno == EINTR { continue }
            guard amount > 0 else { throw failure() }
            offset += amount
        }
        let record = try JSONDecoder().decode(Record.self, from: Data(bytes))
        return record
    }

    func save(_ record: Record) throws {
        // Reject a malformed or substituted existing record before overwriting it.
        _ = try load()
        let dir = try openDirectory(); defer { close(dir) }
        let temporary = ".\(filename)-\(UUID().uuidString).tmp"
        let fd = openat(dir, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw failure() }
        defer { close(fd); _ = unlinkat(dir, temporary, 0) }
        guard fchmod(fd, 0o600) == 0 else { throw failure() }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == owner, hasNoExtendedACL(fd) else { throw failure() }
        let bytes = try JSONEncoder().encode(record)
        var offset = 0
        while offset < bytes.count {
            let amount = bytes.withUnsafeBytes { ptr in
                Darwin.write(fd, ptr.baseAddress!.advanced(by: offset), ptr.count - offset)
            }
            if amount < 0 && errno == EINTR { continue }
            guard amount > 0 else { throw failure() }
            offset += amount
        }
        guard fsync(fd) == 0, fcntl(fd, F_FULLFSYNC) == 0 else { throw failure() }
        guard renameat(dir, temporary, dir, filename) == 0, fsync(dir) == 0 else { throw failure() }
    }

    func remove() throws {
        guard try load() != nil else { return }
        let dir = try openDirectory(); defer { close(dir) }
        guard unlinkat(dir, filename, 0) == 0, fsync(dir) == 0 else { throw failure() }
    }

    private func openDirectory() throws -> Int32 {
        guard directory.isFileURL, directory.path.hasPrefix("/"),
              !directory.pathComponents.contains("..") else { throw failure() }
        var fd = open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw failure() }
        do {
            let components = directory.pathComponents.filter { $0 != "/" }
            for (index, component) in components.enumerated() {
                let last = index == components.count - 1
                var next = openat(fd, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                if next < 0 && errno == ENOENT && last {
                    guard mkdirat(fd, component, 0o700) == 0 || errno == EEXIST else { throw failure() }
                    next = openat(fd, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                    guard fsync(fd) == 0 else { if next >= 0 { close(next) }; throw failure() }
                }
                guard next >= 0 else { throw failure() }
                close(fd); fd = next
                var info = stat()
                guard fstat(fd, &info) == 0 else { throw failure() }
                if last {
                    guard info.st_uid == owner, info.st_mode & 0o777 == 0o700, hasNoExtendedACL(fd) else { throw failure() }
                } else if owner == 0 {
                    guard info.st_uid == 0, info.st_mode & 0o022 == 0, hasNoExtendedACL(fd) else { throw failure() }
                }
            }
            return fd
        } catch { close(fd); throw error }
    }

    private func failure(line: Int = #line) -> NSError {
        NSError(domain: "CaffeineRecoveryJournal", code: Int(errno), userInfo: [NSLocalizedDescriptionKey: "The recovery record could not be safely read or saved.", "sourceLine": line])
    }

    private func hasNoExtendedACL(_ fd: Int32) -> Bool {
        errno = 0
        // APFS returns ENOENT when no extended ACL is present.
        guard let acl = acl_get_fd_np(fd, ACL_TYPE_EXTENDED) else { return errno == ENOENT }
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        var entry: acl_entry_t?
        // Darwin returns 0 for an entry and -1/EINVAL for the end of an ACL.
        errno = 0
        return acl_get_entry(acl, Int32(ACL_FIRST_ENTRY.rawValue), &entry) == -1 && errno == EINVAL
    }
}

func currentBootIdentifier() -> String? {
    var size = 0
    guard sysctlbyname("kern.bootsessionuuid", nil, &size, nil, 0) == 0, size > 1, size < 128 else { return nil }
    var bytes = [CChar](repeating: 0, count: size)
    guard sysctlbyname("kern.bootsessionuuid", &bytes, &size, nil, 0) == 0 else { return nil }
    return String(decoding: bytes.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
}
