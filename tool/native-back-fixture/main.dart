import 'dart:convert';

import 'dart:typed_data';


import 'package:material_ui/material_ui.dart';
import 'package:otpanda_client/browser_account_page.dart';
import 'package:otpanda_client/native/native_app.dart';
import 'package:otpanda_client/native/native_navigation.dart';
import 'package:otpanda_client/native/native_auth.dart';
import 'package:otpanda_client/native/native_bridge.dart';
import 'package:otpanda_client/native/native_session.dart';
import 'package:otpanda_client/session_contract.dart';

class _Ks implements NativeKeystore {
  @override
  Future<Uint8List> ensureKey() async =>
      Uint8List.fromList([4, ...List.filled(64, 1)]);
  @override
  Future<Uint8List> beginNewKey() => ensureKey();
  @override
  Future<void> commitNewKey() async {}
  @override
  Future<void> discardNewKey() async {}
  @override
  Future<bool> hasPendingKey() async => false;
  @override
  Future<Uint8List> signDer(Uint8List m, {bool pending = false}) async =>
      Uint8List.fromList([0x30, 6, 2, 1, 1, 2, 1, 1]);
  @override
  Future<void> deleteKey() async {}
}

class _St implements NativeSecureStore {
  String? id = 'DEV';
  @override
  Future<String?> readDeviceId() async => id;
  @override
  Future<void> writeDeviceId(String v) async => id = v;
  @override
  Future<void> clear() async => id = null;
}

class _Br implements BrowserHandoff {
  @override
  Future<Uri?> run(Uri u) async => null;
}

class _G implements GoogleIdTokenSource {
  @override
  bool get available => false;
  @override
  Future<String?> idToken({required String nonce}) async => null;
}

void main(){
 final c=NativeSessionController(NativeAuth(post:(p,b)async=>p.endsWith('challenge')?(status:200,body:{'device_id':'DEV','nonce':'n','expires_at':5}):(status:200,body:{'access':'fictional','access_expires_at':DateTime.now().millisecondsSinceEpoch+3600000}),keystore:_Ks(),browser:_Br(),google:_G(),store:_St(),apiOrigin:'https://fixture.invalid',launchUrl:(c,s)=>Uri.parse('https://fixture.invalid')));
 final bridge=NativeSessionBridge(c,(m,path,{body,query,required bearer})async=>SessionResponse(200,jsonEncode(switch(path){
 '/v1/manage/session'=>{'ownerId':'fictional','expiresAt':DateTime.now().millisecondsSinceEpoch+3600000},
 '/v1/manage/account'=>{'email':'fictional@example.invalid','passkeys':[]},
 '/v1/manage/entries'=>{'entries':[]},
 '/v1/manage/active-codes'=>{'records':[]},
 '/v1/manage/sources'=>{'sources':[]},
 '/v1/manage/unassigned'=>{'records':[]},
 _=>{},})),settingsEnabled:true,onLogout:()=>c.signOut());
 runApp(NativeApp(controller:c,googleAvailable:false,authBridge:bridge,signedInBuilder:(context)=>NativeNavigation(builder:(context,route,navigate)=>BrowserAccountPage(bridge:bridge,navigation:route,onNavigate:navigate,accountOnly:true,workspaceEnabled:true,signOutEnabled:true))));
}
