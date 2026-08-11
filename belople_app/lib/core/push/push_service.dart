import 'dart:async';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../network/api_client.dart';
import '../router/app_router.dart';

/// Handles a message that arrives while the app is fully terminated. Must be a
/// top-level function — Android spins up a separate isolate for it, so anything
/// captured from the UI isolate simply isn't there. We only need Firebase up;
/// the system draws the tray notification from the message's own `notification`
/// block without us doing anything.
@pragma('vm:entry-point')
Future<void> firebaseBackgroundHandler(RemoteMessage message) async {
  await Firebase.initializeApp();
}

/// Registers this device with FCM and hands the token to the backend, which
/// stores it against the signed-in user (see /api/push/device) and uses it to
/// deliver likes/comments/follows/messages while the app is closed.
///
/// Everything here is best-effort: a phone with no Play Services, a denied
/// permission, or a failed registration must never stop the app from running.
class PushService {
  PushService(this._ref);
  final Ref _ref;

  StreamSubscription<String>? _refreshSub;
  StreamSubscription<RemoteMessage>? _openedSub;
  String? _lastSentToken;

  /// Called once after Firebase.initializeApp() and again whenever the signed-in
  /// user changes, since a token is only useful once it's tied to an account.
  Future<void> start() async {
    try {
      final messaging = FirebaseMessaging.instance;

      // Android 13+ shows the system permission sheet here. Declining is a
      // normal outcome, not an error — we just never get a token to send.
      final settings = await messaging.requestPermission();
      if (settings.authorizationStatus == AuthorizationStatus.denied) return;

      await _sendToken(await messaging.getToken());

      // FCM rotates tokens (app restore, reinstall, clearing storage). A stale
      // token silently stops delivering, so re-register whenever it changes.
      _refreshSub ??= messaging.onTokenRefresh.listen(_sendToken);

      // Notification tapped while the app was in the background.
      _openedSub ??= FirebaseMessaging.onMessageOpenedApp.listen(_openFromMessage);

      // …or tapped while the app was terminated: the launch message is only
      // available once, right here.
      final initial = await messaging.getInitialMessage();
      if (initial != null) _openFromMessage(initial);
    } catch (e) {
      debugPrint('Push registration skipped: $e');
    }
  }

  Future<void> _sendToken(String? token) async {
    if (token == null || token.isEmpty || token == _lastSentToken) return;
    try {
      await _ref.read(dioProvider).post('/push/device', data: {
        'token': token,
        'platform': defaultTargetPlatform == TargetPlatform.iOS ? 'ios' : 'android',
      });
      _lastSentToken = token;
    } catch (e) {
      // Not signed in yet (401) is the common case — start() runs again after
      // login, and onTokenRefresh keeps trying.
      debugPrint('Push token not registered: $e');
    }
  }

  /// Routes a tapped notification to the thing it's about. The Worker puts a
  /// ready-made app path in `data.route`; the web-style `data.url`
  /// (`/?video=…`) is translated for older payloads.
  void _openFromMessage(RemoteMessage message) {
    final data = message.data;
    final route = _routeFor(data);
    if (route == null) return;
    // The router may not be mounted yet on a cold start — go after this frame.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      try {
        _ref.read(appRouterProvider).push(route);
      } catch (_) {}
    });
  }

  static String? _routeFor(Map<String, dynamic> data) {
    final route = data['route'];
    if (route is String && route.startsWith('/')) return route;

    final url = data['url'];
    if (url is String) {
      final uri = Uri.tryParse(url);
      final q = uri?.queryParameters ?? const {};
      if (q['video'] != null) return '/v/${q['video']}';
      if (q['user'] != null) return '/profile/${q['user']}';
      if (q['chat'] != null) return '/chat/${q['chat']}';
      if (q['open'] == 'wallet') return '/wallet';
    }
    return null;
  }

  void dispose() {
    _refreshSub?.cancel();
    _openedSub?.cancel();
  }
}

final pushServiceProvider = Provider<PushService>((ref) {
  final service = PushService(ref);
  ref.onDispose(service.dispose);
  return service;
});
