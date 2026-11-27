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
  /// can hang a headless or backgrounded app. The call fails instead.
  private func noUI(_ q: inout [String: Any]) {
    q[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail
  }

  func add(namespace: String, data: Data) -> Int32 {
    var q = base(namespace)
    q[kSecValueData as String] = data
    if SystemKeychainOps.backend == .dataProtection {
      q[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
    }
    noUI(&q)
    return SecItemAdd(q as CFDictionary, nil)
  }

  func copy(namespace: String) -> (status: Int32, data: Data?) {
    var q = base(namespace)
    q[kSecReturnData as String] = true
    q[kSecMatchLimit as String] = kSecMatchLimitOne
    noUI(&q)
    var out: CFTypeRef?
    let st = SecItemCopyMatching(q as CFDictionary, &out)
    if st == errSecSuccess { return (st, out as? Data) }
    return (st, nil)
  }

  func delete(namespace: String) -> Int32 {
    var q = base(namespace)
    noUI(&q)
    return SecItemDelete(q as CFDictionary)
  }

  func keychainUnlocked() -> Bool? {
    if SystemKeychainOps.backend == .dataProtection { return nil }
    var status: SecKeychainStatus = 0
    if SecKeychainGetStatus(nil, &status) != errSecSuccess { return nil }
    return (status & UInt32(kSecUnlockStateStatus)) != 0
  }
}
