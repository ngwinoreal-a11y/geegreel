import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../core/network/api_client.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_typography.dart';
import '../data/promote_repository.dart';

/// The creator's own ads with live stats — views (toward the paid target),
/// clicks, likes, and where each ad is in the pending → active → complete flow.
class MyAdsScreen extends ConsumerWidget {
  const MyAdsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final adsAsync = ref.watch(myAdsProvider);
    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: AppBar(
        title: const Text('My ads'),
        actions: [
          IconButton(icon: const Icon(Icons.add), onPressed: () => context.push('/promote')),
        ],
      ),
      body: adsAsync.when(
        loading: () => const Center(child: CircularProgressIndicator(color: AppColors.text)),
        error: (e, _) => Center(child: Text("Couldn't load your ads", style: AppTypography.sans(color: AppColors.muted))),
        data: (ads) {
          if (ads.isEmpty) {
            return Center(
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                const Icon(Icons.campaign_outlined, color: AppColors.muted, size: 44),
                const SizedBox(height: 12),
                Text('No ads yet', style: AppTypography.sans(color: AppColors.muted)),
                const SizedBox(height: 14),
                ElevatedButton(onPressed: () => context.push('/promote'), child: const Text('Create an ad')),
              ]),
            );
          }
          return RefreshIndicator(
            onRefresh: () async => ref.invalidate(myAdsProvider),
            child: ListView.separated(
              padding: const EdgeInsets.all(16),
              itemCount: ads.length,
              separatorBuilder: (_, _) => const SizedBox(height: 12),
              itemBuilder: (context, i) => _AdCard(ad: ads[i]),
            ),
          );
        },
      ),
    );
  }
}

class _AdCard extends StatelessWidget {
  const _AdCard({required this.ad});
  final AdStat ad;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(color: AppColors.surface, borderRadius: BorderRadius.circular(14)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: SizedBox(
                  width: 46, height: 46,
                  child: ad.mediaUrl != null
                      ? CachedNetworkImage(imageUrl: mediaUrl(ad.mediaUrl!), fit: BoxFit.cover)
                      : Container(color: AppColors.raised, child: const Icon(Icons.link, color: AppColors.muted)),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(ad.caption.isEmpty ? '(no caption)' : ad.caption,
                    maxLines: 2, overflow: TextOverflow.ellipsis,
                    style: AppTypography.sans(fontSize: 14, fontWeight: FontWeight.w600)),
              ),
              const SizedBox(width: 8),
              _StatusChip(status: ad.status),
            ],
          ),
          const SizedBox(height: 14),
          // Progress toward the paid reach.
          if (ad.reach != null) ...[
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: ad.progress.toDouble(),
                minHeight: 6,
                backgroundColor: AppColors.raised,
                valueColor: const AlwaysStoppedAnimation(AppColors.accent),
              ),
            ),
            const SizedBox(height: 6),
            Text('${ad.impressions} / ${ad.reach} views',
                style: AppTypography.sans(fontSize: 12, color: AppColors.muted)),
            const SizedBox(height: 10),
          ],
          Row(
            children: [
              _stat(Icons.visibility_outlined, '${ad.impressions}', 'views'),
              _stat(Icons.ads_click, '${ad.clicks}', 'clicks'),
              _stat(Icons.favorite_border, '${ad.likes}', 'likes'),
              const Spacer(),
              Text('\$${ad.priceUsd}', style: AppTypography.sans(fontWeight: FontWeight.w700, color: AppColors.accent)),
            ],
          ),
        ],
      ),
    );
  }

  Widget _stat(IconData icon, String value, String label) {
    return Padding(
      padding: const EdgeInsets.only(right: 18),
      child: Row(children: [
        Icon(icon, size: 16, color: AppColors.muted),
        const SizedBox(width: 5),
        Text(value, style: AppTypography.sans(fontSize: 13, fontWeight: FontWeight.w600)),
        const SizedBox(width: 3),
        Text(label, style: AppTypography.sans(fontSize: 12, color: AppColors.muted)),
      ]),
    );
  }
}

class _StatusChip extends StatelessWidget {
  const _StatusChip({required this.status});
  final String status;

  @override
  Widget build(BuildContext context) {
    final (color, label) = switch (status) {
      'active' => (AppColors.online, 'Active'),
      'complete' => (AppColors.accent, 'Complete'),
      'rejected' => (AppColors.danger, 'Rejected'),
      _ => (AppColors.muted, 'In review'),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
      decoration: BoxDecoration(color: color.withValues(alpha: 0.18), borderRadius: BorderRadius.circular(20)),
      child: Text(label, style: AppTypography.sans(fontSize: 11, fontWeight: FontWeight.w700, color: color)),
    );
  }
}
