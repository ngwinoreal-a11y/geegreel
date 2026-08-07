import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_typography.dart';
import '../../../core/widgets/skeleton.dart';
import '../data/wallet_repository.dart';

final _historyProvider = FutureProvider.autoDispose<List<WalletTx>>((ref) {
  return ref.watch(walletRepositoryProvider).fetchHistory();
});

/// Ports index.html's walletHistoryPage(): the coin/gift/earnings ledger.
class WalletHistoryScreen extends ConsumerWidget {
  const WalletHistoryScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final historyAsync = ref.watch(_historyProvider);

    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: AppBar(title: const Text('Transaction history')),
      body: historyAsync.when(
        loading: () => ListView.builder(
          padding: const EdgeInsets.all(AppSpacing.pageHorizontal),
          itemCount: 8,
          itemBuilder: (context, i) => const Padding(
            padding: EdgeInsets.symmetric(vertical: 10),
            child: Skeleton(height: 14),
          ),
        ),
        error: (e, _) => Center(
          child: Text("Couldn't load your history", style: AppTypography.sans(color: AppColors.muted)),
        ),
        data: (history) {
          if (history.isEmpty) {
            return Center(
              child: Text('No transactions yet', style: AppTypography.sans(color: AppColors.muted)),
            );
          }
          return ListView.separated(
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.pageHorizontal),
            itemCount: history.length,
            separatorBuilder: (_, _) => const Divider(color: AppColors.border, height: 1),
            itemBuilder: (context, i) => _TxRow(tx: history[i]),
          );
        },
      ),
    );
  }
}

class _TxRow extends StatelessWidget {
  const _TxRow({required this.tx});
  final WalletTx tx;

  /// Turns a raw kind ("gift_sent") into a readable label ("Gift sent").
  String get _label {
    final words = tx.kind.split('_');
    if (words.isEmpty) return tx.kind;
    return words.map((w) => w.isEmpty ? w : '${w[0].toUpperCase()}${w.substring(1)}').join(' ');
  }

  @override
  Widget build(BuildContext context) {
    // Prefer the coin delta; fall back to the cash (cents) delta for
    // gift-received / earnings rows that don't move coins.
    final usesCoins = tx.coinsDelta != 0;
    final amount = usesCoins ? tx.coinsDelta : tx.centsDelta;
    final positive = amount > 0;
    final display = usesCoins
        ? '${positive ? '+' : ''}$amount 🪙'
        : '${positive ? '+' : '-'}\$${(amount.abs() / 100).toStringAsFixed(2)}';

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 14),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(_label, style: AppTypography.sans(fontSize: 15, fontWeight: FontWeight.w600)),
                if (tx.note != null && tx.note!.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(tx.note!, style: AppTypography.sans(fontSize: 13, color: AppColors.muted)),
                ],
              ],
            ),
          ),
          Text(
            display,
            style: AppTypography.mono(
              fontSize: 15,
              fontWeight: FontWeight.w700,
              color: positive ? AppColors.online : AppColors.text,
            ),
          ),
        ],
      ),
    );
  }
}
