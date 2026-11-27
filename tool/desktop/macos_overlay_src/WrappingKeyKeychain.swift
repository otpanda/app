import Foundation
import Security

enum KeychainBackend { case fileBased, dataProtection }

/// Live Keychain access. One generic-password item per namespace.
///
/// The backend is a COMPILE-TIME choice (macos_overlay.py rewrites the marker
/// line below). There is never a runtime fallback between the two: an item in
/// one store is invisible to the other, so switching would look like an absent
/// key and orphan sealed state.
///  - fileBased (default): the user's login keychain. No entitlement, no
///    provisioning profile, works for ad-hoc builds. Access is by per-item ACL
///    keyed to the creating app's code identity.
///  - dataProtection: needs a signed build with keychain-access-groups.
struct SystemKeychainOps: KeychainOps {
  static let service = "app.otpanda.wrapping-key"
  // OTPANDA_BACKEND_MARKER
  static let backend: KeychainBackend = .fileBased

  private func base(_ ns: String) -> [String: Any] {
    var q: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: SystemKeychainOps.service,
      kSecAttrAccount as String: ns,
    ]
    if SystemKeychainOps.backend == .dataProtection {
      q[kSecAttrSynchronizable as String] = kCFBooleanFalse as Any
      q[kSecUseDataProtectionKeychain as String] = true
    }
    return q
  }

  /// Never let the system show an ACL or unlock dialog from a call: a dialog
  /// can hang a headless or backgrounded app. kSecUseAuthenticationUI=Fail is
  /// kept, but a real-host probe showed it does NOT stop the legacy file-based
  /// ACL prompt (existing-key reads hung until killed). The effective control is
  /// the process-wide legacy switch SecKeychainSetUserInteractionAllowed(false):
  /// with it, a call that would prompt returns errSecInteractionNotAllowed
  /// (-25308) instead. It is scoped to one call under a lock and restored after.
  /// It never widens an ACL; refusal stays refusal. Deprecated API, UNVERIFIED
  /// until the probe's interaction scenarios run on a real host.
  private func noUI(_ q: inout [String: Any]) {
    q[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail
  }

  private static let interactionLock = NSLock()
  private func quiet(_ body: () -> Int32) -> Int32 {
    if SystemKeychainOps.backend == .dataProtection { return body() }
    SystemKeychainOps.interactionLock.lock()
    defer { SystemKeychainOps.interactionLock.unlock() }
    var previous: DarwinBoolean = true
    guard SecKeychainGetUserInteractionAllowed(&previous) == errSecSuccess else {
      return errSecNotAvailable
    }
    guard SecKeychainSetUserInteractionAllowed(false) == errSecSuccess else {
      return errSecNotAvailable
    }
    let result = body()
    guard SecKeychainSetUserInteractionAllowed(previous.boolValue) == errSecSuccess else {
      // The item operation may have applied. Core treats this as unknown.
      return errSecNotAvailable
    }
    return result
  }

  func add(namespace: String, data: Data) -> Int32 {
    var q = base(namespace)
    q[kSecValueData as String] = data
    if SystemKeychainOps.backend == .dataProtection {
      q[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
    }
    noUI(&q)
    return quiet { SecItemAdd(q as CFDictionary, nil) }
  }

  func copy(namespace: String) -> (status: Int32, data: Data?) {
    var q = base(namespace)
    q[kSecReturnData as String] = true
    q[kSecMatchLimit as String] = kSecMatchLimitOne
    noUI(&q)
    var out: CFTypeRef?
    let st = quiet { SecItemCopyMatching(q as CFDictionary, &out) }
    if st == errSecSuccess { return (st, out as? Data) }
    return (st, nil)
  }

  func delete(namespace: String) -> Int32 {
    var q = base(namespace)
    noUI(&q)
    return quiet { SecItemDelete(q as CFDictionary) }
  }

  func keychainUnlocked() -> Bool? {
    if SystemKeychainOps.backend == .dataProtection { return nil }
    var status: SecKeychainStatus = 0
    if SecKeychainGetStatus(nil, &status) != errSecSuccess { return nil }
    return (status & UInt32(kSecUnlockStateStatus)) != 0
  }
}
