import Foundation

public enum PasswordPolicy {
    /// Lengths are counted in UTF-16 code units, exactly like the Windows version.
    public static let minimumLength = 8
    public static let maximumLength = 256

    /// Returns nil when the password is acceptable, otherwise a message for the user.
    public static func check(_ password: String?) -> String? {
        guard let password, !password.isEmpty else { return "The password cannot be empty." }
        let length = password.utf16.count
        if length < minimumLength { return "The password must be at least \(minimumLength) characters." }
        if length > maximumLength { return "The password must be at most \(maximumLength) characters." }
        if password.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) {
            return "The password cannot contain control characters."
        }
        if password.unicodeScalars.allSatisfy({ $0.properties.isWhitespace }) {
            return "The password cannot be only spaces."
        }
        return nil
    }
}

/// Clean-up for passwords read from redirected stdin: a leading UTF-8 byte-order mark and a trailing
/// carriage return (files written on Windows, PowerShell pipes) are not part of the password.
public enum PipedPassword {
    public static func clean(_ line: String) -> String {
        var scalars = line.unicodeScalars
        while scalars.first == "\u{FEFF}" { scalars.removeFirst() }
        while scalars.last == "\r" || scalars.last == "\n" { scalars.removeLast() }
        return String(scalars)
    }
}
