import 'dart:convert';
import 'dart:js_interop';

import 'browser_session_contract.dart';
import 'extension_connect.dart';
import 'extension_popup.dart';
import 'google_link.dart';
import 'gmail_source.dart';
import 'recovery_contract.dart';
import 'profile_cache.dart';
import 'session_contract.dart';

@JS('OTPandaSession')
external _Session get _session;

extension type _Recovery(JSObject _) implements JSObject {
  external JSPromise<JSString> status();
  external JSPromise<JSString> change(
    JSString kind,
    JSString target,
    JSBoolean warningAccepted,
  );
  external JSPromise<JSString> cancelRequest(JSString requestId);
  external JSPromise<JSString> renamePasskey(JSString id, JSString? label);
  external JSPromise<JSAny?> start(JSString email);
  external JSPromise<JSNumber> verify(JSString email, JSString code);
  external JSPromise<JSAny?> sendCompletionCode(JSString email);
  external JSPromise<JSString> complete(JSString email, JSString code);
}

extension type _Session(JSObject _) implements JSObject {
  external _Recovery? get recovery;
  external JSPromise<JSString> entryEdit(
    JSString kind,
    JSString entryId,
    JSString value, [
    JSBoolean? clear,
  ]);
  external JSPromise<JSString> assignmentPrepare(JSString target);
  external JSPromise<JSString> assignmentConfirm();
  external JSPromise<JSString> assignmentReconcile();
  external JSString assignmentState();
  external void assignmentDismiss();
  external JSPromise<JSAny?> get ready;
  external JSString status();
  external JSNumber view();
  external JSPromise<JSAny?> maintain();
  external JSNumber accessExpiresAt();
  external JSFunction realtimeSubscribe(JSFunction listener);
  external void setView(JSNumber view);
  external JSString email();
  external JSString pendingLabel();
  external JSFunction protectionWatch(JSFunction listener);
  external JSPromise<JSString> protectionContinue(JSString action);
  external JSPromise<JSString> security(
    JSString action,
    JSBoolean enabled,
    JSString pendingId,
  );
  external JSPromise<JSAny?> googleContinue(JSString action, JSString proof);
  external JSPromise<JSAny?> googleStart(JSBoolean remember);
  external JSPromise<JSAny?> waitForAuthNavigation();
  external JSPromise<JSString> connectGoogle();
  external JSString googleLinkResult();
  external JSString extensionIntent();
  external JSPromise<JSString> extensionConnect();
  external void extensionCancel();
  external JSFunction? get extensionPopup;
  external JSBoolean firstPasskeyAvailable();
  external JSPromise<JSAny?> firstPasskey();
  external JSPromise<JSAny?> addPasskey();
  external JSPromise<JSAny?> signupEmail(JSString email, JSString proof);
  external JSPromise<JSAny?> start(JSString mode);
  external JSPromise<JSAny?> passkey();
  external JSString profileRead(JSString ownerId, JSString sessionId);
  external void profileWrite(
    JSString ownerId,
    JSString sessionId,
    JSString email,
    JSString? picture,
  );
  external void profileClear();
  external JSBoolean profileRevoked();
  external void onProfileRevoked(JSFunction listener);
  external void clear();
  external void logout();
  external JSPromise<_ReadResponse> gmailSourceStatus();
  external JSPromise<JSAny?> connectGmail();
  external JSPromise<JSString> takeGmailResult();
  external JSPromise<JSString> disconnectGmail(JSString sourceId);
  external JSPromise<JSString> addTotp(
    JSString label,
    JSString account,
    JSString secret, [
    JSString? catalogId,
  ]);
  external JSPromise<_ReadResponse> totpCode(JSString entryId);
  external JSPromise<_ReadResponse> read(JSString path);
  external JSPromise<_ReadResponse> organize(JSString method, JSString body);
  external JSPromise<_ReadResponse> copied(
    JSString entryId,
    JSNumber createdAt,
  );
}

extension type _ReadResponse(JSObject _) implements JSObject {
  external JSNumber? get retryAfterSeconds;
  external JSNumber get status;
  external JSString get body;
}

BrowserSessionBridge createBrowserSession() => _Browser();

