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
                  const SizedBox(height: 14),
                  // There is deliberately no "Get coins" button here.
                  //
                  // Google Play requires digital goods bought inside an Android
                  // app to go through Play Billing, and forbids the app from
                  // pointing anyone at any other way to pay — a button, a link,
                  // a price, or even a hint. Coins are bought on the website
                  // instead, and the app simply shows the balance and spends
                  // it, which IS allowed (the same "consumption-only" shape
                  // Netflix and Spotify use). Say nothing here about where more
                  // coins come from; that silence is the whole point.
                  //
                  // When Play Billing is wired in, this button comes back and
                  // the restriction lifts entirely. See git history for the
                  // screen it used to open.
                  //
                  // Cashing OUT is unaffected: Play's fee applies to money
                  // coming in, never to paying a creator.
                  // White, not the brand amber. Full width and amber made a
                  // slab of yellow the size of the card — the loudest thing on
                  // a screen that is otherwise about numbers. White carries the
                  // same weight without the shouting, and reads as the serious
                  // action it is; the app already uses white for its floating
                  // chrome, so it isn't a new colour.
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton(
                      onPressed: () => context.push('/wallet/cash-out'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppColors.chrome,
                        foregroundColor: AppColors.onChrome,
                      ),
                      child: const Text('Cash out'),
                    ),
                  ),
                  const SizedBox(height: 4),
                  // No outline. A ring around a secondary action drew as much
                  // of the eye as the primary one above it — the two read as
                  // equals when they aren't. Plain amber text is enough.
                  SizedBox(
                    width: double.infinity,
                    child: TextButton(
                      onPressed: () => context.push('/wallet/history'),
                      style: TextButton.styleFrom(foregroundColor: AppColors.accent),
                      child: const Text('History'),
                    ),
                  ),
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
            const SizedBox(height: 12),
            // Also unringed — see the History button above.
            TextButton(
              onPressed: () => context.push('/monetization'),
              style: TextButton.styleFrom(foregroundColor: AppColors.accent),
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
