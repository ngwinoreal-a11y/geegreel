import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/network/api_client.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_typography.dart';
import '../../../core/widgets/top_toast.dart';
import '../data/promote_repository.dart';

/// Staff review queue: paid user ads awaiting approval. Approve → the ad goes
/// live; Reject → the creator is notified it wasn't approved.
class AdminAdsScreen extends ConsumerWidget {
  const AdminAdsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final adsAsync = ref.watch(pendingAdsProvider);
    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: AppBar(title: const Text('Review ads')),
      body: adsAsync.when(
        loading: () => const Center(child: CircularProgressIndicator(color: AppColors.text)),
        error: (e, _) => Center(child: Text("Couldn't load the queue", style: AppTypography.sans(color: AppColors.muted))),
        data: (ads) {
          if (ads.isEmpty) {
            return Center(child: Text('Nothing to review', style: AppTypography.sans(color: AppColors.muted)));
          }
          return RefreshIndicator(
            onRefresh: () async => ref.invalidate(pendingAdsProvider),
            child: ListView.separated(
              padding: const EdgeInsets.all(16),
              itemCount: ads.length,
              separatorBuilder: (_, _) => const SizedBox(height: 12),
              itemBuilder: (context, i) => _ReviewCard(ad: ads[i]),
            ),
          );
        },
      ),
    );
  }
}

class _ReviewCard extends ConsumerStatefulWidget {
  const _ReviewCard({required this.ad});
  final AdStat ad;

  @override
  ConsumerState<_ReviewCard> createState() => _ReviewCardState();
}

class _ReviewCardState extends ConsumerState<_ReviewCard> {
  bool _busy = false;

  Future<void> _decide(bool approve) async {
    setState(() => _busy = true);
    try {
      await ref.read(promoteRepositoryProvider).decideAd(widget.ad.id, approve: approve);
      ref.invalidate(pendingAdsProvider);
      if (mounted) showTopToast(context, approve ? 'Ad approved' : 'Ad rejected');
    } catch (_) {
      if (mounted) {
        setState(() => _busy = false);
        showTopToast(context, "Couldn't update — try again");
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final ad = widget.ad;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(color: AppColors.surface, borderRadius: BorderRadius.circular(14)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: SizedBox(
                width: 56, height: 56,
                child: ad.mediaUrl != null
                    ? CachedNetworkImage(imageUrl: mediaUrl(ad.mediaUrl!), fit: BoxFit.cover)
                    : Container(color: AppColors.raised, child: const Icon(Icons.link, color: AppColors.muted)),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('@${ad.ownerUsername ?? 'unknown'}',
                      style: AppTypography.sans(fontSize: 14, fontWeight: FontWeight.w700)),
                  const SizedBox(height: 2),
                  Text('~${ad.reach ?? 0} people · \$${ad.priceUsd}',
                      style: AppTypography.sans(fontSize: 12, color: AppColors.muted)),
                ],
              ),
            ),
          ]),
          if (ad.caption.isNotEmpty) ...[
            const SizedBox(height: 10),
            Text(ad.caption, style: AppTypography.sans(fontSize: 13)),
          ],
          if (ad.linkUrl != null) ...[
            const SizedBox(height: 6),
            Text(ad.linkUrl!, style: AppTypography.sans(fontSize: 12, color: AppColors.verified)),
          ],
          const SizedBox(height: 14),
          Row(children: [
            Expanded(
              child: OutlinedButton(
                onPressed: _busy ? null : () => _decide(false),
                style: OutlinedButton.styleFrom(foregroundColor: AppColors.danger),
                child: const Text('Reject'),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: ElevatedButton(
                onPressed: _busy ? null : () => _decide(true),
                child: _busy
                    ? const SizedBox(height: 18, width: 18, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Text('Approve'),
              ),
            ),
          ]),
        ],
      ),
    );
  }
}
