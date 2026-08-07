import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../data/feed_repository.dart';
import '../data/video_model.dart';

enum FeedTab { following, forYou, public }

extension on FeedTab {
  String get apiValue => switch (this) {
        FeedTab.following => 'following',
        FeedTab.forYou => 'foryou',
        FeedTab.public => 'foryou', // Public tab has its own repository later; unused here.
      };
}

class FeedState {
  const FeedState({
    this.videos = const [],
    this.nextCursor,
    this.isLoadingMore = false,
    this.hasError = false,
  });

  final List<VideoModel> videos;
  final String? nextCursor;
  final bool isLoadingMore;
  final bool hasError;

  FeedState copyWith({
    List<VideoModel>? videos,
    String? nextCursor,
    bool? isLoadingMore,
    bool? hasError,
  }) {
    return FeedState(
      videos: videos ?? this.videos,
      nextCursor: nextCursor ?? this.nextCursor,
      isLoadingMore: isLoadingMore ?? this.isLoadingMore,
      hasError: hasError ?? false,
    );
  }
}

/// Cursor-paginated feed, one instance per tab (`family`), auto-disposed
/// when nothing is watching it (e.g. the user has scrolled away and the tab
/// is unmounted) — see the plan's Riverpod rationale.
class FeedController extends FamilyAsyncNotifier<FeedState, FeedTab> {
  late FeedTab _tab;

  @override
  Future<FeedState> build(FeedTab arg) async {
    _tab = arg;
    final cached = ref.read(feedRepositoryProvider).readCachedFeed(_tab.apiValue);
    if (cached != null) {
      // Paint the cached page instantly (no spinner), then quietly refresh
      // from the network — matches the WhatsApp-style instant-open feel.
      // A real Timer (not a microtask) — guarantees this runs strictly
      // after Riverpod finishes applying build()'s own returned value to
      // `state`, so this refresh's fresh data can't get clobbered back to
      // the stale cached value by that internal assignment landing later.
      Future.delayed(Duration.zero, _silentRefresh);
      return FeedState(videos: cached.videos, nextCursor: cached.nextCursor);
    }
    final page = await ref.read(feedRepositoryProvider).fetchFeed(tab: _tab.apiValue);
    return FeedState(videos: page.videos, nextCursor: page.nextCursor);
  }

  Future<void> _silentRefresh() async {
    try {
      final page = await ref.read(feedRepositoryProvider).fetchFeed(tab: _tab.apiValue);
      state = AsyncData(FeedState(videos: page.videos, nextCursor: page.nextCursor));
    } catch (_) {
      // Keep showing the cached page on a transient network failure.
    }
  }

  Future<void> loadMore() async {
    final current = state.valueOrNull;
    if (current == null || current.isLoadingMore || current.nextCursor == null) return;
    state = AsyncData(current.copyWith(isLoadingMore: true));
    try {
      final page = await ref.read(feedRepositoryProvider).fetchFeed(
            tab: _tab.apiValue,
            cursor: current.nextCursor,
          );
      state = AsyncData(current.copyWith(
        videos: [...current.videos, ...page.videos],
        nextCursor: page.nextCursor,
        isLoadingMore: false,
      ));
    } catch (_) {
      state = AsyncData(current.copyWith(isLoadingMore: false, hasError: true));
    }
  }

  /// Optimistic like/unlike, reconciled against the server's authoritative
  /// {liked, count} response — matches the web app's like handler pattern
  /// (instant UI flip, corrected if the server disagrees).
  Future<void> toggleLike(String videoId) async {
    final current = state.valueOrNull;
    if (current == null) return;
    final index = current.videos.indexWhere((v) => v.id == videoId);
    if (index == -1) return;
    final video = current.videos[index];
    final optimistic = video.copyWith(
      liked: !video.liked,
      counts: VideoCounts(
        likes: video.counts.likes + (video.liked ? -1 : 1),
        comments: video.counts.comments,
        shares: video.counts.shares,
        reposts: video.counts.reposts,
      ),
    );
    state = AsyncData(current.copyWith(videos: _replaceAt(current.videos, index, optimistic)));
    try {
      final (liked, count) = await ref.read(feedRepositoryProvider).setLiked(videoId, !video.liked);
      final latest = state.valueOrNull;
      if (latest == null) return;
      final i = latest.videos.indexWhere((v) => v.id == videoId);
      if (i == -1) return;
      final reconciled = latest.videos[i].copyWith(
        liked: liked,
        counts: VideoCounts(
          likes: count,
          comments: latest.videos[i].counts.comments,
          shares: latest.videos[i].counts.shares,
          reposts: latest.videos[i].counts.reposts,
        ),
      );
      state = AsyncData(latest.copyWith(videos: _replaceAt(latest.videos, i, reconciled)));
    } catch (_) {
      // Revert on failure.
      final latest = state.valueOrNull;
      if (latest == null) return;
      final i = latest.videos.indexWhere((v) => v.id == videoId);
      if (i == -1) return;
      state = AsyncData(latest.copyWith(videos: _replaceAt(latest.videos, i, video)));
    }
  }

  Future<void> toggleFollow(String userId) async {
    final current = state.valueOrNull;
    if (current == null) return;
    final target = current.videos.firstWhere((v) => v.user.id == userId, orElse: () => current.videos.first);
    final nextFollowing = !target.following;
    final updated = [
      for (final v in current.videos)
        if (v.user.id == userId) v.copyWith(following: nextFollowing) else v,
    ];
    state = AsyncData(current.copyWith(videos: updated));
    try {
      final following = await ref.read(feedRepositoryProvider).setFollowing(userId, nextFollowing);
      final latest = state.valueOrNull;
      if (latest == null) return;
      state = AsyncData(latest.copyWith(videos: [
        for (final v in latest.videos)
          if (v.user.id == userId) v.copyWith(following: following) else v,
      ]));
    } catch (_) {
      final latest = state.valueOrNull;
      if (latest == null) return;
      state = AsyncData(latest.copyWith(videos: [
        for (final v in latest.videos)
          if (v.user.id == userId) v.copyWith(following: !nextFollowing) else v,
      ]));
    }
  }

  List<VideoModel> _replaceAt(List<VideoModel> list, int index, VideoModel value) {
    final copy = [...list];
    copy[index] = value;
    return copy;
  }

  Future<void> refresh() async {
    state = const AsyncLoading();
    state = await AsyncValue.guard(() async {
      final page = await ref.read(feedRepositoryProvider).fetchFeed(tab: _tab.apiValue);
      return FeedState(videos: page.videos, nextCursor: page.nextCursor);
    });
  }
}

final feedControllerProvider =
    AsyncNotifierProvider.family<FeedController, FeedState, FeedTab>(FeedController.new);
