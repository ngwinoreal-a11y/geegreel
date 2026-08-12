import 'dart:io';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';
import '../../../core/network/api_client.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_typography.dart';
import '../../../core/theme/app_radii.dart';
import '../../../core/widgets/country_picker.dart';
import '../data/promote_repository.dart';

/// Self-serve ad creation: pick what to promote (video / image / link), choose
/// how many people should see it (fixed-price tiers), review, then pay. The ad
/// is created `pending`; after payment an admin reviews and approves it before
/// it goes live under the creator's name. Payment itself is stubbed until the
/// real provider is wired in.
class PromoteScreen extends ConsumerStatefulWidget {
  const PromoteScreen({super.key});

  @override
  ConsumerState<PromoteScreen> createState() => _PromoteScreenState();
}

enum _AdKind { video, image, link }

enum _Step { content, reach, review }

class _PromoteScreenState extends ConsumerState<PromoteScreen> {
  _Step _step = _Step.content;
  _AdKind _kind = _AdKind.video;
  File? _media;
  final _linkController = TextEditingController();
  final _captionController = TextEditingController();
  final _ctaController = TextEditingController(text: 'Learn more');
  AdTier _tier = kAdTiers.first;

  /// Where the ad runs. Null = everywhere. Unlike a video's country (a
  /// preference), this is a real constraint — the advertiser paid to reach a
  /// place, so spending their reach elsewhere spends their money wrongly.
  String? _country;

  Future<void> _pickCountry() async {
    final picked = await showCountryPicker(context, current: _country);
    if (picked == null || !mounted) return;
    setState(() => _country = picked == kEverywhere ? null : picked);
  }

  final _picker = ImagePicker();
  bool _submitting = false;
  String? _error;

  @override
  void dispose() {
    _linkController.dispose();
    _captionController.dispose();
    _ctaController.dispose();
    super.dispose();
  }

  Future<void> _pickMedia() async {
    final XFile? picked = _kind == _AdKind.video
        ? await _picker.pickVideo(source: ImageSource.gallery)
        : await _picker.pickImage(source: ImageSource.gallery, imageQuality: 90);
    if (picked != null) setState(() => _media = File(picked.path));
  }

  bool get _contentReady {
    if (_kind == _AdKind.link) return _linkController.text.trim().isNotEmpty;
    return _media != null;
  }

  void _next() {
    setState(() => _error = null);
    if (_step == _Step.content) {
      if (!_contentReady) {
        setState(() => _error = _kind == _AdKind.link ? 'Enter a link' : 'Pick a ${_kind.name}');
        return;
      }
      setState(() => _step = _Step.reach);
    } else if (_step == _Step.reach) {
      setState(() => _step = _Step.review);
    } else {
      _payAndSubmit();
    }
  }

  void _back() {
    setState(() {
      _error = null;
      _step = _Step.values[_step.index - 1];
    });
  }

