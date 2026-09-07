import Darwin
import Foundation
import Structure

/// Only one `JobKeepAlive` may own the Mach service. Extra SM / `open -n` copies
/// steal `VUSK4B2YKQ.derrick.shared.daemon` and hang UI "Connecting to Derrick daemon".
enum DaemonSingleton {
    static func acquireOrExit() {
        guard let path = lockPath() else {
            fputs("[derrickd] singleton lock skipped — no app group container\n", stderr)
            return
        }
        let fd = open(path, O_CREAT | O_RDWR, 0o644)
        guard fd >= 0 else {
            fputs("[derrickd] singleton lock open failed \(path)\n", stderr)
            return
        }
        if flock(fd, LOCK_EX | LOCK_NB) != 0 {
            close(fd)
            fputs(
                "[derrickd] another derrickd already holds \(path) — exiting so Mach XPC stays unique\n",
                stderr
            )
            fflush(stderr)
            // Exit 0 so KeepAlive SuccessfulExit=false does not respawn extras.
            _exit(0)
        }
        // Leak `fd` for process lifetime so the exclusive lock is held until exit.
        fputs("[derrickd] singleton lock acquired pid=\(getpid()) path=\(path)\n", stderr)
        fflush(stderr)
    }

    private static func lockPath() -> String? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: DerrickAppSupport.applicationGroupIdentifier)?
            .appendingPathComponent("derrickd.lock", isDirectory: false)
            .path
    }
}
