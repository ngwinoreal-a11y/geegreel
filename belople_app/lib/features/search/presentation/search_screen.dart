import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/cache/local_cache.dart';
import '../../../core/network/api_client.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_radii.dart';
import '../../../core/theme/app_typography.dart';
import '../../../core/widgets/app_avatar.dart';
import '../../../core/widgets/skeleton.dart';
import '../data/search_repository.dart';

/// Search over everything in Belople.
///
/// The box reaches accounts, videos, Public posts and sounds — and matches on
/// anything written in them, including comments (see /api/search). The screen
/// used to render only the accounts, so the other three came back over the
/// wire and were dropped on the floor.
///
/// The empty state is the list of what you searched before, because that is
/// what a person opening search most often wants: the thing they looked at
/// yesterday.
class SearchScreen extends ConsumerStatefulWidget {
  const SearchScreen({super.key});

  @override
  ConsumerState<SearchScreen> createState() => _SearchScreenState();
}

const _kRecentSearchesKey = 'recent_searches';
const _kMaxRecent = 12;

class _SearchScreenState extends ConsumerState<SearchScreen> {
  final _controller = TextEditingController();
  Timer? _debounce;
  SearchResults? _results;
  bool _loading = false;
  List<String> _recent = const [];

  @override
  void initState() {
    super.initState();
    _recent = LocalCache.getStringList(_kRecentSearchesKey);
  }

  void _onChanged(String value) {
    _debounce?.cancel();
    if (value.trim().isEmpty) {
      setState(() { _results = null; _loading = false; });
      return;
    }
    _debounce = Timer(const Duration(milliseconds: 300), () => _run(value));
  }

  /// Saved when a search actually returns something, not on every keystroke —
  /// otherwise the list fills with "a", "ab", "abc" on the way to one word.
  Future<void> _remember(String term) async {
    final t = term.trim();
    if (t.isEmpty) return;
    final next = [t, ..._recent.where((r) => r.toLowerCase() != t.toLowerCase())]
        .take(_kMaxRecent)
        .toList();
    setState(() => _recent = next);
    await LocalCache.putJson(_kRecentSearchesKey, next);
  }

  Future<void> _forget(String term) async {
    final next = _recent.where((r) => r != term).toList();
    setState(() => _recent = next);
    await LocalCache.putJson(_kRecentSearchesKey, next);
  }

  Future<void> _clearRecent() async {
    setState(() => _recent = const []);
    await LocalCache.putJson(_kRecentSearchesKey, const []);
  }

  void _useRecent(String term) {
    _controller.text = term;
    _controller.selection = TextSelection.collapsed(offset: term.length);
    _run(term);
  }

