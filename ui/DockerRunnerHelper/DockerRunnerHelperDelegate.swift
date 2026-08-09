import Foundation
import DockerRunnerXPC
import os.log

private let logger = Logger(subsystem: "derrick.ui.DockerRunnerHelper", category: "DockerRunnerHelperDelegate")

final class DockerRunnerHelperDelegate: NSObject, NSXPCListenerDelegate {
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        logger.log("XPC listener received a new connection request from the app.")
        HelperLogRelay.shared.log("XPC listener received a new connection request from the app.")

        // Peer must be the main app or another Derrick XPC service (same team when available).
        let requirement = XPCPeerAuthentication.requirementString(
            allowedPeerIdentifiers: [
                XPCPeerAuthentication.mainAppIdentifier,
                XPCPeerAuthentication.agentServiceIdentifier,
                XPCPeerAuthentication.jobServiceIdentifier,
                XPCPeerAuthentication.mcpServiceIdentifier,
                XPCPeerAuthentication.daemonIdentifier
            ]
        )
        do {
            try XPCPeerAuthentication.apply(requirement: requirement, to: connection)
            HelperLogRelay.shared.log("XPC peer code-signing requirement applied: \(requirement)")
        } catch {
            let message = "Rejected XPC connection: peer code-signing requirement failed (\(error.localizedDescription)). requirement=\(requirement)"
            logger.error("\(message, privacy: .public)")
            HelperLogRelay.shared.log(message)
            return false
        }

        connection.exportedInterface = NSXPCInterface(with: DockerProcessRunnerXPC.self)
        HelperLogRelay.shared.log("Exported interface configured for DockerProcessRunnerXPCProtocol.")

        connection.remoteObjectInterface = NSXPCInterface(with: DockerHelperLogSinkXPC.self)
        HelperLogRelay.shared.log("Remote object interface configured for DockerHelperLogSinkXPCProtocol.")

        let service = DockerRunnerService()
        connection.exportedObject = service
        HelperLogRelay.shared.log("Exported helper object created and attached.")

        connection.interruptionHandler = {
            logger.warning("XPC connection interrupted on helper side.")
            HelperLogRelay.shared.log("XPC connection interrupted on helper side.")
        }
        connection.invalidationHandler = {
            logger.warning("XPC connection invalidated on helper side.")
            HelperLogRelay.shared.log("XPC connection invalidated on helper side.")
        }

        connection.resume()
        HelperLogRelay.shared.log("Helper-side XPC connection resumed.")
        HelperLogRelay.shared.attach(connection: connection)
        return true
    }
}
