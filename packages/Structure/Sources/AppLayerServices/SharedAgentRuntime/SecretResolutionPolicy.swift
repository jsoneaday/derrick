import Foundation

/// How a secret lookup should resolve across Keychain, process env, and `.env`.
public enum SecretResolutionPolicy: Sendable {
    /// Keychain only — used for user-created plugin / connector credentials.
    case keychainOnly
    /// Follow `UI_SECRET_MODE` (Keychain with env/dotenv fallback, or dotenv-only).
    case appDefault
}
