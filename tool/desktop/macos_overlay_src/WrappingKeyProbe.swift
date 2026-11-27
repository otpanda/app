import Foundation

// Real-Keychain probe driver. Built and driven by tool/desktop/macos_keychain_probe.sh
// on a macOS host. Usage: probe <read|create|delete> <namespace> [byte]
// Prints one line: "ok key=<hex|none> created=<bool|-> marker=<m>" or
// "err kind=<k> unknown=<bool> marker=<m>". Never prints more than the key's
// first 4 bytes' worth of identity: the probe key is a throwaway test value.

@main
struct Probe {
  static func hex(_ d: Data?) -> String {
    guard let d = d else { return "none" }
    return d.prefix(4).map { String(format: "%02x", $0) }.joined() + "/\(d.count)"
  }

  static func main() {
    let a = CommandLine.arguments
    guard a.count >= 3 else { print("usage"); exit(2) }
    let ops = SystemKeychainOps()
    do {
      switch a[1] {
      case "read":
        let k = try WrappingKeyCore.read(ops, a[2])
        print("ok key=\(hex(k)) created=- marker=\(probeMarker)")
      case "create":
        let b = UInt8(a.count > 3 ? a[3] : "1", radix: 16) ?? 1
        let r = try WrappingKeyCore.create(ops, a[2], Data(repeating: b, count: 32))
        print("ok key=\(hex(r.key)) created=\(r.created) marker=\(probeMarker)")
      case "delete":
        try WrappingKeyCore.delete(ops, a[2])
        print("ok key=none created=- marker=\(probeMarker)")
      default:
        print("usage"); exit(2)
      }
    } catch let f as WrappingKeyFailure {
      print("err kind=\(f.kind.rawValue) unknown=\(f.outcomeUnknown) marker=\(probeMarker)")
    } catch {
      print("err kind=other unknown=true marker=\(probeMarker)")
    }
  }
}
