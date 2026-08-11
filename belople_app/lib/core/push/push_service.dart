import 'dart:async';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../network/api_client.dart';
import '../router/app_router.dart';

/// Must match `default_notification_channel_id` in AndroidManifest.xml.
/// Android 8+ silently discards a notification whose channel doesn't exist —
/// the send succeeds, FCM answers 200, and nothing is ever drawn — so the
/// channel is created at startup rather than left to an implicit fallback.
const _channelId = 'belople_default';

const _androidChannel = AndroidNotificationChannel(
  _channelId,
  'Belople',
  description: 'Likes, comments, follows, gifts and messages',
  // Anything lower than `high` will not pop up over the screen — it lands
  // silently in the shade, which reads as "notifications don't work".
  importance: Importance.high,
);

final _localNotifications = FlutterLocalNotificationsPlugin();

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
  StreamSubscription<RemoteMessage>? _foregroundSub;
  String? _lastSentToken;

  /// Registers the notification channel and the local-notification plugin used
  /// to draw messages that arrive while the app is open.
  Future<void> _setupLocal() async {
    await _localNotifications.initialize(
      const InitializationSettings(
        android: AndroidInitializationSettings('@drawable/ic_stat_belople'),
      ),
      onDidReceiveNotificationResponse: (response) {
        final route = response.payload;
        if (route != null && route.startsWith('/')) _go(route);
      },
    );
    await _localNotifications
        .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
        ?.createNotificationChannel(_androidChannel);
  }

  /// FCM does NOT draw a tray notification while the app is in the foreground —
  /// it hands the message to the app instead. Without this, testing the feature
  /// with the app open looks exactly like it being broken.
  void _showForeground(RemoteMessage message) {
    final n = message.notification;
    if (n == null) return;
    _localNotifications.show(
      message.hashCode,
      n.title,
      n.body,
      NotificationDetails(
        android: AndroidNotificationDetails(
          _channelId,
          _androidChannel.name,
          channelDescription: _androidChannel.description,
          importance: Importance.high,
          priority: Priority.high,
          icon: '@drawable/ic_stat_belople',
        ),
      ),
      payload: message.data['route']?.toString(),
    );
  }

  /// Called once after Firebase.initializeApp() and again whenever the signed-in
  /// user changes, since a token is only useful once it's tied to an account.
  Future<void> start() async {
    try {
      final messaging = FirebaseMessaging.instance;
      await _setupLocal();

      // Android 13+ shows the system permission sheet here. Declining is a
      // normal outcome, not an error — we just never get a token to send.
      final settings = await messaging.requestPermission();
      if (settings.authorizationStatus == AuthorizationStatus.denied) return;

      _foregroundSub ??= FirebaseMessaging.onMessage.listen(_showForeground);

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
    final route = _routeFor(message.data);
    if (route != null) _go(route);
  }

  void _go(String route) {
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
    _foregroundSub?.cancel();
  }
}

final pushServiceProvider = Provider<PushService>((ref) {
  final service = PushService(ref);
  ref.onDispose(service.dispose);
  return service;
});
