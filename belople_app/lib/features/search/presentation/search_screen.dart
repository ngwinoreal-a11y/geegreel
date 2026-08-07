import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../core/cache/local_cache.dart';
import '../../../core/network/api_client.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_typography.dart';
import '../../../core/widgets/app_avatar.dart';
import '../../../core/widgets/skeleton.dart';
import '../data/search_repository.dart';

/// Ports index.html's searchPage(): debounced (300ms) unified search, with a
/// recent-searches list (persisted locally) shown when the box is empty.
class SearchScreen extends ConsumerStatefulWidget {
  const SearchScreen({super.key});

  @override
  ConsumerState<SearchScreen> createState() => _SearchScreenState();
}

const _kRecentSearchesKey = 'recent_searches';
const _kMaxRecent = 8;

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
    _debounce = Timer(const Duration(milliseconds: 300), () => _run(value));
  }

  /// Records a term at the top of the recent list (deduped, capped), used
  /// when a search actually resolves to results the user acts on.
  Future<void> _remember(String term) async {
    final t = term.trim();
    if (t.isEmpty) return;
    final next = [t, ..._recent.where((r) => r.toLowerCase() != t.toLowerCase())]
        .take(_kMaxRecent)
        .toList();
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
    if (query.trim().isEmpty) {
      setState(() => _results = null);
      return;
    }
    setState(() => _loading = true);
    try {
      final results = await ref.read(searchRepositoryProvider).search(query);
      if (mounted) setState(() { _results = results; _loading = false; });
    } catch (_) {
      if (mounted) setState(() => _loading = false);
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
    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: AppBar(
        title: TextField(
          controller: _controller,
          autofocus: true,
          onChanged: _onChanged,
          style: AppTypography.sans(color: AppColors.text),
          decoration: const InputDecoration(hintText: 'Search accounts, videos, posts'),
        ),
      ),
      body: _loading
          ? ListView.builder(
              padding: const EdgeInsets.all(AppSpacing.pageHorizontal),
              itemCount: 5,
              itemBuilder: (context, i) => const Padding(
                padding: EdgeInsets.symmetric(vertical: 8),
                child: Row(children: [
                  Skeleton.avatar(size: 44),
                  SizedBox(width: 12),
                  Expanded(child: Skeleton(height: 12)),
                ]),
              ),
            )
          : (_results == null)
              ? _RecentSearches(
                  terms: _recent,
                  onUse: _useRecent,
                  onClear: _clearRecent,
                )
              : (_results!.accounts.isEmpty)
                  ? Center(
                      child: Text('No results', style: AppTypography.sans(color: AppColors.muted)))
                  : ListView.builder(
                      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.pageHorizontal),
                      itemCount: _results!.accounts.length,
                      itemBuilder: (context, i) {
                        final u = _results!.accounts[i];
                        return ListTile(
                          contentPadding: EdgeInsets.zero,
                          leading: AppAvatar(
                            size: 44,
                            imageUrl: u.avatarUrl != null ? mediaUrl(u.avatarUrl!) : null,
                            displayName: u.displayName,
                          ),
                          title: Text(u.displayName, style: AppTypography.sans(fontWeight: FontWeight.w600)),
                          subtitle: Text('@${u.username}', style: AppTypography.sans(color: AppColors.muted, fontSize: 13)),
                          onTap: () {
                            _remember(_controller.text);
                            context.push('/profile/${u.username}');
                          },
                        );
                      },
                    ),
    );
  }
}

/// The empty-state list of previously-run searches — tap to re-run, or clear
/// the whole list. Mirrors index.html's recent-searches block.
class _RecentSearches extends StatelessWidget {
  const _RecentSearches({required this.terms, required this.onUse, required this.onClear});
  final List<String> terms;
  final ValueChanged<String> onUse;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    if (terms.isEmpty) return const SizedBox.shrink();
    return ListView(
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.pageHorizontal),
      children: [
        const SizedBox(height: 8),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text('RECENT', style: AppTypography.sectionLabel),
            TextButton(
              onPressed: onClear,
              style: TextButton.styleFrom(
                foregroundColor: AppColors.muted,
                padding: EdgeInsets.zero,
                minimumSize: const Size(0, 0),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              child: const Text('Clear'),
            ),
          ],
        ),
        for (final term in terms)
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.history, color: AppColors.muted),
            title: Text(term, style: AppTypography.sans(color: AppColors.text)),
            trailing: const Icon(Icons.north_west, color: AppColors.faint, size: 18),
            onTap: () => onUse(term),
          ),
      ],
    );
  }
}
