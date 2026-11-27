import Foundation

// Portable core of the macOS wrapping-key store. It talks to the Keychain only
// through KeychainOps, so every outcome mapping can be tested with a fake.
// Statuses are plain Int32 (OSStatus) so this file compiles without Security.

enum KcStatus {
  static let success: Int32 = 0
  static let userCanceled: Int32 = -128
  static let param: Int32 = -50
  static let notAvailable: Int32 = -25291
  static let authFailed: Int32 = -25293
  static let duplicateItem: Int32 = -25299
  static let itemNotFound: Int32 = -25300
  static let interactionNotAllowed: Int32 = -25308
  static let interactionRequired: Int32 = -25315
  static let missingEntitlement: Int32 = -34018
}

enum WrappingKeyErrorKind: String {
  case unavailable, locked, denied, corrupt
}

struct WrappingKeyFailure: Error {
  let kind: WrappingKeyErrorKind
  /// True only for a mutation that may or may not have been applied.
  let outcomeUnknown: Bool
}

protocol KeychainOps {
  func add(namespace: String, data: Data) -> Int32
  func copy(namespace: String) -> (status: Int32, data: Data?)
  func delete(namespace: String) -> Int32
  /// Whether the keychain this backend uses is unlocked. nil when the backend
  /// cannot tell. Used only to tell "locked" apart from "ACL refused".
  func keychainUnlocked() -> Bool?
}

enum WrappingKeyCore {
  static let keyBytes = 32

  static func validName(_ s: String) -> Bool {
    guard !s.isEmpty, s.utf8.count <= 64 else { return false }
    return s.utf8.allSatisfy {
      ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x41 && $0 <= 0x5A) ||
        ($0 >= 0x61 && $0 <= 0x7A) || $0 == 0x5F || $0 == 0x2D
    }
  }

  static func kind(for status: Int32, _ ops: KeychainOps) -> WrappingKeyErrorKind {
    switch status {
    case KcStatus.interactionNotAllowed, KcStatus.interactionRequired:
      // With UI disabled the file-based keychain answers both "keychain is
      // locked" and "this app is not in the item's ACL" with the same status.
      // Locked is retryable after unlock; an ACL refusal is not, so tell
      // them apart. Unknown lock state stays "locked" (the retryable reading).
      return ops.keychainUnlocked() == true ? .denied : .locked
    case KcStatus.authFailed, KcStatus.userCanceled, KcStatus.missingEntitlement:
      return .denied
    default:
      return .unavailable
    }
  }

  /// Statuses the OS returns before touching the store. Anything else from a
  /// mutation is treated as an unknown outcome.
  static func rejectedBeforeWrite(_ status: Int32) -> Bool {
    switch status {
    case KcStatus.interactionNotAllowed, KcStatus.interactionRequired,
         KcStatus.authFailed, KcStatus.userCanceled,
         KcStatus.missingEntitlement, KcStatus.param:
      return true
    default:
      return false
    }
  }

  /// nil only when the Keychain definitely reports the item absent.
  static func read(_ ops: KeychainOps, _ ns: String) throws -> Data? {
    guard validName(ns) else {
      throw WrappingKeyFailure(kind: .unavailable, outcomeUnknown: false)
    }
    let r = ops.copy(namespace: ns)
    switch r.status {
    case KcStatus.success:
      guard let d = r.data, d.count == keyBytes else {
        throw WrappingKeyFailure(kind: .corrupt, outcomeUnknown: false)
      }
      return d
    case KcStatus.itemNotFound:
      return nil
    default:
      throw WrappingKeyFailure(kind: kind(for: r.status, ops), outcomeUnknown: false)
    }
  }

  /// Create-only. Never overwrites, never deletes. Returns the key stored
  /// afterwards and whether this call created it.
  static func create(
    _ ops: KeychainOps, _ ns: String, _ candidate: Data
  ) throws -> (key: Data, created: Bool) {
    guard validName(ns), candidate.count == keyBytes else {
      throw WrappingKeyFailure(kind: .unavailable, outcomeUnknown: false)
    }
    var attempts = 0
    while attempts < 3 {
      attempts += 1
      let st = ops.add(namespace: ns, data: candidate)
      if st == KcStatus.success {
        // Verify by reading back; a vanished or different item is surprising.
        let back: Data?
        do { back = try read(ops, ns) } catch let f as WrappingKeyFailure {
          throw WrappingKeyFailure(kind: f.kind, outcomeUnknown: true)
        }
        guard let key = back else {
          throw WrappingKeyFailure(kind: .unavailable, outcomeUnknown: true)
        }
        return (key, key == candidate)
      }
      if st == KcStatus.duplicateItem {
        // A winner exists (ours from a prior attempt, another process, or a
        // damaged value). Nothing was applied by this call.
        if let key = try read(ops, ns) { return (key, false) }
        continue  // deleted between add and read: try again, bounded
      }
      if rejectedBeforeWrite(st) {
        throw WrappingKeyFailure(kind: kind(for: st, ops), outcomeUnknown: false)
      }
      // Unexpected failure: the add may or may not have landed. Read back.
      let back: Data?
      do { back = try read(ops, ns) } catch let f as WrappingKeyFailure {
        throw WrappingKeyFailure(kind: f.kind, outcomeUnknown: true)
      }
      if let key = back { return (key, key == candidate) }
      throw WrappingKeyFailure(kind: kind(for: st, ops), outcomeUnknown: false)
    }
    throw WrappingKeyFailure(kind: .unavailable, outcomeUnknown: true)
  }

  /// Explicit purge only. Absent is success.
  static func delete(_ ops: KeychainOps, _ ns: String) throws {
    guard validName(ns) else {
      throw WrappingKeyFailure(kind: .unavailable, outcomeUnknown: false)
    }
    let st = ops.delete(namespace: ns)
    if st == KcStatus.success || st == KcStatus.itemNotFound { return }
    throw WrappingKeyFailure(
      kind: kind(for: st, ops), outcomeUnknown: !rejectedBeforeWrite(st))
  }
}
