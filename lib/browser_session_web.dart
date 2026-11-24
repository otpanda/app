import 'dart:js_interop';

import 'browser_session_contract.dart';
import 'session_contract.dart';

@JS('OTPandaSession')
external _Session get _session;

extension type _Session(JSObject _) implements JSObject {
  external JSPromise<JSString> assignmentPrepare(JSString target);
  external JSPromise<JSString> assignmentConfirm();
  external JSPromise<JSString> assignmentReconcile();
  external JSString assignmentState();
  external void assignmentDismiss();
  external JSPromise<JSAny?> get ready;
  external JSString status();
  external JSString email();
  external JSString pendingLabel();
  external JSPromise<JSString> protectionContinue(JSString action);
  external JSPromise<JSString> security(
    JSString action,
    JSBoolean enabled,
    JSString pendingId,
  );
  external JSPromise<JSAny?> googleContinue(JSString action, JSString proof);
  external JSPromise<JSAny?> googleStart(JSBoolean remember);
  external JSBoolean firstPasskeyAvailable();
  external JSPromise<JSAny?> firstPasskey();
  external JSPromise<JSAny?> addPasskey();
  external JSPromise<JSAny?> signupEmail(JSString email, JSString proof);
  external JSPromise<JSAny?> start(JSString mode);
  external JSPromise<JSAny?> passkey();
  external void clear();
  external void logout();
  external JSPromise<_ReadResponse> read(JSString path);
  external JSPromise<_ReadResponse> organize(JSString method, JSString body);
  external JSPromise<_ReadResponse> copied(
    JSString entryId,
    JSNumber createdAt,
  );
}

extension type _ReadResponse(JSObject _) implements JSObject {
  external JSNumber get status;
  external JSString get body;
}

BrowserSessionBridge createBrowserSession() => _Browser();

class _Browser
    implements
        BrowserSessionBridge,
        AssignmentBridge,
        AuthEntryBridge,
        FirstPasskeyBridge,
        AdditionalPasskeyBridge {
  @override
  Future<void> addPasskey() async {
    await _session.addPasskey().toDart;
  }

  @override
  bool get firstPasskeyAvailable => _session.firstPasskeyAvailable().toDart;
  @override
  Future<void> firstPasskey() async {
    await _session.firstPasskey().toDart;
  }

  @override
  Future<void> googleContinue(String action, [String proof = '']) async {
    await _session.googleContinue(action.toJS, proof.toJS).toDart;
  }

  @override
  Future<void> googleStart(bool remember) async {
    await _session.googleStart(remember.toJS).toDart;
  }

  @override
  Future<String> protectionContinue(String action) async =>
      (await _session.protectionContinue(action.toJS).toDart).toDart;
  @override
  Future<String> security(
    String action, [
    bool enabled = false,
    String pendingId = '',
  ]) async =>
      (await _session
              .security(action.toJS, enabled.toJS, pendingId.toJS)
              .toDart)
          .toDart;
  @override
  String get pendingLabel => _session.pendingLabel().toDart;
  @override
  String get email => _session.email().toDart;
  @override
  Future<void> signupEmail(String email, [String proof = '']) async {
    await _session.signupEmail(email.toJS, proof.toJS).toDart;
  }

  @override
  Future<String> assignmentPrepare(String target) async =>
      (await _session.assignmentPrepare(target.toJS).toDart).toDart;
  @override
  Future<String> assignmentConfirm() async =>
      (await _session.assignmentConfirm().toDart).toDart;
  @override
  Future<String> assignmentReconcile() async =>
      (await _session.assignmentReconcile().toDart).toDart;
  @override
  String get assignmentState => _session.assignmentState().toDart;
  @override
  void assignmentDismiss() => _session.assignmentDismiss();
  @override
  Future<void> get ready async {
    await _session.ready.toDart;
  }

  @override
  String get status => _session.status().toDart;
  @override
  Future<void> start(String mode) async {
    await _session.start(mode.toJS).toDart;
  }

  @override
  Future<void> passkey() async {
    await _session.passkey().toDart;
  }

  @override
  void clear() => _session.clear();
  @override
  void logout() => _session.logout();
  @override
  Future<SessionResponse> organize(String method, String body) async {
    final r = await _session.organize(method.toJS, body.toJS).toDart;
    return SessionResponse(r.status.toDartInt, r.body.toDart);
  }

  @override
  Future<SessionResponse> copied(String entryId, int createdAt) async {
    final r = await _session.copied(entryId.toJS, createdAt.toJS).toDart;
    return SessionResponse(r.status.toDartInt, r.body.toDart);
  }

  @override
  Future<SessionResponse> read(String path) async {
    final response = await _session.read(path.toJS).toDart;
    return SessionResponse(response.status.toDartInt, response.body.toDart);
  }
        }