  Future<void> _run(String query) async {
    final q = query.trim();
    if (q.isEmpty) {
      setState(() => _results = null);
      return;
    }
    setState(() => _loading = true);
    try {
      final results = await ref.read(searchRepositoryProvider).search(q);
      if (!mounted) return;
      setState(() { _results = results; _loading = false; });
      if (!results.isEmpty) _remember(q);
    } catch (e) {
      // A search that fails quietly looks exactly like a search with no
      // results, and the person retypes the same word forever.
      debugPrint('[BLSEARCH] "$q" failed: $e');
      if (mounted) setState(() { _loading = false; _results = const SearchResults(); });
    }
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final results = _results;
    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: AppBar(
        backgroundColor: AppColors.bg,
        surfaceTintColor: AppColors.bg,
        elevation: 0,
        titleSpacing: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: AppColors.text),
          onPressed: () => context.pop(),
        ),
        title: Padding(
          padding: const EdgeInsets.only(right: 12),
          child: Container(
            height: 42,
            padding: const EdgeInsets.symmetric(horizontal: 14),
            decoration: BoxDecoration(
              color: AppColors.surface,
              borderRadius: BorderRadius.circular(999),
            ),
            child: Row(
              children: [
                const Icon(Icons.search, size: 20, color: AppColors.muted),
                const SizedBox(width: 10),
                Expanded(
                  child: TextField(
                    controller: _controller,
                    autofocus: true,
                    textInputAction: TextInputAction.search,
                    onChanged: _onChanged,
                    onSubmitted: _run,
                    style: AppTypography.sans(fontSize: 15, color: AppColors.text),
                    decoration: InputDecoration(
                      isDense: true,
                      border: InputBorder.none,
                      contentPadding: const EdgeInsets.symmetric(vertical: 11),
                      hintText: 'Search',
                      hintStyle: AppTypography.sans(fontSize: 15, color: AppColors.muted),
                    ),
                  ),
                ),
                if (_controller.text.isNotEmpty)
                  GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () {
                      _controller.clear();
                      setState(() => _results = null);
                    },
                    child: const Icon(Icons.close, size: 19, color: AppColors.muted),
                  ),
              ],
            ),
          ),
        ),
      ),
      body: _loading
          ? _skeleton()
          : results == null
              ? _RecentSearches(
                  terms: _recent,
                  onUse: _useRecent,
                  onForget: _forget,
                  onClear: _clearRecent,
                )
              : results.isEmpty
                  ? _empty()
                  : _resultList(results),
    );
  }

  Widget _skeleton() => ListView.builder(
        padding: const EdgeInsets.all(16),
        itemCount: 6,
        itemBuilder: (context, i) => const Padding(
          padding: EdgeInsets.symmetric(vertical: 9),
          child: Row(children: [
            Skeleton.avatar(size: 44),
            SizedBox(width: 12),
            Expanded(child: Skeleton(height: 12)),
          ]),
        ),
      );

  Widget _empty() => Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.search_off, size: 42, color: AppColors.faint),
              const SizedBox(height: 12),
              Text('Nothing matched "${_controller.text.trim()}"',
                  textAlign: TextAlign.center,
                  style: AppTypography.sans(fontSize: 15, color: AppColors.muted)),
            ],
          ),
        ),
      );

  Widget _resultList(SearchResults r) {
    return ListView(
      padding: const EdgeInsets.only(bottom: 32),
      children: [
        if (r.accounts.isNotEmpty) ...[
          _sectionLabel('Accounts'),
          for (final u in r.accounts)
            ListTile(
              leading: AppAvatar(
                size: 44,
                imageUrl: u.avatarUrl != null ? mediaUrl(u.avatarUrl!) : null,
                displayName: u.displayName,
              ),
              title: Text(u.displayName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppTypography.sans(fontWeight: FontWeight.w600)),
              subtitle: Text('@${u.username}',
                  style: AppTypography.sans(fontSize: 13, color: AppColors.muted)),
              onTap: () => context.push('/profile/${u.username}'),
            ),
        ],
        if (r.sounds.isNotEmpty) ...[
          _sectionLabel('Sounds'),
          for (final s in r.sounds)
            ListTile(
              leading: ClipRRect(
                borderRadius: BorderRadius.circular(AppRadii.sm),
                child: s.coverUrl != null
                    ? CachedNetworkImage(
                        imageUrl: mediaUrl(s.coverUrl!),
                        width: 44, height: 44, fit: BoxFit.cover)
                    : Container(
                        width: 44, height: 44,
                        color: AppColors.surface,
                        child: const Icon(Icons.music_note, color: AppColors.muted),
                      ),
              ),
              title: Text(s.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppTypography.sans(fontWeight: FontWeight.w600)),
              subtitle: Text(
                  '${s.uses} ${s.uses == 1 ? 'video' : 'videos'}'
                  '${s.authorUsername != null ? ' · @${s.authorUsername}' : ''}',
                  style: AppTypography.sans(fontSize: 13, color: AppColors.muted)),
              onTap: () => context.push('/sound/${s.id}'),
            ),
        ],
        // Videos and posts are grids, not rows: what you recognise in a video
        // is its picture, and a list of captions is unreadable next to it.
        if (r.videos.isNotEmpty) ...[
          _sectionLabel('Videos'),
          _grid(
            count: r.videos.length,
            thumb: (i) => r.videos[i].thumbUrl,
            // The model travels with it, so the player opens on its own frame
            // rather than spinning through a fetch it does not need.
            onTap: (i) => context.push('/v/${r.videos[i].id}', extra: r.videos[i]),
          ),
        ],
        if (r.posts.isNotEmpty) ...[
          _sectionLabel('Posts'),
          _grid(
            count: r.posts.length,
            thumb: (i) => r.posts[i].imageUrl,
            caption: (i) => r.posts[i].content,
            // Required here, not just nice: /p/:id with no model in `extra`
            // falls back to the whole Public feed.
            onTap: (i) => context.push('/p/${r.posts[i].id}', extra: r.posts[i]),
          ),
        ],
      ],
    );
  }

  Widget _sectionLabel(String text) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 18, 16, 6),
        child: Text(text.toUpperCase(), style: AppTypography.sectionLabel),
      );

  Widget _grid({
    required int count,
    required String? Function(int) thumb,
    String Function(int)? caption,
    required void Function(int) onTap,
  }) =>
      GridView.builder(
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        padding: const EdgeInsets.symmetric(horizontal: 12),
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 3,
          mainAxisSpacing: 4,
          crossAxisSpacing: 4,
          childAspectRatio: 0.72,
        ),
        itemCount: count,
        itemBuilder: (context, i) {
          final url = thumb(i);
          final text = caption?.call(i);
          return GestureDetector(
            onTap: () => onTap(i),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(AppRadii.sm),
              child: Container(
                color: AppColors.surface,
                child: url != null
                    ? CachedNetworkImage(imageUrl: mediaUrl(url), fit: BoxFit.cover)
                    // A text post has no picture — show its words, which is
                    // the whole post anyway.
                    : (text ?? '').trim().isNotEmpty
                        ? Padding(
                            padding: const EdgeInsets.all(8),
                            child: Text(
                              text!.trim(),
                              maxLines: 6,
                              overflow: TextOverflow.ellipsis,
                              style: AppTypography.sans(fontSize: 12, color: AppColors.text),
                            ),
                          )
                        // Nothing to show at all: a video whose poster frame
                        // never got made, or a post with neither picture nor
                        // words. It drew as a blank grey hole in the grid,
                        // which reads as the grid being broken rather than as
                        // a result you can still tap.
                        : const Center(
                            child: Icon(Icons.play_circle_outline,
                                color: AppColors.faint, size: 30),
                          ),
              ),
            ),
          );
        },
      );
}