  Future<void> _payAndSubmit() async {
    setState(() { _submitting = true; _error = null; });
    try {
      final repo = ref.read(promoteRepositoryProvider);
      final id = await repo.createAd(
        kind: _kind.name,
        reach: _tier.reach,
        priceCents: _tier.priceCents,
        country: _country,
        media: _kind == _AdKind.link ? null : _media,
        linkUrl: _kind == _AdKind.link ? _linkController.text.trim() : null,
        caption: _captionController.text.trim(),
        ctaText: _ctaController.text.trim().isEmpty ? 'Learn more' : _ctaController.text.trim(),
      );
      await repo.pay(id);
      if (!mounted) return;
      _showSubmitted();
    } on DioException catch (e) {
      setState(() => _error = apiErrorMessage(e, "Couldn't submit your ad — try again"));
    } catch (_) {
      setState(() => _error = "Couldn't submit your ad — try again");
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  void _showSubmitted() {
    showModalBottomSheet(
      context: context,
      backgroundColor: AppColors.surface,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(18))),
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.check_circle_outline, color: AppColors.online, size: 48),
              const SizedBox(height: 14),
              Text('Sent for review', style: AppTypography.sans(fontSize: 18, fontWeight: FontWeight.w700)),
              const SizedBox(height: 6),
              Text(
                // A timeframe, not a role: "an admin will" tells the advertiser
                // nothing they can plan around.
                "Your ad is being reviewed — usually within a day. Once approved it goes live to ~${_tier.reachLabel} people, and you'll get a notification with views and clicks.",
                textAlign: TextAlign.center,
                style: AppTypography.sans(fontSize: 14, color: AppColors.muted),
              ),
              const SizedBox(height: 18),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: () {
                    Navigator.of(ctx).pop();
                    if (mounted) context.pop();
                  },
                  child: const Text('Done'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: AppBar(
        leading: _step == _Step.content
            ? null
            : IconButton(icon: const Icon(Icons.arrow_back), onPressed: _submitting ? null : _back),
        title: Text(switch (_step) {
          _Step.content => 'What to promote',
          _Step.reach => 'How many people',
          _Step.review => 'Review & pay',
        }),
      ),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(AppSpacing.pageHorizontal),
                child: switch (_step) {
                  _Step.content => _contentStep(),
                  _Step.reach => _reachStep(),
                  _Step.review => _reviewStep(),
                },
              ),
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: AppSpacing.pageHorizontal),
                child: Text(_error!, style: const TextStyle(color: AppColors.error, fontSize: 13)),
              ),
            Padding(
              padding: const EdgeInsets.all(AppSpacing.pageHorizontal),
              child: SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: _submitting ? null : _next,
                  child: _submitting
                      ? const SizedBox(height: 18, width: 18, child: CircularProgressIndicator(strokeWidth: 2))
                      : Text(switch (_step) {
                          _Step.content => 'Next',
                          _Step.reach => 'Next',
                          _Step.review => 'Pay \$${_tier.priceUsd}',
                        }),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _contentStep() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Ad type', style: AppTypography.sectionLabel),
        const SizedBox(height: 10),
        Row(
          children: [
            for (final k in _AdKind.values)
              Expanded(
                child: Padding(
                  padding: EdgeInsets.only(right: k == _AdKind.link ? 0 : 8),
                  child: _TypeChip(
                    label: k.name[0].toUpperCase() + k.name.substring(1),
                    icon: switch (k) {
                      _AdKind.video => Icons.videocam,
                      _AdKind.image => Icons.image,
                      _AdKind.link => Icons.link,
                    },
                    selected: _kind == k,
                    onTap: () => setState(() { _kind = k; _media = null; }),
                  ),
                ),
              ),
          ],
        ),
        const SizedBox(height: 20),
        if (_kind == _AdKind.link)
          TextField(
            controller: _linkController,
            keyboardType: TextInputType.url,
            decoration: const InputDecoration(hintText: 'https://your-link.com'),
            onChanged: (_) => setState(() {}),
          )
        else
          GestureDetector(
            onTap: _pickMedia,
            child: Container(
              height: 180,
              decoration: BoxDecoration(
                color: AppColors.surface,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: AppColors.border),
              ),
              alignment: Alignment.center,
              child: _media != null
                  ? (_kind == _AdKind.image
                      ? ClipRRect(borderRadius: BorderRadius.circular(14), child: Image.file(_media!, fit: BoxFit.cover, width: double.infinity))
                      : Column(mainAxisSize: MainAxisSize.min, children: [
                          const Icon(Icons.check_circle, color: AppColors.online, size: 34),
                          const SizedBox(height: 6),
                          Text('Video selected', style: AppTypography.sans(color: AppColors.muted)),
                        ]))
                  : Column(mainAxisSize: MainAxisSize.min, children: [
                      Icon(_kind == _AdKind.video ? Icons.videocam : Icons.image, color: AppColors.muted, size: 34),
                      const SizedBox(height: 8),
                      Text('Tap to choose a ${_kind.name}', style: AppTypography.sans(color: AppColors.muted)),
                    ]),
            ),
          ),
        const SizedBox(height: 16),
        TextField(
          controller: _captionController,
          maxLines: 2,
          decoration: const InputDecoration(hintText: 'Caption (optional)'),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _ctaController,
          decoration: const InputDecoration(hintText: 'Button text (e.g. Learn more)'),
        ),
      ],
    );
  }

  Widget _reachStep() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Choose how many people see your ad. It stops automatically once it reaches that many.',
            style: AppTypography.sans(fontSize: 14, color: AppColors.muted)),
        const SizedBox(height: 16),
        for (final t in kAdTiers) ...[
          _TierRow(tier: t, selected: _tier.reach == t.reach, onTap: () => setState(() => _tier = t)),
          const SizedBox(height: 10),
        ],

        const SizedBox(height: 20),
        Text('WHERE', style: AppTypography.sectionLabel),
        const SizedBox(height: 6),
        Text(
          _country == null
              ? 'Everywhere — your reach is spent across all countries'
              : 'Your whole reach is spent in $_country',
          style: AppTypography.sans(fontSize: 14, color: AppColors.muted),
        ),
        const SizedBox(height: 10),
        GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: _pickCountry,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
            decoration: BoxDecoration(
              color: AppColors.surface,
              borderRadius: BorderRadius.circular(AppRadii.md),
              border: Border.all(color: _country == null ? AppColors.border : AppColors.accent),
            ),
            child: Row(
              children: [
                const Icon(Icons.public, size: 20, color: AppColors.muted),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(_country ?? 'Everywhere',
                      style: AppTypography.sans(
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                          color: _country == null ? AppColors.muted : AppColors.text)),
                ),
                const Icon(Icons.chevron_right, color: AppColors.muted),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _reviewStep() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _reviewRow('Type', _kind.name[0].toUpperCase() + _kind.name.substring(1)),
        _reviewRow('Reach', '~${_tier.reachLabel} people'),
        _reviewRow('Price', '\$${_tier.priceUsd}'),
        _reviewRow('Where', _country ?? 'Everywhere'),
        if (_captionController.text.trim().isNotEmpty) _reviewRow('Caption', _captionController.text.trim()),
        if (_kind == _AdKind.link) _reviewRow('Link', _linkController.text.trim()),
        const SizedBox(height: 20),
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(color: AppColors.surface, borderRadius: BorderRadius.circular(12)),
          child: Row(children: [
            const Icon(Icons.info_outline, color: AppColors.muted, size: 20),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                'Your ad is reviewed after payment — usually within a day — before it goes live. Payment provider is being set up.',
                style: AppTypography.sans(fontSize: 13, color: AppColors.muted),
              ),
            ),
          ]),
        ),
      ],
    );
  }

  Widget _reviewRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(width: 90, child: Text(label, style: AppTypography.sans(fontSize: 14, color: AppColors.muted))),
          Expanded(child: Text(value, style: AppTypography.sans(fontSize: 14, fontWeight: FontWeight.w600))),
        ],
      ),
    );
  }
}

