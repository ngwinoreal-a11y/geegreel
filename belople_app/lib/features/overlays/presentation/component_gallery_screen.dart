import 'package:flutter/material.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_radii.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_typography.dart';
import '../../../core/widgets/app_avatar.dart';
import '../../../core/widgets/bottom_nav_pill.dart';
import '../../../core/widgets/pressable.dart';
import '../../../core/widgets/seg_control.dart';
import '../../../core/widgets/skeleton.dart';

/// Phase 0 verification screen (see the plan's "Verification" section):
/// every extracted token/component in one place, for a side-by-side
/// screenshot comparison against the live web app before any real screen
/// gets built on top of these primitives. Not part of the shipped app's
/// navigation — remove or gate behind a debug flag once Phase 1 lands.
class ComponentGalleryScreen extends StatefulWidget {
  const ComponentGalleryScreen({super.key});

  @override
  State<ComponentGalleryScreen> createState() => _ComponentGalleryScreenState();
}

class _ComponentGalleryScreenState extends State<ComponentGalleryScreen> {
  int _navIndex = 0;
  int _segIndex = 0;
  int _feedTabIndex = 1;
  bool _switchOn = true;
  final Set<int> _selectedInterests = {0, 2};

  static const _interests = [
    'Comedy', 'Music', 'Sports', 'Gaming', 'Food', 'Dance',
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bg,
      body: Stack(
        children: [
          ListView(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.pageHorizontal,
              56,
              AppSpacing.pageHorizontal,
              140,
            ),
            children: [
              Text('Belople', style: AppTypography.pageHeading),
              const SizedBox(height: 4),
              Text(
                'Component gallery — Phase 0 token check',
                style: AppTypography.sans(color: AppColors.muted, fontSize: 13),
              ),
              _section('Typography'),
              Text('Display / Space Grotesk 800', style: AppTypography.display()),
              const SizedBox(height: 6),
              Text('Sans / Inter body text', style: AppTypography.sans(fontSize: 15)),
              const SizedBox(height: 6),
              Text('Mono / IBM Plex Mono 128', style: AppTypography.mono(fontSize: 18)),

              _section('Buttons'),
              ElevatedButton(onPressed: () {}, child: const Text('Continue')),
              const SizedBox(height: 10),
              ElevatedButton(onPressed: null, child: const Text('Disabled')),
              const SizedBox(height: 10),
              TextButton(onPressed: () {}, child: const Text('Plain button')),

              _section('Avatars'),
              Row(
                children: [
                  const AppAvatar(size: 46, displayName: 'Kim'),
                  const SizedBox(width: 12),
                  const AppAvatar(
                    size: 52,
                    displayName: 'A',
                    borderColor: Colors.white,
                    borderWidth: 2,
                  ),
                  const SizedBox(width: 12),
                  AppAvatar(
                    size: 60,
                    displayName: 'B',
                    backgroundColor: AppColors.chrome,
                    textColor: AppColors.onChrome,
                  ),
                ],
              ),

              _section('Field'),
              const TextField(decoration: InputDecoration(hintText: 'Username')),

              _section('Switch'),
              Row(
                children: [
                  Text('Private account', style: AppTypography.sans(fontSize: 14)),
                  const Spacer(),
                  Switch(value: _switchOn, onChanged: (v) => setState(() => _switchOn = v)),
                ],
              ),

              _section('Segmented control (.seg)'),
              SegControl(
                labels: const ['Following', 'Followers', 'Friends'],
                selectedIndex: _segIndex,
                onChanged: (i) => setState(() => _segIndex = i),
              ),

              _section('Feed tabs (floating, over video)'),
              Container(
                height: 64,
                width: double.infinity,
                color: AppColors.raised,
                alignment: Alignment.center,
                child: FeedTabs(
                  labels: const ['Following', 'For you', 'Public'],
                  selectedIndex: _feedTabIndex,
                  onChanged: (i) => setState(() => _feedTabIndex = i),
                ),
              ),

              _section('Interest chips'),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (var i = 0; i < _interests.length; i++)
                    InterestChip(
                      label: _interests[i],
                      selected: _selectedInterests.contains(i),
                      onTap: () => setState(() {
                        _selectedInterests.contains(i)
                            ? _selectedInterests.remove(i)
                            : _selectedInterests.add(i);
                      }),
                    ),
                ],
              ),

              _section('Skeleton loading'),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Skeleton.avatar(size: 44),
                  const SizedBox(width: 12),
                  const Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Skeleton(height: 12),
                        SizedBox(height: 7),
                        Skeleton(width: 120, height: 12),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              const SizedBox(width: 90, child: Skeleton.cell()),

              _section('Loading dots / spinner'),
              const Row(
                children: [
                  LoadingDots(),
                  SizedBox(width: 24),
                  AppSpinner(size: 22),
                ],
              ),

              _section('Badges'),
              Row(
                children: [
                  _badgePreview('3'),
                  const SizedBox(width: 16),
                  _badgePreview(null),
                ],
              ),

              _section('Pressable (tap feedback)'),
              Pressable(
                onTap: () {},
                borderRadius: BorderRadius.circular(AppRadii.md),
                child: Container(
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  width: double.infinity,
                  color: AppColors.surface,
                  alignment: Alignment.center,
                  child: Text('Tap and hold', style: AppTypography.sans()),
                ),
              ),
            ],
          ),

          // Bottom nav pill preview, pinned like the real shell will be.
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: BottomNavPill(
              items: const [
                (icon: Icons.mail_outline, label: 'Messages'),
                (icon: Icons.home_rounded, label: 'Feed'),
              ],
              activeIndex: _navIndex,
              onTap: (i) => setState(() => _navIndex = i),
              fabIcon: Icons.add,
              onFabTap: () {},
            ),
          ),
        ],
      ),
    );
  }

  Widget _badgePreview(String? count) {
    return Container(
      width: 46,
      height: 46,
      decoration: const BoxDecoration(color: AppColors.navBg, shape: BoxShape.circle),
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          const Center(child: Icon(Icons.notifications_outlined, color: Colors.white, size: 20)),
          Positioned(
            top: -2,
            right: -2,
            child: Container(
              constraints: const BoxConstraints(minWidth: 18),
              height: 18,
              padding: const EdgeInsets.symmetric(horizontal: 5),
              decoration: BoxDecoration(
                color: AppColors.badge,
                borderRadius: BorderRadius.circular(9),
                border: Border.all(color: AppColors.navBg, width: 2),
              ),
              alignment: Alignment.center,
              child: count == null
                  ? null
                  : Text(
                      count,
                      style: AppTypography.sans(
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        color: Colors.white,
                      ),
                    ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _section(String title) {
    return Padding(
      padding: const EdgeInsets.only(top: 22, bottom: 8),
      child: Text(title.toUpperCase(), style: AppTypography.sectionLabel),
    );
  }
}
