import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_radii.dart';
import '../../../core/theme/app_typography.dart';
import '../data/gift_repository.dart';
import '../data/wallet_repository.dart';

/// Opens the gift picker for a video. Ports the gift grid the web app shows on
/// a video: pick a gift, spend coins, the creator keeps a share.
Future<void> showGiftSheet(BuildContext context, {required String videoId}) {
  return showModalBottomSheet(
    context: context,
    backgroundColor: AppColors.surface,
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(borderRadius: AppRadii.sheetTop),
    builder: (_) => _GiftSheet(videoId: videoId),
  );
}

class _GiftSheet extends ConsumerStatefulWidget {
  const _GiftSheet({required this.videoId});
  final String videoId;

  @override
  ConsumerState<_GiftSheet> createState() => _GiftSheetState();
}

class _GiftSheetState extends ConsumerState<_GiftSheet> {
  String? _sending;

  Future<void> _send(Gift gift) async {
    if (_sending != null) return;
    setState(() => _sending = gift.key);
    try {
      await ref.read(giftRepositoryProvider).sendGift(videoId: widget.videoId, giftKey: gift.key);
      ref.invalidate(walletProvider);
      if (!mounted) return;
      Navigator.of(context).pop();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Sent ${gift.emoji} ${gift.name}!')),
      );
    } on DioException catch (e) {
      if (!mounted) return;
      setState(() => _sending = null);
      if (e.response?.statusCode == 402) {
        // Not enough coins — offer the top-up flow instead of a dead end.
        Navigator.of(context).pop();
        _promptBuyCoins(context);
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("Couldn't send gift — try again")),
        );
      }
    }
  }

  void _promptBuyCoins(BuildContext context) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: const Text('Not enough coins'),
        action: SnackBarAction(label: 'Get coins', onPressed: () => context.push('/coins')),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final walletAsync = ref.watch(walletProvider);
    final coins = walletAsync.valueOrNull?.coins;

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text('Send a gift', style: AppTypography.display(fontSize: 18)),
                Row(
                  children: [
                    const Text('🪙', style: TextStyle(fontSize: 16)),
                    const SizedBox(width: 6),
                    Text(coins != null ? '$coins' : '—',
                        style: AppTypography.mono(fontSize: 15, color: AppColors.text)),
                  ],
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text('The creator keeps 50% of every gift',
                style: AppTypography.sans(fontSize: 12, color: AppColors.muted)),
            const SizedBox(height: 16),
            GridView.count(
              crossAxisCount: 4,
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              mainAxisSpacing: 10,
              crossAxisSpacing: 10,
              childAspectRatio: 0.82,
              children: [
                for (final gift in kGifts)
                  _GiftTile(
                    gift: gift,
                    busy: _sending == gift.key,
                    disabled: _sending != null && _sending != gift.key,
                    onTap: () => _send(gift),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _GiftTile extends StatelessWidget {
  const _GiftTile({
    required this.gift,
    required this.busy,
    required this.disabled,
    required this.onTap,
  });
  final Gift gift;
  final bool busy;
  final bool disabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Opacity(
      opacity: disabled ? 0.4 : 1,
      child: GestureDetector(
        onTap: disabled ? null : onTap,
        child: Container(
          decoration: BoxDecoration(
            color: AppColors.raised,
            borderRadius: BorderRadius.circular(14),
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (busy)
                const SizedBox(
                  height: 30,
                  width: 30,
                  child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.text),
                )
              else
                Text(gift.emoji, style: const TextStyle(fontSize: 30)),
              const SizedBox(height: 6),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Text('🪙', style: TextStyle(fontSize: 11)),
                  const SizedBox(width: 3),
                  Text('${gift.coins}',
                      style: AppTypography.mono(fontSize: 12, color: AppColors.muted)),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
