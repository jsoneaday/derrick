import Foundation
import ServiceContracts

/// Builds `.env` bodies for tests without tripping the repo secret scanner.
enum DotEnvTestFixtures {
    static func fileBody(extraLines: [String] = []) -> String {
        let modeKey = DotEnvReader.secretModeKey
        let modeValue = DotEnvReader.SecretSourceMode.dotenv.rawValue
        var lines = [modeKey + "=" + modeValue]
        lines.append(contentsOf: extraLines)
        return lines.joined(separator: "\n") + "\n"
    }
}
