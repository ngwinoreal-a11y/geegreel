import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../data/post_model.dart';
import '../data/public_feed_repository.dart';

class PublicFeedState {
  const PublicFeedState({this.posts = const [], this.nextCursor, this.isLoadingMore = false});
  final List<PostModel> posts;
  final String? nextCursor;
  final bool isLoadingMore;

  PublicFeedState copyWith({List<PostModel>? posts, String? nextCursor, bool? isLoadingMore}) {
    return PublicFeedState(
      posts: posts ?? this.posts,
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
      return PublicFeedState(posts: cached.posts, nextCursor: cached.nextCursor);
    }
    final page = await ref.read(publicFeedRepositoryProvider).fetchPosts();
    return PublicFeedState(posts: page.posts, nextCursor: page.nextCursor);
  }

  Future<void> _silentRefresh() async {
    try {
      final page = await ref.read(publicFeedRepositoryProvider).fetchPosts();
      state = AsyncData(PublicFeedState(posts: page.posts, nextCursor: page.nextCursor));
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

  List<PostModel> _replace(List<PostModel> list, int index, PostModel value) {
    final copy = [...list];
    copy[index] = value;
    return copy;
  }
}

final publicFeedControllerProvider =
    AsyncNotifierProvider<PublicFeedController, PublicFeedState>(PublicFeedController.new);
