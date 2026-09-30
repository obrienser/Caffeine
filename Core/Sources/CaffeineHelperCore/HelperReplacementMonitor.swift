import Foundation

/// The file a helper process was launched from. A replaced bundle yields a
/// different file even when its contents are identical.
public struct HelperExecutableIdentity: Equatable, Sendable {
    public let device: UInt64
    public let inode: UInt64
    public let size: Int64
    public let modifiedSeconds: Int64
    public let modifiedNanoseconds: Int64

    public init(device: UInt64, inode: UInt64, size: Int64, modifiedSeconds: Int64, modifiedNanoseconds: Int64) {
        self.device = device; self.inode = inode; self.size = size
        self.modifiedSeconds = modifiedSeconds; self.modifiedNanoseconds = modifiedNanoseconds
    }
}

public protocol HelperExecutableInspecting: Sendable {
    /// Nil unless a regular file currently exists at the launch path.
    func identity() -> HelperExecutableIdentity?
    /// True only for a complete helper satisfying the exact signing requirement.
    func hasValidSignature() -> Bool
}

/// Clients cannot authenticate a helper whose on-disk executable was replaced.
/// This monitor reports when a complete, validly signed replacement has settled
/// at the launch path. It never decides whether the session allows retirement.
public struct HelperReplacementMonitor: Sendable {
    /// An unchanged but rejected file is validated again only occasionally.
    public static let checksBetweenValidations = 12

    private let executable: any HelperExecutableInspecting
    private let launched: HelperExecutableIdentity?
    private var candidate: HelperExecutableIdentity?
    private var candidateIsValid = false
    private var checksSinceValidation = 0

    public init(executable: any HelperExecutableInspecting) {
        self.executable = executable
        launched = executable.identity()
    }

    public mutating func replacementIsReady() -> Bool {
        guard let launched, let current = executable.identity(), current != launched else {
            candidate = nil
            candidateIsValid = false
            return false
        }
        guard current == candidate else {
            // A copy in progress keeps changing. Require a second unchanged observation.
            candidate = current
            candidateIsValid = false
            checksSinceValidation = Self.checksBetweenValidations
            return false
        }
        if candidateIsValid { return true }
        checksSinceValidation += 1
        guard checksSinceValidation > Self.checksBetweenValidations else { return false }
        checksSinceValidation = 0
        // The file may change again while its signature is being validated.
        candidateIsValid = executable.hasValidSignature() && executable.identity() == current
        return candidateIsValid
    }
}
