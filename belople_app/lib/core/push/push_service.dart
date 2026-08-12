import 'dart:async';
import 'dart:io';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

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

/// The action button offered per notification type — the "Reply"/"Open chat"
/// affordance other apps have and this one didn't. Tapping one routes exactly
/// where the body does; the value is only the label.
/// The action button per notification type. Every one used to read "Watch",
/// including on a message — the label has to name what you'd actually do next.
String _actionLabel(String type) => switch (type) {
      'message' => 'Open chat',
      'comment' || 'reply' => 'Reply',
      'follow' => 'View profile',
      'like' => 'View video',
      'gift' => 'Say thanks',
      'repost' => 'View video',
      'post' => 'Watch',
      _ => 'Open',
    };

/// Downloads the actor's photo and returns a local file path for it, or null.
/// Android's large icon has to come from a bitmap on disk, so a remote avatar
/// must be fetched before the notification can be built. Failure is fine: the
/// notification just shows without a photo rather than not showing at all.
/// Downloads one image for a notification (the actor's avatar, or the video's
/// poster for the expanded view) and returns a local path.
Future<String?> _downloadImage(String url, {String prefix = 'notif'}) async {
  if (url.isEmpty) return null;
  // dart:io's HttpClient rather than a package: this also runs in the
  // background isolate, where the fewer moving parts the better.
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
  try {
    final res = await client
        .getUrl(Uri.parse(url))
        .then((req) => req.close())
        .timeout(const Duration(seconds: 10));
    if (res.statusCode != 200) return null;
    final bytes = await consolidateHttpClientResponseBytes(res);
    if (bytes.isEmpty) return null;
    final dir = await getTemporaryDirectory();
    final file = File('${dir.path}/${prefix}_${url.hashCode}.jpg');
    await file.writeAsBytes(bytes);
    return file.path;
  } catch (_) {
    return null;
  } finally {
    client.close();
  }
}

/// Builds and shows one notification from a data-only FCM message.
///
/// Shared by the foreground listener and the background isolate, so a
/// notification looks identical whether the app was open, backgrounded, or
/// killed. The server sends data only — Android's own rendering can't show a
/// person's photo or an action button — so everything here is ours to draw.
Future<void> _showFromData(Map<String, dynamic> data) async {
  final title = (data['title'] ?? 'Belople').toString();
  final body = (data['body'] ?? '').toString();
  final type = (data['type'] ?? '').toString();
  final route = (data['route'] ?? '/').toString();
  final tag = (data['tag'] ?? type).toString();

  // Both images at once: the notification can't be drawn until they're here,
  // and fetching them one after the other doubles the wait for no reason.
  final results = await Future.wait([
    _downloadImage((data['avatar'] ?? '').toString(), prefix: 'notif_av'),
    _downloadImage((data['image'] ?? '').toString(), prefix: 'notif_img'),
  ]);
  final avatarPath = results[0];
  final imagePath = results[1];

  final android = AndroidNotificationDetails(
    _channelId,
    _androidChannel.name,
    channelDescription: _androidChannel.description,
    importance: Importance.high,
    priority: Priority.high,
    // Small icon stays the Belople mark; the large icon is the person who did
    // the thing — the same arrangement every messaging app uses.
    icon: '@drawable/ic_stat_belople',
    largeIcon: avatarPath != null ? FilePathAndroidBitmap(avatarPath) : null,
    // Expanded, show the VIDEO it's about — a like or comment means nothing
    // until you know which of your videos it landed on, and a 44px thumbnail
    // isn't enough to tell. Falls back to big text when there's no image, so a
    // long caption still isn't cut off at one line.
    styleInformation: imagePath != null
        ? BigPictureStyleInformation(
            FilePathAndroidBitmap(imagePath),
            contentTitle: title,
            summaryText: body.isNotEmpty ? body : null,
            // The avatar stays the large icon while collapsed; hiding it on
            // expand is what lets the picture have the full width.
            hideExpandedLargeIcon: true,
          )
        : (body.isNotEmpty ? BigTextStyleInformation(body, contentTitle: title) : null),
    // Same tag = replace, so ten likes don't become ten rows in the shade.
    tag: tag.isEmpty ? null : tag,
    actions: [AndroidNotificationAction('open', _actionLabel(type), showsUserInterface: true)],
  );

  await _localNotifications.show(
    tag.hashCode,
    title,
    body,
    NotificationDetails(android: android),
    payload: route,
  );
}

/// Handles a message that arrives while the app is backgrounded or fully
/// terminated. Must be a top-level function — Android spins up a separate
/// isolate for it, so anything captured from the UI isolate simply isn't there,
/// including the notification plugin's own setup. That's why the channel and
/// the plugin are initialised again here rather than assumed.
@pragma('vm:entry-point')
Future<void> firebaseBackgroundHandler(RemoteMessage message) async {
  await Firebase.initializeApp();
  await _localNotifications.initialize(
    const InitializationSettings(
      android: AndroidInitializationSettings('@drawable/ic_stat_belople'),
    ),
  );
  await _localNotifications
      .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
      ?.createNotificationChannel(_androidChannel);
  await _showFromData(message.data);
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

    // A tap that COLD-STARTS the app doesn't come through the callback above —
    // the plugin wasn't listening yet when it happened. The launch details are
    // the only record of it, and they're only readable once, right here.
    final launch = await _localNotifications.getNotificationAppLaunchDetails();
    final route = launch?.notificationResponse?.payload;
    if (launch?.didNotificationLaunchApp == true && route != null && route.startsWith('/')) {
      _go(route);
    }
  }

  /// A data-only message is never drawn by Android on its own, in any app
  /// state — drawing it is entirely ours. Same builder as the background
  /// isolate so a notification looks the same however it arrived.
  void _showForeground(RemoteMessage message) {
    _showFromData(message.data);
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
