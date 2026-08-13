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
    return _load();
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
