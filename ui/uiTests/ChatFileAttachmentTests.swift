import Foundation
import Testing
import UniformTypeIdentifiers
@testable import ui

@Suite struct ChatFileAttachmentTests {
    @Test func allowsDocumentTypesAndRejectsExecutables() {
        #expect(ChatFileAttachmentPolicy.isAllowed(filename: "notes.csv", type: .commaSeparatedText))
        #expect(ChatFileAttachmentPolicy.isAllowed(filename: "report.pdf", type: .pdf))
        #expect(ChatFileAttachmentPolicy.isAllowed(filename: "readme.txt", type: .plainText))
        #expect(ChatFileAttachmentPolicy.isAllowed(filename: "data.json", type: .json))
        #expect(!ChatFileAttachmentPolicy.isAllowed(filename: "install.sh", type: .plainText))
        #expect(!ChatFileAttachmentPolicy.isAllowed(filename: "App.app", type: .application))
        #expect(!ChatFileAttachmentPolicy.isAllowed(filename: "payload.bin", type: .data))
    }

    @Test func inlinesSmallTextButNotPDF() {
        #expect(
            ChatFileAttachmentPolicy.isInlineable(
                filename: "notes.csv",
                typeIdentifier: UTType.commaSeparatedText.identifier,
                byteCount: 120
            )
        )
        #expect(
            !ChatFileAttachmentPolicy.isInlineable(
                filename: "report.pdf",
                typeIdentifier: UTType.pdf.identifier,
                byteCount: 120
            )
        )
        #expect(
            !ChatFileAttachmentPolicy.isInlineable(
                filename: "notes.csv",
                typeIdentifier: UTType.commaSeparatedText.identifier,
                byteCount: Int64(ChatFileAttachmentPolicy.maximumInlineUTF8Bytes) + 1
            )
        )
    }

    @Test func composerKeepsUserTextAndInlinesCSV() {
        let csv = ChatFileAttachment(
            id: "a1",
            originalFilename: "notes.csv",
            byteCount: 11,
            typeIdentifier: UTType.commaSeparatedText.identifier,
            stagedRelativePath: "session/a1/notes.csv"
        )
        let pdf = ChatFileAttachment(
            id: "a2",
            originalFilename: "report.pdf",
            byteCount: 2048,
            typeIdentifier: UTType.pdf.identifier,
            stagedRelativePath: "session/a2/report.pdf"
        )
        let prompt = ChatFileAttachmentPromptComposer.agentPrompt(
            userText: "Summarize these",
            payloads: [
                ChatFileAttachmentInlinePayload(attachment: csv, utf8Text: "name,age\nAda,36"),
                ChatFileAttachmentInlinePayload(attachment: pdf, utf8Text: nil),
            ]
        )

        #expect(prompt.contains("Summarize these"))
        #expect(prompt.contains("----- begin notes.csv -----"))
        #expect(prompt.contains("name,age\nAda,36"))
        #expect(prompt.contains("report.pdf"))
        #expect(prompt.contains("contents are not included in this message"))
        #expect(prompt.contains("files.extract"))
        #expect(!prompt.contains("Process the attached files."))
    }

    @Test func composerUsesFallbackWhenPromptIsEmpty() {
        let csv = ChatFileAttachment(
            id: "a1",
            originalFilename: "notes.csv",
            byteCount: 4,
            typeIdentifier: UTType.commaSeparatedText.identifier,
            stagedRelativePath: "session/a1/notes.csv"
        )
        let prompt = ChatFileAttachmentPromptComposer.agentPrompt(
            userText: "   ",
            payloads: [
                ChatFileAttachmentInlinePayload(attachment: csv, utf8Text: "a,b"),
            ]
        )
        #expect(prompt.hasPrefix(ChatFileAttachmentPromptComposer.emptyUserFallback))
        #expect(prompt.contains("a,b"))
    }

    @Test func composerWithoutAttachmentsLeavesPromptUnchanged() {
        #expect(
            ChatFileAttachmentPromptComposer.agentPrompt(userText: "hello", payloads: [])
                == "hello"
        )
    }

    @Test func stagerCopiesAllowedFilesAndRejectsOversizedAndExtraFiles() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let sourceDir = root.appendingPathComponent("source", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceDir, withIntermediateDirectories: true)
        let csvURL = sourceDir.appendingPathComponent("notes.csv")
        try "a,b\n1,2\n".write(to: csvURL, atomically: true, encoding: .utf8)
        let oversized = sourceDir.appendingPathComponent("big.txt")
        try Data(repeating: 0x61, count: 32).write(to: oversized)
        let script = sourceDir.appendingPathComponent("install.sh")
        try "#!/bin/sh\necho hi\n".write(to: script, atomically: true, encoding: .utf8)

        var stager = ChatFileAttachmentStager(
            rootDirectory: root.appendingPathComponent("staged", isDirectory: true),
            maximumFileCount: 1,
            maximumBytesPerFile: 16
        )

        let staged = try stager.stage(urls: [csvURL], sessionID: "session-1", existingCount: 0)
        #expect(staged.count == 1)
        #expect(staged[0].originalFilename == "notes.csv")
        let copied = stager.rootDirectory.appendingPathComponent(staged[0].stagedRelativePath)
        #expect(FileManager.default.fileExists(atPath: copied.path))
        #expect(try String(contentsOf: copied, encoding: .utf8).contains("1,2"))

        let inlined = ChatFileAttachmentInliner.payloads(
            attachments: staged,
            rootDirectory: stager.rootDirectory
        )
        #expect(inlined[0].utf8Text?.contains("1,2") == true)

        do {
            _ = try stager.stage(urls: [oversized], sessionID: "session-1", existingCount: 0)
            Issue.record("Expected oversized file to be rejected")
        } catch let error as ChatFileAttachmentError {
            #expect(error == .fileTooLarge(filename: "big.txt", byteCount: 32))
        }

        do {
            _ = try stager.stage(urls: [csvURL], sessionID: "session-1", existingCount: 1)
            Issue.record("Expected extra file to be rejected")
        } catch let error as ChatFileAttachmentError {
            #expect(error == .tooManyFiles(limit: 1))
        }

        do {
            _ = try stager.stage(urls: [script], sessionID: "session-1", existingCount: 0)
            Issue.record("Expected shell script to be rejected")
        } catch let error as ChatFileAttachmentError {
            #expect(error == .typeNotAllowed(filename: "install.sh"))
        }

        stager.remove(staged[0])
        #expect(!FileManager.default.fileExists(atPath: copied.path))
    }

    @Test func sanitizesPathTraversalFromFilenames() {
        #expect(ChatFileAttachmentStager.sanitizedFilename("../secret.txt") == "secret.txt")
        #expect(ChatFileAttachmentStager.sanitizedFilename("a/../../etc/passwd") == "passwd")
        #expect(ChatFileAttachmentStager.sanitizedFilename("My Report.csv") == "My_Report.csv")
    }
}
