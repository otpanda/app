import Foundation

// Build and run on a machine with a Swift toolchain (macOS CI runner):
//   swiftc -parse-as-library WrappingKeyCore.swift WrappingKeyCoreTests.swift -o wk_tests && ./wk_tests
// Exit code is non-zero on any failure.

final class FakeKeychain: KeychainOps {
  private let lock = NSLock()
  var items: [String: Data] = [:]
  var corruptCopyStatusSuccessNilData = false
  var addOverride: Int32? = nil        // returned instead of calling the store
  var addAppliesAnyway = false         // store the item, then return override
  var copyOverride: Int32? = nil
  var copyOverrideAfterNAdds: Int? = nil
  var deleteOverride: Int32? = nil
  var deleteAppliesAnyway = false
  var vanishOnNextCopyAfterDuplicate = false
  var unlocked: Bool? = nil
  private var adds = 0
  private var sawDuplicate = false

  func add(namespace: String, data: Data) -> Int32 {
    lock.lock(); defer { lock.unlock() }
    adds += 1
    if let o = addOverride {
      if addAppliesAnyway && items[namespace] == nil { items[namespace] = data }
      return o
    }
    if items[namespace] != nil { sawDuplicate = true; return KcStatus.duplicateItem }
    items[namespace] = data
    return KcStatus.success
  }

  func copy(namespace: String) -> (status: Int32, data: Data?) {
    lock.lock(); defer { lock.unlock() }
    if let o = copyOverride { return (o, nil) }
    if vanishOnNextCopyAfterDuplicate && sawDuplicate {
      vanishOnNextCopyAfterDuplicate = false
      items[namespace] = nil
      return (KcStatus.itemNotFound, nil)
    }
    if corruptCopyStatusSuccessNilData { return (KcStatus.success, nil) }
    guard let d = items[namespace] else { return (KcStatus.itemNotFound, nil) }
    return (KcStatus.success, d)
  }

  func keychainUnlocked() -> Bool? { unlocked }

  func delete(namespace: String) -> Int32 {
    lock.lock(); defer { lock.unlock() }
    if let o = deleteOverride {
      if deleteAppliesAnyway { items[namespace] = nil }
      return o
    }
    if items.removeValue(forKey: namespace) == nil { return KcStatus.itemNotFound }
    return KcStatus.success
  }
}

var failures = 0
func check(_ cond: Bool, _ name: String) {
  if !cond { failures += 1; print("FAIL: \(name)") } else { print("ok:   \(name)") }
}
func key(_ b: UInt8) -> Data { Data(repeating: b, count: 32) }
func failure(_ body: () throws -> Void) -> WrappingKeyFailure? {
  do { try body(); return nil } catch let f as WrappingKeyFailure { return f } catch { return nil }
}

