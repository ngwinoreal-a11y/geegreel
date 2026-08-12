import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../feed/data/feed_repository.dart';
import '../../feed/data/video_model.dart';
import '../data/post_model.dart';
import '../data/public_feed_repository.dart';

class PublicFeedState {
  const PublicFeedState({
    this.posts = const [],
    this.ad,
    this.nextCursor,
    this.isLoadingMore = false,
  });
  final List<PostModel> posts;

  /// The photo/text ad for this session's feed, spliced in a few cards down by
  /// the screen. Held here (not per page) so scrolling doesn't stack one ad per
  /// batch loaded.
  final VideoModel? ad;

  final String? nextCursor;
  final bool isLoadingMore;

  PublicFeedState copyWith({
    List<PostModel>? posts,
    VideoModel? ad,
    String? nextCursor,
    bool? isLoadingMore,
  }) {
    return PublicFeedState(
      posts: posts ?? this.posts,
      ad: ad ?? this.ad,
      nextCursor: nextCursor ?? this.nextCursor,
      isLoadingMore: isLoadingMore ?? this.isLoadingMore,
    );
  }
}

class PublicFeedController extends AsyncNotifier<PublicFeedState> {
  @override
  Future<PublicFeedState> build() async {
    final cached = ref.read(publicFeedRepositoryProvider).readCachedPosts();
    if (cached != null) {
      Future.delayed(Duration.zero, _silentRefresh);
      return PublicFeedState(posts: cached.posts, ad: cached.ad, nextCursor: cached.nextCursor);
    }
    final page = await ref.read(publicFeedRepositoryProvider).fetchPosts();
    return PublicFeedState(posts: page.posts, ad: page.ad, nextCursor: page.nextCursor);
  }

  Future<void> _silentRefresh() async {
    try {
      final page = await ref.read(publicFeedRepositoryProvider).fetchPosts();
      state = AsyncData(PublicFeedState(posts: page.posts, ad: page.ad, nextCursor: page.nextCursor));
    } catch (_) {
      // Keep showing the cached posts on a transient network failure.
    }
  }

  Future<void> loadMore() async {
    final current = state.valueOrNull;
    if (current == null || current.isLoadingMore || current.nextCursor == null) return;
    state = AsyncData(current.copyWith(isLoadingMore: true));
    final page = await ref.read(publicFeedRepositoryProvider).fetchPosts(cursor: current.nextCursor);
    state = AsyncData(current.copyWith(
      posts: [...current.posts, ...page.posts],
      nextCursor: page.nextCursor,
      isLoadingMore: false,
    ));
  }

  Future<void> toggleLike(String postId) async {
    final current = state.valueOrNull;
    if (current == null) return;
    final index = current.posts.indexWhere((p) => p.id == postId);
    if (index == -1) return;
    final post = current.posts[index];
    final optimistic = post.copyWith(liked: !post.liked, likes: post.likes + (post.liked ? -1 : 1));
    state = AsyncData(current.copyWith(posts: _replace(current.posts, index, optimistic)));
    try {
      final (liked, count) =
          await ref.read(publicFeedRepositoryProvider).setLiked(postId, !post.liked);
      final latest = state.valueOrNull;
      if (latest == null) return;
      final i = latest.posts.indexWhere((p) => p.id == postId);
      if (i == -1) return;
      state = AsyncData(latest.copyWith(
        posts: _replace(latest.posts, i, latest.posts[i].copyWith(liked: liked, likes: count)),
      ));
    } catch (_) {
      final latest = state.valueOrNull;
      if (latest == null) return;
      final i = latest.posts.indexWhere((p) => p.id == postId);
      if (i == -1) return;
      state = AsyncData(latest.copyWith(posts: _replace(latest.posts, i, post)));
    }
  }

  /// Follow/unfollow a post's author, flipping every post by that author in
  /// the feed optimistically and reverting on failure. Storing it on the model
  /// (not a widget's local state) means the button keeps the right label even
  /// as the list rebuilds/recycles while scrolling.
  Future<void> toggleFollow(String userId, bool currentlyFollowing) async {
    final next = !currentlyFollowing;
    _setFollowing(userId, next);
    try {
      await ref.read(feedRepositoryProvider).setFollowing(userId, next);
    } catch (_) {
      _setFollowing(userId, currentlyFollowing); // revert
    }
  }

  void _setFollowing(String userId, bool following) {
    final current = state.valueOrNull;
    if (current == null) return;
    final posts = current.posts
        .map((p) => p.user.id == userId ? p.copyWith(following: following) : p)
        .toList();
    state = AsyncData(current.copyWith(posts: posts));
  }

  /// Bumps a post's share count after a share (best-effort, cosmetic).
  Future<void> registerShare(String postId) async {
    try {
      final count = await ref.read(publicFeedRepositoryProvider).sharePost(postId);
      final current = state.valueOrNull;
      if (current == null) return;
      final i = current.posts.indexWhere((p) => p.id == postId);
      if (i == -1) return;
      state = AsyncData(current.copyWith(
        posts: _replace(current.posts, i, current.posts[i].copyWith(shares: count)),
      ));
    } catch (_) {/* count is cosmetic */}
  }

  List<PostModel> _replace(List<PostModel> list, int index, PostModel value) {
    final copy = [...list];
    copy[index] = value;
    return copy;
  }
}

final publicFeedControllerProvider =
    AsyncNotifierProvider<PublicFeedController, PublicFeedState>(PublicFeedController.new);
