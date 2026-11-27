import Cocoa
import FlutterMacOS

/// MethodChannel "app.otpanda/wrapping-key". Same wire contract as the Windows
/// overlay: wrappingKeyRead -> {key: bytes|null}; wrappingKeyCreate ->
/// {key, created}; wrappingKeyDelete -> {}. Errors carry code
/// unavailable|locked|denied|corrupt and details {outcomeUnknown: bool}.
enum OtpandaWrappingKeyChannel {
  private static let queue = DispatchQueue(label: "app.otpanda.wrapping-key")
  private static var channel: FlutterMethodChannel?

  static func register(_ messenger: FlutterBinaryMessenger) {
    let ch = FlutterMethodChannel(
      name: "app.otpanda/wrapping-key", binaryMessenger: messenger)
    ch.setMethodCallHandler { call, result in
      handle(call, SystemKeychainOps(), result)
    }
    channel = ch
  }

  static func handle(
    _ call: FlutterMethodCall, _ ops: KeychainOps, _ result: @escaping FlutterResult
  ) {
    let args = call.arguments as? [String: Any]
    let ns = args?["namespace"] as? String
    let key = (args?["key"] as? FlutterStandardTypedData)?.data
    let method = call.method
    // Keychain calls can block (locked store), so never run them on the
    // platform thread. Replies go back on the main thread.
    queue.async {
      let reply: Any
      do {
        guard let ns = ns else {
          throw WrappingKeyFailure(kind: .unavailable, outcomeUnknown: false)
        }
        switch method {
        case "wrappingKeyRead":
          let k = try WrappingKeyCore.read(ops, ns)
          let v: Any
          if let k = k { v = FlutterStandardTypedData(bytes: k) } else { v = NSNull() }
          reply = ["key": v]
        case "wrappingKeyCreate":
          guard let key = key else {
            throw WrappingKeyFailure(kind: .unavailable, outcomeUnknown: false)
          }
          let r = try WrappingKeyCore.create(ops, ns, key)
          reply = ["key": FlutterStandardTypedData(bytes: r.key), "created": r.created]
        case "wrappingKeyDelete":
          try WrappingKeyCore.delete(ops, ns)
          reply = [String: Any]()
        default:
          DispatchQueue.main.async { result(FlutterMethodNotImplemented) }
          return
        }
        DispatchQueue.main.async { result(reply) }
      } catch let f as WrappingKeyFailure {
        let e = FlutterError(
          code: f.kind.rawValue, message: nil,
          details: ["outcomeUnknown": f.outcomeUnknown])
        DispatchQueue.main.async { result(e) }
      } catch {
        let e = FlutterError(
          code: "unavailable", message: nil, details: ["outcomeUnknown": true])
        DispatchQueue.main.async { result(e) }
      }
    }
  }
}