@main
struct Tests {
  static func main() {
    let ns = "install-1"

    do {
      let k = FakeKeychain()
      let absent = try! WrappingKeyCore.read(k, ns)
      check(absent == nil, "read absent returns nil")
      let r = try! WrappingKeyCore.create(k, ns, key(1))
      check(r.key == key(1) && r.created, "create stores and reports created")
      check(try! WrappingKeyCore.read(k, ns) == key(1), "read returns stored key")
      let r2 = try! WrappingKeyCore.create(k, ns, key(2))
      check(r2.key == key(1) && !r2.created && k.items[ns] == key(1),
            "duplicate create returns winner and never overwrites")
    }
    do {
      let k = FakeKeychain(); k.items[ns] = Data(repeating: 7, count: 31)
      let f = failure { _ = try WrappingKeyCore.read(k, ns) }
      check(f?.kind == .corrupt && f?.outcomeUnknown == false, "wrong-size item is corrupt, not absent")
      let g = failure { _ = try WrappingKeyCore.create(k, ns, key(1)) }
      check(g?.kind == .corrupt && k.items[ns]?.count == 31, "create over corrupt throws and keeps the value")
      let k2 = FakeKeychain(); k2.corruptCopyStatusSuccessNilData = true
      check(failure { _ = try WrappingKeyCore.read(k2, ns) }?.kind == .corrupt, "success with no data is corrupt")
    }
    do {
      let k = FakeKeychain(); k.copyOverride = KcStatus.interactionNotAllowed
      check(failure { _ = try WrappingKeyCore.read(k, ns) }?.kind == .locked, "locked read maps to locked")
      let k2 = FakeKeychain(); k2.copyOverride = KcStatus.missingEntitlement
      check(failure { _ = try WrappingKeyCore.read(k2, ns) }?.kind == .denied, "missing entitlement maps to denied")
      let kl = FakeKeychain(); kl.copyOverride = KcStatus.interactionNotAllowed; kl.unlocked = false
      check(failure { _ = try WrappingKeyCore.read(kl, ns) }?.kind == .locked, "no-UI refusal while keychain locked is locked")
      let ka = FakeKeychain(); ka.copyOverride = KcStatus.interactionNotAllowed; ka.unlocked = true
      check(failure { _ = try WrappingKeyCore.read(ka, ns) }?.kind == .denied, "no-UI refusal while unlocked is denied (ACL), not locked")
      let kc = FakeKeychain(); kc.addOverride = KcStatus.interactionNotAllowed; kc.unlocked = true
      let fc = failure { _ = try WrappingKeyCore.create(kc, ns, key(1)) }
      check(fc?.kind == .denied && fc?.outcomeUnknown == false, "create ACL refusal is denied, known not applied")
      let kd = FakeKeychain(); kd.deleteOverride = KcStatus.interactionNotAllowed; kd.unlocked = true; kd.items[ns] = key(1)
      check(failure { try WrappingKeyCore.delete(kd, ns) }?.kind == .denied && kd.items[ns] != nil, "delete ACL refusal is denied and keeps the item")
      let k3 = FakeKeychain(); k3.copyOverride = -99999
      let f = failure { _ = try WrappingKeyCore.read(k3, ns) }
      check(f?.kind == .unavailable && f?.outcomeUnknown == false, "unknown read status is unavailable, never absent")
    }
    do {
      let k = FakeKeychain(); k.addOverride = KcStatus.interactionNotAllowed
      let f = failure { _ = try WrappingKeyCore.create(k, ns, key(1)) }
      check(f?.kind == .locked && f?.outcomeUnknown == false && k.items.isEmpty, "locked create is known not applied")
      let k2 = FakeKeychain(); k2.addOverride = KcStatus.missingEntitlement
      let g = failure { _ = try WrappingKeyCore.create(k2, ns, key(1)) }
      check(g?.kind == .denied && g?.outcomeUnknown == false, "entitlement failure on create is denied, known not applied")
    }
    do {
      let k = FakeKeychain(); k.addOverride = -99999; k.addAppliesAnyway = true
      let r = try? WrappingKeyCore.create(k, ns, key(1))
      check(r?.key == key(1), "add failed after landing: read-back returns stored key")
      let k2 = FakeKeychain(); k2.addOverride = -99999
      let f = failure { _ = try WrappingKeyCore.create(k2, ns, key(1)) }
      check(f?.kind == .unavailable && f?.outcomeUnknown == false, "unexpected add failure with absent read-back is known not applied")
      let k3 = FakeKeychain(); k3.addOverride = -99999; k3.copyOverride = KcStatus.interactionNotAllowed
      let h = failure { _ = try WrappingKeyCore.create(k3, ns, key(1)) }
      check(h?.kind == .locked && h?.outcomeUnknown == true, "unexpected add failure with unreadable store is outcomeUnknown")
    }
    do {
      let k = FakeKeychain(); k.items[ns] = key(1); k.vanishOnNextCopyAfterDuplicate = true
      let r = try? WrappingKeyCore.create(k, ns, key(2))
      check(r?.key == key(2) && r?.created == true, "winner deleted between add and read: bounded retry creates")
    }
    do {
      let k = FakeKeychain()
      check(failure { try WrappingKeyCore.delete(k, ns) } == nil, "delete absent succeeds")
      k.items[ns] = key(1)
      check(failure { try WrappingKeyCore.delete(k, ns) } == nil && k.items.isEmpty, "delete removes")
      let k2 = FakeKeychain(); k2.deleteOverride = KcStatus.interactionNotAllowed; k2.items[ns] = key(1)
      let f = failure { try WrappingKeyCore.delete(k2, ns) }
      check(f?.kind == .locked && f?.outcomeUnknown == false && k2.items[ns] != nil, "locked delete is known not applied")
      let k3 = FakeKeychain(); k3.deleteOverride = -99999; k3.deleteAppliesAnyway = true; k3.items[ns] = key(1)
      let g = failure { try WrappingKeyCore.delete(k3, ns) }
      check(g?.kind == .unavailable && g?.outcomeUnknown == true, "unexpected delete failure is outcomeUnknown")
    }
    do {
      let k = FakeKeychain()
      check(failure { _ = try WrappingKeyCore.read(k, "bad name!") }?.kind == .unavailable, "invalid namespace rejected")
      check(failure { _ = try WrappingKeyCore.create(k, ns, Data(count: 16)) }?.kind == .unavailable, "wrong-size candidate rejected")
      check(failure { _ = try WrappingKeyCore.create(k, ns, key(1)) } == nil && !WrappingKeyCore.validName(String(repeating: "a", count: 65)), "65-char name invalid")
    }
    do {
      let k = FakeKeychain()
      let group = DispatchGroup()
      let outLock = NSLock()
      var seen = Set<Data>()
      for i in 0..<16 {
        group.enter()
        DispatchQueue.global().async {
          if let r = try? WrappingKeyCore.create(k, "race", key(UInt8(i + 1))) {
            outLock.lock(); seen.insert(r.key); outLock.unlock()
          }
          group.leave()
        }
      }
      group.wait()
      check(seen.count == 1 && seen.first == k.items["race"], "concurrent creates converge on one key")
    }
    print(failures == 0 ? "ALL PASSED" : "\(failures) FAILED")
    exit(failures == 0 ? 0 : 1)
  }
}
