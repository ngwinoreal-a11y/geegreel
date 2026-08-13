import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/live_repository.dart';

/// Who is on right now, refreshed while the feed is open.
///
/// Every 20 seconds, not every 3: this is a list of who is broadcasting, not
/// the inside of a broadcast. A live that started fifteen seconds ago can wait,
/// and the feed is the screen most people leave open longest.
///
/// Failures are deliberately quiet on screen — an empty rail looks exactly
/// like "nobody is live", which is the truthful fallback and the common case.
/// They are never quiet in the log.
class ActiveLivesController extends AsyncNotifier<List<LiveSession>> {
  Timer? _timer;

  @override
  Future<List<LiveSession>> build() async {
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 20), (_) => _refresh());
    ref.onDispose(() => _timer?.cancel());
    try {
      return await _load();
    } catch (e, s) {
      // An AsyncError here reads as "nobody is live" everywhere it is used —
      // valueOrNull is null and the rail simply doesn't draw. That is the right
      // thing to SHOW and the wrong thing to say nothing about: a parse error
      // and an empty schedule look identical from the outside, and the first
      // one hid live cards from the feed until this line was added.
      debugPrint('[BLLIVE] loading active lives failed: $e\n$s');
      rethrow;
    }
  }

  Future<List<LiveSession>> _load() => ref.read(liveRepositoryProvider).active();

  Future<void> _refresh() async {
    try {
      final lives = await _load();
      state = AsyncData(lives);
    } catch (e) {
      // Keep whatever was last known rather than blanking the rail on one bad
      // request — the previous list is a better guess than nothing.
      debugPrint('[BLLIVE] refreshing the live rail failed: $e');
    }
  }
}

final activeLivesProvider =
    AsyncNotifierProvider<ActiveLivesController, List<LiveSession>>(ActiveLivesController.new);
