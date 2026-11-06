import Darwin
import Foundation
import SteadyVolumeCore

/// Reads a password without echoing it. Passwords are never taken from the command line.
enum PasswordPrompt {
    static func read(_ prompt: String) -> String {
        if isatty(STDIN_FILENO) == 0 {
            // Non-interactive use (stdin is a pipe or file); nothing is echoed in this case anyway.
            // A leading byte-order mark and a trailing carriage return are not part of the password.
            print(prompt, terminator: "")
            fflush(stdout)
            let line = readLine(strippingNewline: true) ?? ""
            print()
            return PipedPassword.clean(line)
        }

        var buffer = [CChar](repeating: 0, count: 1024)
        defer { for i in buffer.indices { buffer[i] = 0 } }
        guard let result = readpassphrase(prompt, &buffer, buffer.count, RPP_REQUIRE_TTY) else { return "" }
        return String(cString: result)
    }
}
