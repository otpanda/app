import 'browser_session_contract.dart';
import 'browser_session_stub.dart'
    if (dart.library.js_interop) 'browser_session_web.dart'
    as platform;

BrowserSessionBridge createBrowserSession() => platform.createBrowserSession();
