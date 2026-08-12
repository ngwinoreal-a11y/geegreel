import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_client.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_radii.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_typography.dart';
import '../../../core/widgets/top_toast.dart';
import '../data/wallet_repository.dart';

/// Turns a coin balance back into money. Coins arrive from gifts and could be
/// spent but never withdrawn, so a creator's earnings had nowhere to go.
///
/// The coins leave the balance the moment the request is sent — the server does
/// that, not this screen — so the same coins can't be requested and then spent
/// while the payout is waiting. A rejected request returns them.
class CashOutScreen extends ConsumerStatefulWidget {
  const CashOutScreen({super.key});

  @override
  ConsumerState<CashOutScreen> createState() => _CashOutScreenState();
}

const _methods = {
  'mobile_money': 'Mobile Money',
  'bank': 'Bank transfer',
  'paypal': 'PayPal',
};

class _CashOutScreenState extends ConsumerState<CashOutScreen> {
  final _coinsController = TextEditingController();
  final _detailsController = TextEditingController();
  String _method = 'mobile_money';
  bool _sending = false;
  String? _error;

  @override
  void dispose() {
    _coinsController.dispose();
    _detailsController.dispose();
    super.dispose();
  }

  String get _detailsHint => switch (_method) {
        'mobile_money' => 'Phone number to send to',
        'bank' => 'Account number and bank name',
        _ => 'PayPal email',
      };

  Future<void> _send(int available) async {
    final coins = int.tryParse(_coinsController.text.trim()) ?? 0;
    setState(() { _error = null; });

    // Checked here as well as on the server so the common mistakes are named
    // immediately instead of costing a round-trip.
    if (coins <= 0) {
      setState(() => _error = 'Enter how many coins to cash out');
      return;
    }
    if (coins > available) {
      setState(() => _error = "You only have $available coins");
      return;
    }
    if (_detailsController.text.trim().isEmpty) {
      setState(() => _error = 'Add where the money should go');
      return;
    }

    setState(() => _sending = true);
    try {
      await ref.read(walletRepositoryProvider).requestPayout(
            coins: coins,
            method: _method,
            details: _detailsController.text.trim(),
          );
      ref.invalidate(walletProvider);
      if (!mounted) return;
      Navigator.of(context).pop();
      showTopToast(context, 'Cash-out sent — usually paid within 2–3 days');
    } on DioException catch (e) {
      setState(() {
        _sending = false;
        _error = apiErrorMessage(e, "Couldn't send — try again");
      });
    } catch (_) {
      setState(() { _sending = false; _error = "Couldn't send — try again"; });
    }
  }

  @override
  Widget build(BuildContext context) {
    final wallet = ref.watch(walletProvider);

    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: AppBar(title: const Text('Cash out')),
      body: wallet.when(
        loading: () => const Center(child: CircularProgressIndicator(color: AppColors.accent)),
        error: (_, __) => Center(
          child: Text("Couldn't load your balance",
              style: AppTypography.sans(color: AppColors.muted)),
        ),
        data: (w) {
          final available = w.coins;
          final minCoins = w.minPayoutCents; // 1 coin = 1 cent
          return ListView(
            padding: const EdgeInsets.all(AppSpacing.pageHorizontal),
            children: [
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: AppColors.surface,
                  borderRadius: BorderRadius.circular(AppRadii.lg),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('AVAILABLE', style: AppTypography.sectionLabel),
                    const SizedBox(height: 6),
                    Text('$available coins',
                        style: AppTypography.mono(fontSize: 28, fontWeight: FontWeight.w700)),
                    Text('= \$${(available / 100).toStringAsFixed(2)}',
                        style: AppTypography.sans(fontSize: 15, color: AppColors.muted)),
                  ],
                ),
              ),
              const SizedBox(height: 22),

              Text('HOW MANY COINS', style: AppTypography.sectionLabel),
              const SizedBox(height: 8),
              TextField(
                controller: _coinsController,
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                style: AppTypography.sans(fontSize: 18, color: AppColors.text),
                decoration: InputDecoration(hintText: 'Minimum $minCoins coins'),
                onChanged: (_) => setState(() {}),
              ),
              const SizedBox(height: 6),
              Row(
                children: [
                  Text(
                    'Smallest cash-out is \$${(w.minPayoutCents / 100).toStringAsFixed(2)}',
                    style: AppTypography.sans(fontSize: 13, color: AppColors.muted),
                  ),
                  const Spacer(),
                  GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () => setState(() => _coinsController.text = '$available'),
                    child: Text('All',
                        style: AppTypography.sans(
                            fontSize: 14, fontWeight: FontWeight.w700, color: AppColors.accent)),
                  ),
                ],
              ),

              const SizedBox(height: 22),
              Text('HOW SHOULD WE PAY YOU', style: AppTypography.sectionLabel),
              const SizedBox(height: 8),
              for (final entry in _methods.entries)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () => setState(() => _method = entry.key),
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
                      decoration: BoxDecoration(
                        color: AppColors.surface,
                        borderRadius: BorderRadius.circular(AppRadii.md),
                        border: Border.all(
                            color: _method == entry.key ? AppColors.accent : AppColors.border),
                      ),
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(entry.value,
                                style: AppTypography.sans(
                                    fontSize: 16,
                                    fontWeight: FontWeight.w600,
                                    color: AppColors.text)),
                          ),
                          if (_method == entry.key)
                            const Icon(Icons.check_circle, color: AppColors.accent, size: 22),
                        ],
                      ),
                    ),
                  ),
                ),

              const SizedBox(height: 14),
              TextField(
                controller: _detailsController,
                style: AppTypography.sans(fontSize: 16, color: AppColors.text),
                decoration: InputDecoration(hintText: _detailsHint),
              ),

              if (_error != null) ...[
                const SizedBox(height: 12),
                Text(_error!, style: const TextStyle(color: AppColors.error, fontSize: 14)),
              ],

              const SizedBox(height: 22),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: _sending ? null : () => _send(available),
                  child: _sending
                      ? const SizedBox(
                          height: 18, width: 18,
                          child: CircularProgressIndicator(strokeWidth: 2))
                      : const Text('Send cash-out request'),
                ),
              ),
              const SizedBox(height: 12),
              // The wait, not who does it: a timeframe is something the creator
              // can plan around.
              Text(
                'Cash-outs are usually paid within 2–3 days. The coins leave your '
                'balance now and come back if the request is turned down.',
                style: AppTypography.sans(fontSize: 13, color: AppColors.muted),
              ),
            ],
          );
        },
      ),
    );
  }
}
