import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_radii.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_typography.dart';
import '../data/monetization_repository.dart';

/// Ports index.html's monetizationPage(): eligibility progress vs.
/// requirements (10k followers/likes, 5 videos), application status, apply
/// button (payout-method form deferred — this covers the eligibility/status
/// read path plus a one-tap apply once eligible).
class MonetizationScreen extends ConsumerWidget {
  const MonetizationScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final statusAsync = ref.watch(monetizationStatusProvider);

    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: AppBar(title: const Text('Monetization')),
      body: statusAsync.when(
        loading: () => const Center(child: CircularProgressIndicator(color: AppColors.text)),
        error: (e, _) => Center(
          child: Text("Couldn't load monetization status", style: AppTypography.sans(color: AppColors.muted)),
        ),
        data: (status) {
          if (status.monetized) {
            return Padding(
              padding: const EdgeInsets.all(AppSpacing.pageHorizontal),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('You are monetized', style: AppTypography.pageHeading.copyWith(fontSize: 18)),
                  const SizedBox(height: 6),
                  Text('Your creator earnings are calculated monthly based on views.',
                      style: AppTypography.sans(color: AppColors.muted)),
                ],
              ),
            );
          }
          return ListView(
            padding: const EdgeInsets.all(AppSpacing.pageHorizontal),
            children: [
              Text('Eligibility', style: AppTypography.sectionLabel),
              const SizedBox(height: 10),
              _ProgressRow(label: 'Followers', value: status.followers, target: 10000),
              _ProgressRow(label: 'Total likes', value: status.likes, target: 10000),
              _ProgressRow(label: 'Videos posted', value: status.videos, target: 5),
              const SizedBox(height: 20),
              if (status.applicationStatus != null)
                Text('Application status: ${status.applicationStatus}',
                    style: AppTypography.sans(color: AppColors.muted))
              else if (status.eligible)
                ElevatedButton(
                  onPressed: () async {
                    try {
                      await ref.read(monetizationRepositoryProvider).apply(
                        payoutMethod: 'mobile_money',
                        payoutDetails: const {},
                      );
                      ref.invalidate(monetizationStatusProvider);
                      if (context.mounted) {
                        ScaffoldMessenger.of(context)
                            .showSnackBar(const SnackBar(content: Text('Application submitted')));
                      }
                    } catch (_) {
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(content: Text("Couldn't submit — check your connection")));
                      }
                    }
                  },
                  child: const Text('Apply for monetization'),
                )
              else
                Text("You'll be able to apply once you meet all the requirements above.",
                    style: AppTypography.sans(color: AppColors.muted, fontSize: 13)),
            ],
          );
        },
      ),
    );
  }
}

class _ProgressRow extends StatelessWidget {
  const _ProgressRow({required this.label, required this.value, required this.target});
  final String label;
  final int value;
  final int target;

  @override
  Widget build(BuildContext context) {
    final progress = (value / target).clamp(0.0, 1.0);
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(label, style: AppTypography.sans(fontSize: 14)),
              Text('$value / $target', style: AppTypography.mono(fontSize: 13, color: AppColors.muted)),
            ],
          ),
          const SizedBox(height: 6),
          ClipRRect(
            borderRadius: BorderRadius.circular(AppRadii.sm),
            child: LinearProgressIndicator(
              value: progress,
              minHeight: 6,
              backgroundColor: AppColors.surface,
              color: progress >= 1 ? AppColors.online : AppColors.accent,
            ),
          ),
        ],
      ),
    );
  }
}
