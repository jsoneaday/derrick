import Testing
@testable import ServiceEnsureUp
import Structure

@Suite struct ServiceEnsureUpTests {
    @Test func errorDescriptionsAreStable() {
        #expect(ServiceEnsureUpError.timeout.errorDescription?.contains("timed out") == true)
        #expect(ServiceEnsureUpError.unavailable("X").errorDescription?.contains("X") == true)
    }

    @Test func serviceIDsMatch() {
        #expect(DerrickServiceID.job.xpcServiceName == "derrick.ui.JobService")
        #expect(DerrickServiceID.agent.xpcServiceName == "derrick.ui.AgentService")
        #expect(DerrickServiceID.mcp.xpcServiceName == "derrick.ui.MCPService")
    }
}
