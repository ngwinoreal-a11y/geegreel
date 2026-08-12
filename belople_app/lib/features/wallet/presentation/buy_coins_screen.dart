import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_radii.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_typography.dart';
import '../data/wallet_repository.dart';

/// Ports index.html's coin top-up flow. There is no in-app payment processor:
/// the user picks a pack, says how they paid (MoMo / Airtel / bank), and the
/// purchase is recorded as *pending* until an admin confirms the real payment
/// and releases the coins.
class BuyCoinsScreen extends ConsumerStatefulWidget {
  const BuyCoinsScreen({super.key});

  @override
  ConsumerState<BuyCoinsScreen> createState() => _BuyCoinsScreenState();
}

const _payMethods = ['MTN MoMo', 'Airtel Money', 'Bank transfer', 'Other'];

class _BuyCoinsScreenState extends ConsumerState<BuyCoinsScreen> {
  CoinPack _pack = kCoinPacks.first;
  String _method = _payMethods.first;
  final _referenceController = TextEditingController();
  bool _submitting = false;
  String? _error;

  @override
  void dispose() {
    _referenceController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    setState(() { _submitting = true; _error = null; });
    try {
      await ref.read(walletRepositoryProvider).buyCoins(
            coins: _pack.coins,
            method: _method,
            reference: _referenceController.text.trim(),
          );
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          backgroundColor: AppColors.surface,
          title: const Text('Request sent'),
          content: const Text(
              // Says how long rather than who: naming an internal role tells
              // the buyer nothing they can act on, while a timeframe does.
              'Your coins are added once the payment is confirmed — usually '
              'within a few hours.'),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('OK'),
            ),
          ],
        ),
      );
      if (mounted) context.pop();
    } catch (_) {
      if (mounted) {
        setState(() => _error = "Couldn't send your request — check your connection");
      }
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: AppBar(title: const Text('Get coins')),
      body: ListView(
        padding: const EdgeInsets.all(AppSpacing.pageHorizontal),
        children: [
          Text('CHOOSE A PACK', style: AppTypography.sectionLabel),
          const SizedBox(height: 10),
          for (final pack in kCoinPacks)
            _PackTile(
              pack: pack,
              selected: pack.coins == _pack.coins,
              onTap: () => setState(() => _pack = pack),
            ),
          const SizedBox(height: 24),
          Text('HOW DID YOU PAY?', style: AppTypography.sectionLabel),
          const SizedBox(height: 10),
          DropdownButtonFormField<String>(
            initialValue: _method,
            dropdownColor: AppColors.surface,
            decoration: const InputDecoration(),
            items: [
              for (final m in _payMethods)
                DropdownMenuItem(value: m, child: Text(m, style: const TextStyle(color: AppColors.text))),
            ],
            onChanged: (v) => setState(() => _method = v ?? _method),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _referenceController,
            decoration: const InputDecoration(hintText: 'Payment reference / phone (optional)'),
          ),
          if (_error != null) ...[
            const SizedBox(height: 10),
            Text(_error!, style: const TextStyle(color: AppColors.error, fontSize: 13)),
          ],
          const SizedBox(height: 20),
          ElevatedButton(
            onPressed: _submitting ? null : _submit,
            child: Text(_submitting
                ? 'Sending...'
                : 'I paid \$${(_pack.cents / 100).toStringAsFixed(2)} for ${_pack.coins} coins'),
          ),
          const SizedBox(height: 10),
          Text(
            'Coins are added by an admin after the payment is confirmed. '
            'Belople does not charge your card in the app.',
            style: AppTypography.sans(fontSize: 12, color: AppColors.muted),
          ),
        ],
      ),
    );
  }
}

class _PackTile extends StatelessWidget {
  const _PackTile({required this.pack, required this.selected, required this.onTap});
  final CoinPack pack;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
          decoration: BoxDecoration(
            color: AppColors.surface,
            borderRadius: BorderRadius.circular(AppRadii.md),
            border: Border.all(
              color: selected ? AppColors.accent : AppColors.border,
              width: selected ? 2 : 1,
            ),
          ),
          child: Row(
            children: [
              const Text('🪙', style: TextStyle(fontSize: 22)),
              const SizedBox(width: 12),
              Expanded(
                child: Text('${pack.coins} coins',
                    style: AppTypography.sans(fontSize: 16, fontWeight: FontWeight.w700)),
              ),
              Text('\$${(pack.cents / 100).toStringAsFixed(2)}',
                  style: AppTypography.mono(fontSize: 15, color: AppColors.muted)),
              if (selected) ...[
                const SizedBox(width: 10),
                const Icon(Icons.check_circle, color: AppColors.accent, size: 20),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
