import Foundation

/// Names and paths shared by the daemon, the CLI and the install scripts.
public enum SteadyVolumePaths {
    public static let version = "1.0.0"

    public static let launchDaemonLabel = "com.steadyvolume.daemon"
    public static let launchDaemonPlist = "/Library/LaunchDaemons/com.steadyvolume.daemon.plist"
    public static let daemonBinary = "/usr/local/libexec/steadyvolume/steadyvolumed"
    public static let daemonDirectory = "/usr/local/libexec/steadyvolume"
    public static let cliBinary = "/usr/local/bin/steadyvol"

    public static let configDirectory = "/Library/Application Support/SteadyVolume"
    public static let configPath = configDirectory + "/config.json"

    /// Any local user may connect; the password, not the socket, protects the commands.
    /// /var/run is writable only by root, so only root can create this socket.
    public static let socketPath = "/var/run/steadyvolume.sock"

    /// Development mode defaults (no install, nothing shared with the real daemon).
    public static var devConfigPath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return home + "/Library/Application Support/SteadyVolume-dev/config.json"
    }

    public static var devSocketPath: String {
        "/tmp/steadyvolume-dev-\(getuid()).sock"
    }
}