/// What you searched before. Tap to run it again, ✕ to drop one, Clear all to
/// drop the lot.
class _RecentSearches extends StatelessWidget {
  const _RecentSearches({
    required this.terms,
    required this.onUse,
    required this.onForget,
    required this.onClear,
  });

  final List<String> terms;
  final ValueChanged<String> onUse;
  final ValueChanged<String> onForget;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    if (terms.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Text('Search people, videos, posts and sounds',
              textAlign: TextAlign.center,
              style: AppTypography.sans(fontSize: 14.5, color: AppColors.muted)),
        ),
      );
    }
    return ListView(
      padding: const EdgeInsets.only(bottom: 24),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 8, 2),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text('Recent searches',
                  style: AppTypography.sans(fontSize: 16, fontWeight: FontWeight.w700)),
              TextButton(
                onPressed: onClear,
                style: TextButton.styleFrom(foregroundColor: AppColors.accent),
                child: const Text('Clear all'),
              ),
            ],
          ),
        ),
        for (final term in terms)
          ListTile(
            dense: true,
            leading: Container(
              width: 34, height: 34,
              decoration: const BoxDecoration(color: AppColors.surface, shape: BoxShape.circle),
              child: const Icon(Icons.history, size: 18, color: AppColors.muted),
            ),
            title: Text(term,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppTypography.sans(fontSize: 15, color: AppColors.text)),
            trailing: IconButton(
              icon: const Icon(Icons.close, size: 18, color: AppColors.muted),
              onPressed: () => onForget(term),
            ),
            onTap: () => onUse(term),
          ),
      ],
    );
  }
}
