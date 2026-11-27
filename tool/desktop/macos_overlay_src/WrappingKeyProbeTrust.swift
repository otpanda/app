import Foundation
import Security

// PROBE ONLY. Never inlined into the app (macos_overlay.py SOURCES does not list it) and never called from production code.
// Experiment: can the TRUSTED creator of a file-based Keychain item add exactly one more application (a staged next build) to the
// item's decrypt ACL without a prompt or a password? It only ever APPENDS one named binary to a non-empty trusted list; an item whose list is
// nil ("any application") is skipped, never produced. UNCOMPILED: written without a Mac; fix compile errors, do not change what it measures.
enum ProbeTrust {
  static func trust(ns: String, path: String) -> String {
    let wasAllowed = UnsafeMutablePointer<DarwinBoolean>.allocate(capacity: 1)
    wasAllowed.pointee = true
    defer { wasAllowed.deallocate() }
    guard SecKeychainGetUserInteractionAllowed(wasAllowed) == errSecSuccess else { return "err step=interaction-read" }
    guard SecKeychainSetUserInteractionAllowed(false) == errSecSuccess else { return "err step=interaction-disable" }
    let known = true
    defer { if known { _ = SecKeychainSetUserInteractionAllowed(wasAllowed.pointee.boolValue) } }

    let q: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: SystemKeychainOps.service,
      kSecAttrAccount as String: ns,
      kSecReturnRef as String: true,
      kSecMatchLimit as String: kSecMatchLimitOne,
    ]
    var ref: CFTypeRef?
    var st = SecItemCopyMatching(q as CFDictionary, &ref)
    guard st == errSecSuccess, let r = ref else { return "err step=find status=\(st)" }
    let item = r as! SecKeychainItem
    var access: SecAccess?
    st = SecKeychainItemCopyAccess(item, &access)
    guard st == errSecSuccess, let acc = access else { return "err step=copy-access status=\(st)" }
    var app: SecTrustedApplication?
    st = SecTrustedApplicationCreateFromPath(path, &app)
    guard st == errSecSuccess, let newApp = app else { return "err step=trusted-app status=\(st)" }
    guard let acls = SecAccessCopyMatchingACLList(acc, kSecACLAuthorizationDecrypt) as? [SecACL] else { return "err step=acl-list" }
    var changed = 0, anyApp = 0
    for acl in acls {
      var apps: CFArray?
      var desc: CFString?
      var sel = SecKeychainPromptSelector(rawValue: 0)
      guard SecACLCopyContents(acl, &apps, &desc, &sel) == errSecSuccess else { continue }
      guard let list = apps as? [SecTrustedApplication], !list.isEmpty else { anyApp += 1; continue }
      if SecACLSetContents(acl, (list + [newApp]) as CFArray, (desc ?? "otpanda" as CFString), sel) == errSecSuccess { changed += 1 }
    }
    st = SecKeychainItemSetAccess(item, acc)
    return "ok acls=\(acls.count) changed=\(changed) any-app-skipped=\(anyApp) set-access-status=\(st)"
  }
}
