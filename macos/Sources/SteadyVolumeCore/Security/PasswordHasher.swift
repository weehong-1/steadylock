import CommonCrypto
import Foundation
import Security

/// A stored PBKDF2 password hash. Salt and hash are Base64. Same record as the Windows config.
public struct PasswordHash: Codable, Equatable {
    public var algorithm: String
    public var iterations: Int
    public var salt: String
    public var hash: String

    public init(algorithm: String, iterations: Int, salt: String, hash: String) {
        self.algorithm = algorithm
        self.iterations = iterations
        self.salt = salt
        self.hash = hash
    }

    /// Throws `InvalidPasswordHashError` if this record is not usable.
    public func validate() throws {
        guard algorithm == PasswordHasher.algorithmName else {
            throw InvalidPasswordHashError("Unsupported password algorithm '\(algorithm)'.")
        }
        guard iterations >= PasswordHasher.minimumIterations else {
            throw InvalidPasswordHashError(
                "Stored iteration count \(iterations) is below the minimum of \(PasswordHasher.minimumIterations).")
        }
        guard let saltBytes = Data(base64Encoded: salt) else { throw InvalidPasswordHashError("Stored salt is not valid Base64.") }
        guard saltBytes.count >= PasswordHasher.saltSize else { throw InvalidPasswordHashError("Stored salt is too short.") }
        guard let hashBytes = Data(base64Encoded: hash) else { throw InvalidPasswordHashError("Stored hash is not valid Base64.") }
        guard hashBytes.count == PasswordHasher.hashSize else { throw InvalidPasswordHashError("Stored hash has the wrong length.") }
    }
}

public struct InvalidPasswordHashError: Error, CustomStringConvertible {
    public let description: String
    public init(_ description: String) { self.description = description }
}

/// PBKDF2-HMAC-SHA256 with a random per-password salt and constant-time comparison.
public enum PasswordHasher {
    public static let algorithmName = "PBKDF2-SHA256"
    /// Hard floor. Stored hashes below this are rejected, so a tampered config cannot downgrade.
    public static let minimumIterations = 210_000
    /// Iterations used for new hashes (OWASP 2023 guidance for PBKDF2-HMAC-SHA256).
    public static let defaultIterations = 600_000
    public static let saltSize = 16
    public static let hashSize = 32

    public static func hash(_ password: String, iterations: Int = defaultIterations) -> PasswordHash {
        precondition(iterations >= minimumIterations, "At least \(minimumIterations) iterations are required.")
        var salt = [UInt8](repeating: 0, count: saltSize)
        let status = SecRandomCopyBytes(kSecRandomDefault, saltSize, &salt)
        precondition(status == errSecSuccess, "SecRandomCopyBytes failed: \(status)")
        var derived = derive(password, salt: salt, iterations: iterations)
        defer { zero(&derived) }
        return PasswordHash(algorithm: algorithmName, iterations: iterations,
                            salt: Data(salt).base64EncodedString(), hash: Data(derived).base64EncodedString())
    }

    /// Returns true when `password` matches. Throws `InvalidPasswordHashError` when the stored record
    /// itself is unusable (wrong algorithm, too few iterations, bad encoding).
    public static func verify(_ password: String?, against stored: PasswordHash) throws -> Bool {
        try stored.validate()
        let salt = [UInt8](Data(base64Encoded: stored.salt)!)
        let expected = [UInt8](Data(base64Encoded: stored.hash)!)
        // Always run the full derivation, even for an empty password, so timing does not leak anything.
        var actual = derive(password ?? "", salt: salt, iterations: stored.iterations)
        defer { zero(&actual) }
        return constantTimeEquals(actual, expected)
    }

    static func derive(_ password: String, salt: [UInt8], iterations: Int) -> [UInt8] {
        // Normalise (NFC, like Windows) so the same visible password always produces the same bytes.
        var bytes = Array(password.precomposedStringWithCanonicalMapping.utf8)
        defer { zero(&bytes) }
        var out = [UInt8](repeating: 0, count: hashSize)
        let status = bytes.withUnsafeBufferPointer { pw -> Int32 in
            pw.withMemoryRebound(to: CChar.self) { chars in
                CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2),
                                     chars.baseAddress, chars.count,
                                     salt, salt.count,
                                     CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), UInt32(iterations),
                                     &out, out.count)
            }
        }
        precondition(status == kCCSuccess, "CCKeyDerivationPBKDF failed: \(status)")
        return out
    }

    static func constantTimeEquals(_ a: [UInt8], _ b: [UInt8]) -> Bool {
        guard a.count == b.count else { return false }
        var diff: UInt8 = 0
        for i in 0..<a.count { diff |= a[i] ^ b[i] }
        return diff == 0
    }

    private static func zero(_ bytes: inout [UInt8]) {
        for i in bytes.indices { bytes[i] = 0 }
    }
}