class _TypeChip extends StatelessWidget {
  const _TypeChip({required this.label, required this.icon, required this.selected, required this.onTap});
  final String label;
  final IconData icon;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 14),
        decoration: BoxDecoration(
          color: selected ? AppColors.chrome : AppColors.surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: selected ? AppColors.chrome : AppColors.border),
        ),
        child: Column(children: [
          Icon(icon, color: selected ? AppColors.onChrome : AppColors.text, size: 22),
          const SizedBox(height: 6),
          Text(label, style: AppTypography.sans(fontSize: 13, fontWeight: FontWeight.w600, color: selected ? AppColors.onChrome : AppColors.text)),
        ]),
      ),
    );
  }
}

class _TierRow extends StatelessWidget {
  const _TierRow({required this.tier, required this.selected, required this.onTap});
  final AdTier tier;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: selected ? AppColors.accent : AppColors.border, width: selected ? 2 : 1),
        ),
        child: Row(
          children: [
            Icon(selected ? Icons.radio_button_checked : Icons.radio_button_off,
                color: selected ? AppColors.accent : AppColors.muted, size: 22),
            const SizedBox(width: 14),
            Expanded(
              child: Text('~${tier.reachLabel} people',
                  style: AppTypography.sans(fontSize: 16, fontWeight: FontWeight.w700)),
            ),
            Text('\$${tier.priceUsd}',
                style: AppTypography.sans(fontSize: 16, fontWeight: FontWeight.w800, color: AppColors.accent)),
          ],
        ),
      ),
    );
  }
}
