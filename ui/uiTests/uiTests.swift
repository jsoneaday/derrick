import Foundation
import LLMAgentClient
import MCP
import MCPClient
import Testing
import DBRepository
@testable import ui

@Suite struct uiTests {
    private func createTestRepository() -> DBRepository {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let config = DBRepositoryConfiguration(
            applicationName: "test",
            databaseName: "test",
            databaseDirectoryURL: directory,
            username: "ui",
            password: "ui"
        )
        let repo = DBRepository(configuration: config)
        return repo
    }

    @MainActor @Test func dotenvModeBypassesKeychainAndUsesRootUiDotEnv() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let uiFolder = root.appendingPathComponent("ui", isDirectory: true)
        try FileManager.default.createDirectory(at: uiFolder, withIntermediateDirectories: true)
        try "UI_SECRET_MODE=dotenv\nGEMINI_API_KEY=dotenv-gemini\n".write(
            to: uiFolder.appendingPathComponent(".env"),
            atomically: true,
            encoding: .utf8
        )

        let resolver = AppSecretResolver(
            environment: [:],
            currentDirectoryURL: root,
            bundleURL: root,
            keychainLoader: { _ in "keychain-gemini" }
        )

        #expect(
            resolver.resolve(
                account: "gemini-3.1-flash-lite",
                environmentKeys: ["GEMINI_API_KEY", "GOOGLE_API_KEY"]
            ) == "dotenv-gemini"
        )
    }

    @MainActor @Test func keychainModeStillPrefersKeychain() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let uiFolder = root.appendingPathComponent("ui", isDirectory: true)
        try FileManager.default.createDirectory(at: uiFolder, withIntermediateDirectories: true)
        try "UI_SECRET_MODE=dotenv\nGEMINI_API_KEY=dotenv-gemini\n".write(
            to: uiFolder.appendingPathComponent(".env"),
            atomically: true,
            encoding: .utf8
        )

        let resolver = AppSecretResolver(
            environment: ["UI_SECRET_MODE": "keychain"],
            currentDirectoryURL: root,
            bundleURL: root,
            keychainLoader: { _ in "keychain-gemini" }
        )

        #expect(
            resolver.resolve(
                account: "gemini-3.1-flash-lite",
                environmentKeys: ["GEMINI_API_KEY", "GOOGLE_API_KEY"]
            ) == "keychain-gemini"
        )
    }

    @MainActor @Test func secretStoreLoadReturnsNilForMissingItem() throws {
        let store = SecretStore(
            service: "ui-tests-\(UUID().uuidString)",
            account: "missing-\(UUID().uuidString)"
        )

        #expect(try store.load() == nil)
    }

    @Test func llmProviderDefaultsToExpectedModels() {
        #expect(LLMProviderChoice..google.defaultModel.displayName == "gemini-3.1-flash-lite")
        #expect(LLMProviderChoice.openai.defaultModel.displayName == "gpt-5.6-luna")
        #expect(LLMProviderChoice..google.apiKeyEnvironmentKeys.contains("GEMINI_API_KEY"))
        #expect(LLMProviderChoice.openai.apiKeyEnvironmentKeys.contains("OPENAI_API_KEY"))
    }

    @Test func llmFailureClassifierDetectsCreditErrors() {
        let creditErrors = [
            "You exceeded your current quota.",
            "insufficient_quota",
            "Billing has not been enabled.",
            "No API credits remaining.",
            "Rate limit exceeded. Please retry later.",
            "HTTP 429: Too Many Requests"
        ]

        for errorMessage in creditErrors {
            let error = NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: errorMessage])
            let context = LLMFailureClassifier.classify(error, provider: .openai)
            #expect(context == .outOfCredits(provider: "Openai"), "Expected credit failure for: \(errorMessage)")
        }
    }

    @Test func llmFailureClassifierFallsBackToGeneric() {
        let error = NSError(domain: "test", code: 500, userInfo: [NSLocalizedDescriptionKey: "Internal server error"])
        let context = LLMFailureClassifier.classify(error, provider: ..google)
        #expect(context == .generic(provider: "Gemini", message: "Internal server error"))
    }

    @Test func llmFailureContextMessagesAreUserFacing() {
        let credit = LLMFailureContext.outOfCredits(provider: "OpenAI")
        #expect(credit.title == "API Credits Exhausted")
        #expect(credit.message.contains("OpenAI"))
        #expect(credit.message.contains("out of API credits"))

        let generic = LLMFailureContext.generic(provider: "Gemini", message: "Something went wrong")
        #expect(generic.title == "Model Request Failed")
        #expect(generic.message.contains("Gemini"))
        #expect(generic.message.contains("Something went wrong"))
    }

    @MainActor @Test func llmFailureReporterStoresLatestFailure() {
        let reporter = LLMFailureReporter.shared
        reporter.clear()
        #expect(reporter.latest == nil)

        let context = LLMFailureContext.outOfCredits(provider: "OpenAI")
        reporter.report(context)
        #expect(reporter.latest == context)

        reporter.clear()
        #expect(reporter.latest == nil)
    }

    @MainActor @Test func helperModelSettingsPersistsModelSelection() async {
        let repo = createTestRepository()
        _ = try! await repo.createEmptyDatabaseIfNeeded(username: "ui", password: "ui")
        let settings = LLMModelSettings(repository: repo)
        settings.summarizerModel = .openai(.gpt54)
        settings.pythonScriptReviewerModel = .gemini(.gemini31FlashLite)

        // Wait for asynchronous saving tasks to complete before reloading
        try? await Task.sleep(nanoseconds: 100_000_000)

        let reloaded = LLMModelSettings(repository: repo)
        await reloaded.loadSettings()
        #expect(reloaded.summarizerModel == .openai(.gpt54))
        #expect(reloaded.pythonScriptReviewerModel == .gemini(.gemini31FlashLite))
    }

    @MainActor @Test func helperModelSettingsDefaultsAreCorrect() async {
        let repo = createTestRepository()
        _ = try! await repo.createEmptyDatabaseIfNeeded(username: "ui", password: "ui")
        let settings = LLMModelSettings(repository: repo)
        await settings.loadSettings()
        #expect(settings.summarizerModel == .defaultHelperModel)
        #expect(settings.pythonScriptReviewerModel == .defaultHelperModel)
    }

    @Test func helperModelChoicesExposeEverySupportedModel() {
        #expect(LLMModelChoice.allCases.count == 8)
        #expect(LLMModelChoice.allCases.contains(.gemini(.gemini25FlashLite)))
        #expect(LLMModelChoice.allCases.contains(.openai(.gpt55)))
        #expect(LLMModelChoice.allCases.contains(.openai(.gpt56Luna)))
        #expect(LLMModelChoice.allCases.contains(.openai(.gpt56Terra)))
        #expect(LLMModelChoice.allCases.contains(.openai(.gpt56Sol)))
        #expect(LLMModelChoice.defaultHelperModel == .openai(.gpt56Luna))
    }

    @Test func debugConfigurationReadsIsDebugFromEnvironment() throws {
        let root = URL(fileURLWithPath: "/tmp/a/b/c/d/e/f/\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let dummyBundle = root.appendingPathComponent("bundle", isDirectory: true)
        
        #expect(AppDebugConfiguration(environment: ["IS_DEBUG": "true"], currentDirectoryURL: root, bundleURL: dummyBundle).isDebugEnabled)
        #expect(AppDebugConfiguration(environment: ["IS_DEBUG": "TRUE"], currentDirectoryURL: root, bundleURL: dummyBundle).isDebugEnabled)
        #expect(!AppDebugConfiguration(environment: ["IS_DEBUG": "false"], currentDirectoryURL: root, bundleURL: dummyBundle).isDebugEnabled)
        #expect(!AppDebugConfiguration(environment: [:], currentDirectoryURL: root, bundleURL: dummyBundle).isDebugEnabled)
    }

    @MainActor @Test func debugConfigurationReadsIsDebugFromResourcesDotEnv() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let resources = root.appendingPathComponent("Resources", isDirectory: true)
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        try "IS_DEBUG=true\n".write(
            to: resources.appendingPathComponent(".env"),
            atomically: true,
            encoding: .utf8
        )

        let configuration = AppDebugConfiguration(
            environment: [:],
            currentDirectoryURL: root,
            bundleURL: root
        )

        #expect(configuration.isDebugEnabled)
    }
}
