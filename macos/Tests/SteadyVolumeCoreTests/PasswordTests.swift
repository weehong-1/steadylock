import XCTest
@testable import SteadyVolumeCore

final class PasswordTests: XCTestCase {
    private let iterations = PasswordHasher.minimumIterations

    func testHashThenVerifyWithSamePasswordSucceeds() throws {
        let hash = PasswordHasher.hash("correct horse", iterations: iterations)
        XCTAssertTrue(try PasswordHasher.verify("correct horse", against: hash))
    }

    func testVerifyWithWrongPasswordFails() throws {
        let hash = PasswordHasher.hash("correct horse", iterations: iterations)
        for attempt in [nil, "", "Correct horse", "correct horse ", "wrong"] as [String?] {
            XCTAssertFalse(try PasswordHasher.verify(attempt, against: hash), "\(String(describing: attempt))")
        }
    }

    func testRecordFormatMatchesWindows() throws {
        let hash = PasswordHasher.hash("correct horse", iterations: iterations)
        XCTAssertEqual(hash.algorithm, "PBKDF2-SHA256")
        XCTAssertEqual(hash.iterations, iterations)
        XCTAssertEqual(Data(base64Encoded: hash.salt)?.count, 16)
        XCTAssertEqual(Data(base64Encoded: hash.hash)?.count, 32)
        XCTAssertFalse(hash.hash.contains("correct"))
    }

    func testDefaultIterationsAreAtLeastTheMinimum() {
        XCTAssertGreaterThanOrEqual(PasswordHasher.defaultIterations, 210_000)
        XCTAssertEqual(PasswordHasher.minimumIterations, 210_000)
    }

    func testSaltIsRandomPerHash() {
        let a = PasswordHasher.hash("correct horse", iterations: iterations)
        let b = PasswordHasher.hash("correct horse", iterations: iterations)
        XCTAssertNotEqual(a.salt, b.salt)
        XCTAssertNotEqual(a.hash, b.hash)
    }

    /// Known-answer test, so the derivation is the standard PBKDF2-HMAC-SHA256 used by .NET's Rfc2898DeriveBytes.
    /// Vector: RFC 7914 section 11 ("passwd", salt "salt", 1 iteration, first 32 bytes).
    func testDerivationMatchesThePbkdf2Standard() {
        let derived = PasswordHasher.derive("passwd", salt: Array("salt".utf8), iterations: 1)
        let hex = derived.map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(hex, "55ac046e56e3089fec1691c22544b605f94185216dde0465e68b9d57c20dacbc")
    }

    func testUnicodeIsNormalisedSoComposedAndDecomposedMatch() throws {
        let hash = PasswordHasher.hash("caf\u{00E9} au lait", iterations: iterations)
        XCTAssertTrue(try PasswordHasher.verify("cafe\u{0301} au lait", against: hash))
    }

    func testStoredHashWithTooFewIterationsIsRejected() {
        var hash = PasswordHasher.hash("correct horse", iterations: iterations)
        hash.iterations = 1000
        XCTAssertThrowsError(try PasswordHasher.verify("correct horse", against: hash))
    }

    func testStoredHashWithWrongAlgorithmOrEncodingIsRejected() {
        let good = PasswordHasher.hash("correct horse", iterations: iterations)
        var algorithm = good; algorithm.algorithm = "MD5"
        var salt = good; salt.salt = "not base64!"
        var shortSalt = good; shortSalt.salt = Data([1, 2, 3]).base64EncodedString()
        var hashLength = good; hashLength.hash = Data([1, 2, 3]).base64EncodedString()
        for bad in [algorithm, salt, shortSalt, hashLength] {
            XCTAssertThrowsError(try PasswordHasher.verify("correct horse", against: bad))
        }
    }

    func testPolicy() {
        XCTAssertNotNil(PasswordPolicy.check(nil))
        XCTAssertNotNil(PasswordPolicy.check(""))
        XCTAssertNotNil(PasswordPolicy.check("short"))
        XCTAssertNotNil(PasswordPolicy.check("        "))
        XCTAssertNotNil(PasswordPolicy.check("has a\ttab in it"))
        XCTAssertNotNil(PasswordPolicy.check(String(repeating: "x", count: 257)))
        XCTAssertNil(PasswordPolicy.check(String(repeating: "x", count: 256)))
        XCTAssertNil(PasswordPolicy.check("correct horse"))
        XCTAssertNil(PasswordPolicy.check("12345678"))
    }

    func testPipedPasswordIgnoresByteOrderMarkAndCarriageReturn() {
        XCTAssertEqual(PipedPassword.clean("\u{FEFF}correct horse\r"), "correct horse")
        XCTAssertEqual(PipedPassword.clean("\u{FEFF}correct horse"), "correct horse")
        XCTAssertEqual(PipedPassword.clean("correct horse\r\n"), "correct horse")
        XCTAssertEqual(PipedPassword.clean("correct horse"), "correct horse")
        XCTAssertEqual(PipedPassword.clean(" spaces kept "), " spaces kept ")
        XCTAssertEqual(PipedPassword.clean("in\u{FEFF}side"), "in\u{FEFF}side")
    }
}
