import 'dart:async';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'core/cache/local_cache.dart';
import 'core/push/push_service.dart';
import 'app.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await LocalCache.init();

  // Push is optional infrastructure: a build without google-services.json, a
  // device with no Play Services, or a Firebase outage must still give a
  // working app — so a failure here is logged and swallowed, never thrown.
  final container = ProviderContainer();
  try {
    await Firebase.initializeApp();
    FirebaseMessaging.onBackgroundMessage(firebaseBackgroundHandler);
    // Not awaited: registration involves a permission sheet and a network
    // round-trip, and the feed shouldn't wait behind either.
    unawaited(container.read(pushServiceProvider).start());
  } catch (e) {
    debugPrint('Firebase unavailable, continuing without push: $e');
  }

  runApp(UncontrolledProviderScope(container: container, child: const BelopleApp()));
}
