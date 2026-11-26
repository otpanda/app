import '../recovery_contract.dart';
import 'native_auth.dart' show BrowserHandoff;
import 'native_handoff.dart';
import 'native_manage_settings.dart';

/// Signed-in "Connect Google": ticket, Custom Tab to Google, App Link back,
/// then the owner's OS passkey step-up links the identity. No session is
/// issued. Contract: native-settings-parity-CONTRACT-ef156abe. Results use
/// the web bridge's codes (connected, restart, cancelled) plus unconfirmed.
/// The page claims success only when the live overview shows Google linked.
///
/// NOT ACTIVE: needs the API's fixed /app-return (chosen by the server for a
/// ticket-bound android session) deployed, plus link/begin and link/finish.
/// A return with link=mismatch or link=restart parses as no link: 'restart'.
class NativeGoogleConnect {
  NativeGoogleConnect({
    required this.settings,
    required this.browser,
    required this.apiOrigin,
    int Function()? nowMs,
    String Function()? newState,
    String? returnOrigin,
    this.returnPath = '/app-return',
  }) : returnOrigin = returnOrigin ?? apiOrigin,
       _now = nowMs ?? (() => DateTime.now().millisecondsSinceEpoch),
       _state = newState ?? generateState;

  final NativeManageSettings settings;
  final BrowserHandoff browser;
  final String apiOrigin, returnOrigin, returnPath;
  final int Function() _now;
  final String Function() _state;
  String _result = '';
  bool _running = false;

  String takeResult() {
    final r = _result;
    _result = '';
    return r;
  }

  /// Empty is never returned here: the flow finishes in this call. Early
  /// refusals give a reason code (already_linked, no_passkey, retry, signin,
  /// unavailable). Otherwise 'completed' and [takeResult] holds the outcome.
  Future<String> connect() async {
    if (_running) return 'unavailable';
    _running = true;
    try {
      final state = _state();
      final String ticket;
      try {
        ticket = await settings.googleLinkTicket(state);
      } on ManageFailure catch (e) {
        if (e.status == 429) return 'retry';
        if (e.status == 401 || e.status == 403) return 'signin';
        if (e.status == 409 && e.error == 'no_passkey') return 'no_passkey';
        if (e.status == 409 && e.error == 'already_linked') {
          return 'already_linked';
        }
        return 'unavailable';
      } catch (_) {
        return 'unavailable';
      }
      final url = Uri.parse(apiOrigin).replace(
        path: '/auth/google/link/start',
        queryParameters: {'ticket': ticket},
      );
      final created = _now();
      final back = await browser.run(url);
      if (back == null) {
        _result = 'cancelled';
        return 'completed';
      }
      final link = parseGoogleLinkReturn(
        back,
        expectedState: state,
        nowMs: _now(),
        origin: returnOrigin,
        path: returnPath,
      );
      if (link == null || _now() - created > 600000) {
        _result = 'restart';
        return 'completed';
      }
      try {
        await settings.googleLinkFinish(link.token);
        _result = 'connected';
      } on ManageDismissed {
        _result = 'cancelled';
      } on RecoveryOutcomeUnknown {
        // Unknown: the page says "connected" only if the live overview shows
        // it, otherwise that it could not confirm.
        _result = 'unconfirmed';
      } catch (_) {
        _result = 'restart';
      }
      return 'completed';
    } finally {
      _running = false;
    }
  }
}
