import Foundation

/// Go contract shown to models that generate Derrick plugin guest programs.
public enum DerrickGuestGo: Sendable {
    public static func source(for spec: PluginSpec? = nil) throws -> String {
        var sections = [ScriptExecContractPrompts.builderGuide()]
        if let spec {
            sections.append(
                """
                Plugin parameters are delivered in the input object's `params` object.
                The parameter contract is:
                \(try spec.goParameterDeclaration())

                --- \(GuestContract.Schema.connectorParams.rawValue) ---
                \(try GuestContract.loadSchemaText(.connectorParams))
                """
            )
        }
        return sections.joined(separator: "\n\n")
    }
}

private extension PluginSpec {
    func goParameterDeclaration() throws -> String {
        _ = try validated()
        let fields = parameters.map { parameter in
            "    \(parameter.name) \(parameterType(parameter.type))"
        }
        return """
        type PluginParams struct {
        \(fields.joined(separator: "\n"))
        }
        """
    }

    func parameterType(_ type: PluginParameterType) -> String {
        switch type {
        case .string:
            return "string"
        case .number:
            return "float64"
        case .boolean:
            return "bool"
        case .stringList:
            return "[]string"
        case .numberList:
            return "[]float64"
        }
    }
}
