import Foundation
import Structure
import Testing

@Suite struct ExecutionContextAlignmentTests {
    @Test func workflowKindsMatchExecutionContextSchema() throws {
        let schemaKinds = Set(try GuestContract.officialWorkflowKinds())
        let swiftKinds = Set(WorkflowKind.allCases.map(\.rawValue))
        #expect(swiftKinds == schemaKinds)
    }

    @Test func capabilitiesMatchExecutionContextSchema() throws {
        let schemaCapabilities = Set(try GuestContract.officialExecutionContextCapabilities())
        let swiftCapabilities = Set(ExecutionContextCapability.allCases.map(\.rawValue))
        #expect(swiftCapabilities == schemaCapabilities)
    }

    @Test func deliveryModesMatchExecutionContextSchema() throws {
        let schemaModes = Set(try GuestContract.officialExecutionContextDeliveryModes())
        let swiftModes = Set(ExecutionContextDelivery.allCases.map(\.rawValue))
        #expect(swiftModes == schemaModes)
    }
}
