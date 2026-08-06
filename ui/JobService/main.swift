import Foundation

let delegate = JobServiceListenerDelegate()
let processInfo = ProcessInfo.processInfo
fputs("[JobService] main starting pid=\(processInfo.processIdentifier)\n", stderr)
// Start scheduler loop (claims due jobs).
JobServiceScheduler.shared.start()
let listener = NSXPCListener.service()
listener.delegate = delegate
listener.resume()
fputs("[JobService] listener resumed\n", stderr)
