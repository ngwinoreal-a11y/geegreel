import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_radii.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_typography.dart';
import '../../../core/widgets/skeleton.dart';
import '../data/wallet_repository.dart';

/// Ports index.html's walletPage(): balance + monetization summary. Buying
/// coins is deferred to Phase 5 (external-browser punt-out, same policy
/// reason as the existing TWA — see wallet_repository.dart's doc comment).
class WalletScreen extends ConsumerWidget {
  const WalletScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final walletAsync = ref.watch(walletProvider);

    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: AppBar(title: const Text('Wallet')),
      body: walletAsync.when(
        loading: () => const Padding(
          padding: EdgeInsets.all(AppSpacing.pageHorizontal),
          child: Skeleton(height: 100),
        ),
        error: (e, _) => Center(
          child: Text("Couldn't load your wallet", style: AppTypography.sans(color: AppColors.muted)),
        ),
        data: (wallet) => ListView(
          padding: const EdgeInsets.all(AppSpacing.pageHorizontal),
          children: [
            Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: AppColors.surface,
                border: Border.all(color: AppColors.border),
                borderRadius: BorderRadius.circular(AppRadii.md),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Coins', style: AppTypography.sectionLabel),
                  const SizedBox(height: 6),
                  Text('${wallet.coins}', style: AppTypography.mono(fontSize: 32, fontWeight: FontWeight.w700)),
                ],
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(child: _StatCard(label: 'Gift balance', value: '\$${(wallet.giftBalanceCents / 100).toStringAsFixed(2)}')),
                const SizedBox(width: 8),
                Expanded(child: _StatCard(label: 'Lifetime gifts', value: '\$${(wallet.lifetimeGiftsCents / 100).toStringAsFixed(2)}')),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(child: _StatCard(label: 'Gifts received', value: '${wallet.giftsReceived}')),
                const SizedBox(width: 8),
                Expanded(child: _StatCard(label: 'Gifts sent', value: '${wallet.giftsSent}')),
              ],
            ),
            const SizedBox(height: 20),
            OutlinedButton(
              onPressed: () => context.push('/monetization'),
              child: const Text('Monetization'),
            ),
          ],
        ),
      ),
    );
  }
}

class _StatCard extends StatelessWidget {
  const _StatCard({required this.label, required this.value});
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.surface,
        border: Border.all(color: AppColors.border),
        borderRadius: BorderRadius.circular(AppRadii.md),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: AppTypography.sans(fontSize: 12, color: AppColors.muted)),
          const SizedBox(height: 4),
          Text(value, style: AppTypography.mono(fontSize: 18, fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }
}