class _Browser
    implements
        BrowserSessionBridge,
        SessionViewBridge,
        SessionContinuityBridge,
        RealtimeBridge,
        ProtectionWatchBridge,
        AssignmentBridge,
        EntryManagementBridge,
        AuthEntryBridge,
        FirstPasskeyBridge,
        AdditionalPasskeyBridge,
        RecoveryBridge,
        PasskeyLabelBridge,
        ProfileCacheBridge,
        TotpManagementBridge,
        GmailSourceBridge,
        GoogleLinkBridge,
        GoogleConnectBridge,
        ExtensionConnectBridge,
        ExtensionPopupBridge {
  @override
  bool get extensionPopup => _session.extensionPopup != null;
  @override
  String get extensionIntent => _session.extensionIntent().toDart;
  @override
  Future<String> connectExtension() async =>
      (await _session.extensionConnect().toDart).toDart;
  @override
  void cancelExtension() => _session.extensionCancel();
  @override
  bool get googleConnectAvailable => true;
  @override
  Future<String> connectGoogle() async =>
      (await _session.connectGoogle().toDart).toDart;
  @override
  String takeGoogleLinkResult() => _session.googleLinkResult().toDart;
  @override
  bool get googleDisconnectAvailable => recoveryAvailable;
  @override
  Future<void> disconnectGoogle() =>
      recoveryChange(const RecoveryChange(RecoveryKind.googleUnlink));

  @override
  Future<SessionResponse> gmailSourceStatus() async {
    final r = await _session.gmailSourceStatus().toDart;
    return SessionResponse(r.status.toDartInt, r.body.toDart);
  }

  @override
  Future<void> connectGmail() async {
    await _session.connectGmail().toDart;
  }

  @override
  Future<String> takeGmailResult() async =>
      (await _session.takeGmailResult().toDart).toDart;

  @override
  Future<GmailDisconnectResult> disconnectGmail(String id) async =>
      GmailDisconnectResult.fromJson(
        (await _session.disconnectGmail(id.toJS).toDart).toDart,
      );

  @override
  Future<String> addTotp(
    String label,
    String account,
    String secret, {
    String? catalogId,
  }) async =>
      (await (catalogId == null
                  ? _session.addTotp(label.toJS, account.toJS, secret.toJS)
                  : _session.addTotp(
                      label.toJS,
                      account.toJS,
                      secret.toJS,
                      catalogId.toJS,
                    ))
              .toDart)
          .toDart;
  @override
  String profileRead(String ownerId, String sessionId) =>
      _session.profileRead(ownerId.toJS, sessionId.toJS).toDart;
  @override
  void profileWrite(
    String ownerId,
    String sessionId,
    String email,
    String? picture,
  ) => _session.profileWrite(
    ownerId.toJS,
    sessionId.toJS,
    email.toJS,
    picture?.toJS,
  );
  @override
  void profileClear() => _session.profileClear();
  @override
  bool get profileRevoked => _session.profileRevoked().toDart;
  @override
  void onProfileRevoked(void Function() listener) =>
      _session.onProfileRevoked(listener.toJS);

  @override
  Future<SessionResponse> totpCode(String entryId) async {
    final r = await _session.totpCode(entryId.toJS).toDart;
    return SessionResponse(r.status.toDartInt, r.body.toDart);
  }

  @override
  Future<void> maintain() async {
    await _session.maintain().toDart;
  }

  @override
  int get accessExpiresAt => _session.accessExpiresAt().toDartInt;
  @override
  void Function() realtimeSubscribe(void Function(String reason) listener) {
    try {
      final stop = _session.realtimeSubscribe(
        ((JSString reason) => listener(reason.toDart)).toJS,
      );
      return () => stop.callAsFunction();
    } catch (_) {
      // Older bootstrap without the realtime client: nothing to subscribe to.
      return () {};
    }
  }

  @override
  int get restoredView => _session.view().toDartInt;
  @override
  void setView(int view) => _session.setView(view.toJS);

  void _outcome(String v) {
    if (v == 'ok') return;
    throw v == 'refused'
        ? const RecoveryRefused()
        : const RecoveryOutcomeUnknown();
  }

  _Recovery get _rec =>
      _session.recovery ?? (throw StateError('Recovery unavailable'));
  @override
  bool get recoveryAvailable => _session.recovery != null;
  @override
  bool get enrolledClientApprovalAvailable => false;
  @override
  Future<RecoveryStatus> recoveryStatus() async =>
      RecoveryStatus.fromJson(jsonDecode((await _rec.status().toDart).toDart));
  @override
  Future<void> recoveryChange(RecoveryChange c) async {
    _outcome(
      (await _rec
              .change(
                c.kind.wire.toJS,
                (c.target ?? '').toJS,
                c.warningAccepted.toJS,
              )
              .toDart)
          .toDart,
    );
  }

  @override
  Future<void> renamePasskey(String credentialId, String? label) async {
    _outcome(
      (await _rec.renamePasskey(credentialId.toJS, label?.toJS).toDart).toDart,
    );
  }

  @override
  Future<void> recoveryCancelRequest(String requestId) async {
    _outcome((await _rec.cancelRequest(requestId.toJS).toDart).toDart);
  }

  @override
  Future<void> emailRecoveryStart(String email) async {
    await _rec.start(email.toJS).toDart;
  }

  @override
  Future<DateTime> emailRecoveryVerify(String email, String code) async {
    final at = (await _rec.verify(email.toJS, code.toJS).toDart).toDartInt;
    return DateTime.fromMillisecondsSinceEpoch(at);
  }

  @override
  Future<void> emailRecoverySendCompletionCode(String email) async {
    await _rec.sendCompletionCode(email.toJS).toDart;
  }

  @override
  Future<void> emailRecoveryComplete(String email, String code) async {
    _outcome((await _rec.complete(email.toJS, code.toJS).toDart).toDart);
  }

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
    await _session.waitForAuthNavigation().toDart;
  }

  @override
  void Function() protectionWatch(void Function(String reason) listener) {
    try {
      final stop = _session.protectionWatch(
        ((JSString reason) => listener(reason.toDart)).toJS,
      );
      return () => stop.callAsFunction();
    } catch (_) {
      // Older bootstrap without the watcher: the manual button still works.
      return () {};
    }
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
  Future<void> renameEntry(String entryId, String label) async {
    if ((await _session
                .entryEdit('rename'.toJS, entryId.toJS, label.toJS)
                .toDart)
            .toDart !=
        'ok') {
      throw StateError('Not confirmed');
    }
  }

  @override
  Future<void> updateAccount(String entryId, String? account) async {
    if ((await _session
                .entryEdit(
                  'account'.toJS,
                  entryId.toJS,
                  (account ?? '').toJS,
                  (account == null).toJS,
                )
                .toDart)
            .toDart !=
        'ok') {
      throw StateError('Not confirmed');
    }
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
    // Every non-restore start is an API navigation, not an in-place ceremony.
    if (mode != 'restore') await _session.waitForAuthNavigation().toDart;
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
    return SessionResponse(
      response.status.toDartInt,
      response.body.toDart,
      retryAfterSeconds: response.retryAfterSeconds?.toDartInt,
    );
  }
}
