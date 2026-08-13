import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_radii.dart';
import '../../../core/theme/app_typography.dart';
import '../../../core/widgets/top_toast.dart';
import '../../wallet/data/gift_repository.dart';
import '../../wallet/data/wallet_repository.dart';
import '../data/live_repository.dart';

/// The most a combo can reach. Matches LIVE_GIFT_MAX_COMBO on the server,
/// which clamps it again — the client's copy is what the counter counts to,
/// the server's is what protects the wallet.
const int kLiveGiftMaxCombo = 10;

/// How long the combo waits for another tap before it commits. Long enough to
/// keep tapping, short enough that the room sees it while it still means
/// something.
const Duration kLiveComboWindow = Duration(milliseconds: 1200);

Future<void> showLiveGiftSheet(BuildContext context, {required String sessionId}) {
  return showModalBottomSheet(
    context: context,
    backgroundColor: AppColors.surface,
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(borderRadius: AppRadii.sheetTop),
    builder: (_) => _LiveGiftSheet(sessionId: sessionId),
  );
}

class _LiveGiftSheet extends ConsumerStatefulWidget {
  const _LiveGiftSheet({required this.sessionId});
  final String sessionId;

  @override
  ConsumerState<_LiveGiftSheet> createState() => _LiveGiftSheetState();
}

class _LiveGiftSheetState extends ConsumerState<_LiveGiftSheet> {
  /// The gift currently being tapped, and how many taps have landed. Held here
  /// rather than sent per tap: the whole run goes as one request when the taps
  /// stop.
  Gift? _combo;
  int _count = 0;
  Timer? _commit;

  @override
  void dispose() {
    _commit?.cancel();
    // A combo the finger already paid for still gets sent, even if the sheet
    // is closed on the last tap.
    if (_combo != null && _count > 0) {
      unawaited(_send(_combo!, _count));
    }
    super.dispose();
  }

  void _tap(Gift gift, int? balance) {
    // A different gift commits the one before it rather than mixing them.
    if (_combo != null && _combo!.key != gift.key) {
      _flush();
    }

    final next = (_combo?.key == gift.key ? _count : 0) + 1;
    if (next > kLiveGiftMaxCombo) return;

    // Stops the counter at what they can actually afford instead of letting it
    // run up to a number the server will refuse.
    if (balance != null && gift.coins * next > balance) {
      if (_count == 0) showTopToast(context, 'Not enough coins for this gift');
      return;
    }

    setState(() {
      _combo = gift;
      _count = next;
    });
    _commit?.cancel();
    _commit = Timer(kLiveComboWindow, _flush);
  }

  void _flush() {
    final gift = _combo;
    final n = _count;
    _commit?.cancel();
    if (gift == null || n == 0) return;
    setState(() {
      _combo = null;
      _count = 0;
    });
    unawaited(_send(gift, n));
  }

  Future<void> _send(Gift gift, int n) async {
    try {
      await ref.read(liveRepositoryProvider).gift(widget.sessionId, gift.key, n);
      ref.invalidate(walletProvider);
    } on DioException catch (e) {
      debugPrint('[BLLIVE] gift ${gift.key} x$n failed: $e');
      if (!mounted) return;
      // States the fact and stops. It must not say "top up" or offer a way to
      // buy — coins are bought on the website, and an Android app that points
      // at any other payment route is the one thing Play does not allow.
      showTopToast(
        context,
        e.response?.statusCode == 402
            ? 'Not enough coins for that'
            : "Couldn't send that gift — try again",
      );
    } catch (e) {
      debugPrint('[BLLIVE] gift ${gift.key} x$n failed: $e');
      if (mounted) showTopToast(context, "Couldn't send that gift — try again");
    }
  }

  @override
  Widget build(BuildContext context) {
    final catalog = kGifts;
    final coins = ref.watch(walletProvider).valueOrNull?.coins;

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text('Send a gift',
                    style: AppTypography.sans(fontSize: 17, fontWeight: FontWeight.w700)),
                const Spacer(),
                const Icon(Icons.monetization_on, size: 18, color: AppColors.accent),
                const SizedBox(width: 6),
                Text(coins != null ? '$coins' : '—',
                    style: AppTypography.sans(fontSize: 15, fontWeight: FontWeight.w700)),
              ],
            ),
            const SizedBox(height: 4),
            Text('Tap again to send more — the count is what everyone sees.',
                style: AppTypography.sans(fontSize: 12.5, color: AppColors.muted)),
            const SizedBox(height: 14),
            Flexible(
              child: GridView.builder(
                shrinkWrap: true,
                padding: EdgeInsets.zero,
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 4,
                  mainAxisSpacing: 10,
                  crossAxisSpacing: 10,
                  childAspectRatio: 0.82,
                ),
                itemCount: catalog.length,
                itemBuilder: (context, i) {
                  final g = catalog[i];
                  final active = _combo?.key == g.key;
                  return GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () => _tap(g, coins),
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 120),
                      decoration: BoxDecoration(
                        color: active
                            ? AppColors.accent.withValues(alpha: 0.18)
                            : Colors.white.withValues(alpha: 0.04),
                        borderRadius: BorderRadius.circular(AppRadii.md),
                        border: Border.all(
                          color: active ? AppColors.accent : Colors.transparent,
                          width: 1.5,
                        ),
                      ),
                      child: Stack(
                        alignment: Alignment.center,
                        children: [
                          Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Text(g.emoji, style: const TextStyle(fontSize: 27)),
                              const SizedBox(height: 6),
                              Text(g.name,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: AppTypography.sans(fontSize: 11.5)),
                              const SizedBox(height: 2),
                              Text('${g.coins}',
                                  style: AppTypography.sans(
                                      fontSize: 11.5,
                                      fontWeight: FontWeight.w700,
                                      color: AppColors.accent)),
                            ],
                          ),
                          // The running count, on the gift being tapped.
                          if (active)
                            Positioned(
                              top: 4, right: 4,
                              child: Container(
                                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                                decoration: BoxDecoration(
                                  color: AppColors.danger,
                                  borderRadius: BorderRadius.circular(999),
                                ),
                                child: Text('x$_count',
                                    style: AppTypography.sans(
                                        fontSize: 12,
                                        fontWeight: FontWeight.w900,
                                        color: Colors.white)),
                              ),
                            ),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}
