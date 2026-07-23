import Foundation
import Observation
import Security

/// Secure storage for credentials that must NOT live in
/// UserDefaults (where they'd sit in plaintext inside the app's
/// .plist, syncing through iCloud backups). Today: just the Stash
/// API key. Future home for any other secrets we pick up
/// (Ollama tokens, StashDB key on iOS, etc.).
///
/// @Observable so SwiftUI views that read the property in their
/// body re-render when Settings writes a new value. Use directly
/// via `KeychainStore.shared.stashApiKey` — no `@AppStorage`-style
/// property wrapper, but the call site is one line either way.
///
/// Migration: on first launch after the upgrade from the
/// @AppStorage("binge.stashApiKey") implementation, the init
/// loads any existing UserDefaults value, writes it to Keychain,
/// and clears the plaintext copy. If the Keychain write fails for
/// any reason, the UserDefaults value stays put — the user never
/// loses access, worst case they re-enter the key in Settings.
@Observable
@MainActor
final class KeychainStore {
    static let shared = KeychainStore()

    private let service = "com.ordureconnoisseur.binge"
    private let stashApiKeyAccount = "stashApiKey"
    private let legacyUserDefaultsKey = "binge.stashApiKey"
    /// Keychain mirror of the `binge.stashUrl` UserDefaults value.
    /// Not a secret — kept here purely because the Keychain SURVIVES
    /// app uninstall while UserDefaults does not. Reinstalling (which
    /// the ad-hoc deploy flow needs whenever iOS rejects an update
    /// install) would otherwise wipe the server URL and drop the user
    /// back on the setup screen with no way back in.
    private static let stashUrlAccount = "stashUrlBackup"
    static let stashUrlDefaultsKey = "binge.stashUrl"

    private var _stashApiKey: String

    var stashApiKey: String {
        get { _stashApiKey }
        set {
            _stashApiKey = newValue
            if Keychain.write(
                service: service,
                account: stashApiKeyAccount,
                value: newValue
            ) {
                // Keychain write succeeded — purge any lingering
                // plaintext from the legacy UserDefaults slot so
                // the .plist no longer carries the secret.
                UserDefaults.standard.removeObject(
                    forKey: legacyUserDefaultsKey
                )
            } else {
                // Fallback: keep the value in UserDefaults so the
                // app remains functional even if Keychain ops
                // misbehave (sandbox / entitlement issues, etc).
                UserDefaults.standard.set(
                    newValue, forKey: legacyUserDefaultsKey
                )
            }
        }
    }

    /// Mirror the current `binge.stashUrl` into the Keychain, or —
    /// when UserDefaults has no URL but the Keychain does — restore
    /// it. Call once at launch BEFORE RootView reads the value, so a
    /// post-reinstall cold start comes up already configured instead
    /// of showing the setup screen.
    ///
    /// Deliberately a UserDefaults mirror rather than a migration:
    /// ~24 views read `binge.stashUrl` via @AppStorage and keeping
    /// that the single read path avoids touching all of them.
    nonisolated static func syncStashUrlBackup() {
        let defaults = UserDefaults.standard
        let current = defaults.string(forKey: stashUrlDefaultsKey) ?? ""
        if current.isEmpty {
            guard
                let saved = Keychain.read(
                    service: "com.ordureconnoisseur.binge",
                    account: stashUrlAccount
                ),
                !saved.isEmpty
            else { return }
            defaults.set(saved, forKey: stashUrlDefaultsKey)
            print("[KeychainStore] restored stashUrl from Keychain")
            return
        }
        Keychain.write(
            service: "com.ordureconnoisseur.binge",
            account: stashUrlAccount,
            value: current
        )
    }

    /// Persist a newly-entered URL immediately (Settings' onChange),
    /// so it survives a reinstall even if the app never cold-starts
    /// again before the next deploy.
    nonisolated static func backUpStashUrl(_ url: String) {
        guard !url.isEmpty else { return }
        Keychain.write(
            service: "com.ordureconnoisseur.binge",
            account: stashUrlAccount,
            value: url
        )
    }

    private init() {
        // 1. Keychain is the source of truth.
        if let existing = Keychain.read(
            service: "com.ordureconnoisseur.binge",
            account: "stashApiKey"
        ) {
            _stashApiKey = existing
            // Belt-and-braces: if both stores have a value (e.g.
            // a previous run wrote both), clear UserDefaults.
            UserDefaults.standard.removeObject(
                forKey: "binge.stashApiKey"
            )
            return
        }
        // 2. Migrate from UserDefaults if present.
        let legacy = UserDefaults.standard.string(
            forKey: "binge.stashApiKey"
        ) ?? ""
        _stashApiKey = legacy
        guard !legacy.isEmpty else { return }
        if Keychain.write(
            service: "com.ordureconnoisseur.binge",
            account: "stashApiKey",
            value: legacy
        ) {
            UserDefaults.standard.removeObject(
                forKey: "binge.stashApiKey"
            )
            print(
                "[KeychainStore] migrated stashApiKey "
                + "UserDefaults → Keychain"
            )
        } else {
            print(
                "[KeychainStore] migration write failed; "
                + "leaving stashApiKey in UserDefaults"
            )
        }
    }
}

/// Thin wrapper around Security framework's generic-password
/// keychain item APIs. Synchronous (Keychain calls are fast +
/// already main-thread-safe).
private enum Keychain {
    static func read(service: String, account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(
            query as CFDictionary, &result
        )
        guard status == errSecSuccess,
              let data = result as? Data,
              let str = String(data: data, encoding: .utf8)
        else { return nil }
        return str
    }

    @discardableResult
    static func write(
        service: String,
        account: String,
        value: String
    ) -> Bool {
        let data = value.data(using: .utf8) ?? Data()
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        // Accessible after first unlock — strikes a balance:
        // unavailable while the device is locked at boot, but
        // available the moment the user enters their passcode
        // even once. Required so the app can talk to Stash
        // when the user opens it without re-prompting.
        let attrs: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String:
                kSecAttrAccessibleAfterFirstUnlock,
        ]
        let updateStatus = SecItemUpdate(
            query as CFDictionary,
            attrs as CFDictionary
        )
        if updateStatus == errSecSuccess { return true }
        if updateStatus == errSecItemNotFound {
            var addQuery = query
            addQuery.merge(attrs) { _, new in new }
            return SecItemAdd(
                addQuery as CFDictionary, nil
            ) == errSecSuccess
        }
        return false
    }
}
