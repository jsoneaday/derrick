import Foundation

public enum DatabaseSchema {
    public static let latestVersion = 21

    public static func migrationSQL(version: Int, isUp: Bool) throws -> String {
        let migrationName = String(format: "%04d_%@", version, migrationFileBaseName(for: version))
        let fileSuffix = isUp ? "up" : "down"
        let resourceName = "\(migrationName).\(fileSuffix)"
        let fileURL = try resourceURL(name: resourceName)

        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw CocoaError(.fileNoSuchFile)
        }

        do {
            return try String(contentsOf: fileURL, encoding: .utf8)
        } catch {
            throw CocoaError(.fileReadCorruptFile)
        }
    }

    private static func migrationFileBaseName(for version: Int) -> String {
        switch version {
        case 1:
            return "memory_sessions"
        case 2:
            return "memory_records"
        case 3:
            return "policy_rules"
        case 4:
            return "policy_approvals"
        case 5:
            return "policy_audit_log"
        case 6:
            return "configuration"
        case 7:
            return "egress_allowed_suffixes"
        case 8:
            return "content_sensitivity_grants"
        case 9:
            return "service_logs"
        case 10:
            return "jobs"
        case 11:
            return "job_schedules"
        case 12:
            return "job_failure_detail"
        case 13:
            return "job_results"
        case 14:
            return "pending_hitl_approvals"
        case 15:
            return "job_results_notify"
        case 16:
            return "hitl_job_context"
        case 17:
            return "chat_orchestration"
        case 18:
            return "plugins"
        case 19:
            return "plugin_source"
        case 20:
            return "policy_approvals_fk"
        case 21:
            return "plugin_hooks"
        default:
            return "unknown"
        }
    }

    private static func resourceURL(name: String) throws -> URL {
        guard let fileURL = Bundle.module.url(forResource: name, withExtension: "sql") else {
            throw CocoaError(.fileNoSuchFile)
        }

        return fileURL
    }
}