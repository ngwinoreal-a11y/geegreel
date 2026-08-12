import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../../core/network/api_client.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_radii.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_typography.dart';
import '../../../core/widgets/app_avatar.dart';
import '../../../core/widgets/country_picker.dart';
import '../../../core/widgets/seg_control.dart';
import '../../auth/application/auth_controller.dart';
import '../data/settings_repository.dart';
import '../../../core/widgets/top_toast.dart';

/// Ports index.html's settingsPage(): avatar, profile fields, privacy
/// (private + who-can-message / who-can-comment), notification toggles,
/// monetization, admin (staff only), password change, and account actions.
class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  late final TextEditingController _usernameController;
  late final TextEditingController _displayNameController;
  late final TextEditingController _bioController;
  late final TextEditingController _emailController;
  final _currentPwController = TextEditingController();
  final _newPwController = TextEditingController();

  bool _saving = false;
  bool _dirty = false;
  bool _uploadingAvatar = false;
  bool _changingPw = false;
  String? _pwError;

  late bool _isPrivate;
  late String _allowMessages;
  late String _allowComments;
  late bool _notifyLikes;
  late bool _notifyComments;
  late bool _notifyFollows;
  String? _country;

  /// Same picker the composer and signup use, so the name saved here is
  /// character-for-character the one an advertiser targets.
  Future<void> _pickCountry() async {
    final picked = await showCountryPicker(
      context,
      current: _country,
      noneLabel: 'Not set',
      noneSubtitle: "Don't say where I am",
    );
    if (picked == null || !mounted) return;
    final value = picked == kEverywhere ? null : picked;
    final previous = _country;
    _patch({'country': value ?? ''}, () => _country = value, () => _country = previous);
  }

  @override
  void initState() {
    super.initState();
    final me = ref.read(authControllerProvider).valueOrNull;
    _usernameController = TextEditingController(text: me?.username ?? '');
    _displayNameController = TextEditingController(text: me?.displayName ?? '');
    _bioController = TextEditingController(text: me?.bio ?? '');
    _emailController = TextEditingController(text: me?.email ?? '');
    _isPrivate = me?.isPrivate ?? false;
    _allowMessages = me?.allowMessages ?? 'everyone';
    _allowComments = me?.allowComments ?? 'everyone';
    _notifyLikes = me?.notifyLikes ?? true;
    _notifyComments = me?.notifyComments ?? true;
    _notifyFollows = me?.notifyFollows ?? true;
    _country = me?.country;
  }

  @override
  void dispose() {
    _usernameController.dispose();
    _displayNameController.dispose();
    _bioController.dispose();
    _emailController.dispose();
    _currentPwController.dispose();
    _newPwController.dispose();
    super.dispose();
  }

  /// Auto-saves a single privacy/notification field on toggle, reverting the
  /// optimistic UI change if the request fails.
  Future<void> _patch(Map<String, dynamic> fields, VoidCallback optimistic, VoidCallback revert) async {
    setState(optimistic);
    try {
      await ref.read(settingsRepositoryProvider).update(fields);
      ref.invalidate(authControllerProvider);
    } catch (_) {
      if (mounted) setState(revert);
    }
  }

  Future<void> _pickAndUploadAvatar() async {
    final picked = await ImagePicker().pickImage(source: ImageSource.gallery, maxWidth: 1024, imageQuality: 85);
    if (picked == null) return;
    setState(() => _uploadingAvatar = true);
    try {
      await ref.read(settingsRepositoryProvider).uploadAvatar(picked.path);
      ref.invalidate(authControllerProvider);
    } catch (_) {
      if (mounted) {
        showTopToast(context, "Couldn't update photo — try a smaller image");
      }
    } finally {
      if (mounted) setState(() => _uploadingAvatar = false);
    }
  }

  Future<void> _removeAvatar() async {
    setState(() => _uploadingAvatar = true);
    try {
      await ref.read(settingsRepositoryProvider).removeAvatar();
      ref.invalidate(authControllerProvider);
    } catch (_) {
    } finally {
      if (mounted) setState(() => _uploadingAvatar = false);
    }
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      await ref.read(settingsRepositoryProvider).update({
        'username': _usernameController.text.trim(),
        'displayName': _displayNameController.text.trim(),
        'bio': _bioController.text.trim(),
        'email': _emailController.text.trim(),
      });
      ref.invalidate(authControllerProvider);
      if (mounted) {
        setState(() { _saving = false; _dirty = false; });
        showTopToast(context, 'Saved');
      }
    } catch (_) {
      if (mounted) {
        setState(() => _saving = false);
        showTopToast(context, "Couldn't save — that username or email may be taken");
      }
    }
  }

  Future<void> _changePassword() async {
    if (_newPwController.text.length < 8) {
      setState(() => _pwError = 'New password must be at least 8 characters');
      return;
    }
    setState(() { _changingPw = true; _pwError = null; });
    try {
      await ref.read(settingsRepositoryProvider).changePassword(
            current: _currentPwController.text,
            next: _newPwController.text,
          );
      _currentPwController.clear();
      _newPwController.clear();
      if (mounted) {
        showTopToast(context, 'Password changed');
      }
    } catch (_) {
      if (mounted) setState(() => _pwError = 'Your current password is incorrect');
    } finally {
      if (mounted) setState(() => _changingPw = false);
    }
  }

  Future<void> _confirmDeleteAccount() async {
    final passwordController = TextEditingController();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: const Text('Delete account?'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('This permanently deletes your account and everything in it. Enter your password to confirm.'),
            const SizedBox(height: 12),
            TextField(controller: passwordController, obscureText: true, decoration: const InputDecoration(hintText: 'Password')),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(dialogContext).pop(false), child: const Text('Cancel')),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            style: TextButton.styleFrom(foregroundColor: AppColors.error),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;
    try {
      await ref.read(settingsRepositoryProvider).deleteAccount(passwordController.text);
      await ref.read(authControllerProvider.notifier).logout();
      if (context.mounted) context.go('/');
    } catch (_) {
      if (context.mounted) {
        showTopToast(context, "Couldn't delete account — check your password");
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final me = ref.watch(authControllerProvider).valueOrNull;

    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        padding: const EdgeInsets.all(AppSpacing.pageHorizontal),
        children: [
          // --- Avatar ---
          Center(
            child: Column(
              children: [
                GestureDetector(
                  onTap: _uploadingAvatar ? null : _pickAndUploadAvatar,
                  child: Stack(
                    clipBehavior: Clip.none,
                    children: [
                      AppAvatar(
                        size: 88,
                        imageUrl: me?.avatarUrl != null ? mediaUrl(me!.avatarUrl!) : null,
                        displayName: me?.displayName ?? '?',
                      ),
                      if (_uploadingAvatar)
                        const Positioned.fill(
                          child: DecoratedBox(
                            decoration: BoxDecoration(color: Colors.black54, shape: BoxShape.circle),
                            child: Center(child: SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))),
                          ),
                        ),
                      Positioned(
                        right: -2,
                        bottom: -2,
                        child: Container(
                          padding: const EdgeInsets.all(6),
                          decoration: const BoxDecoration(color: AppColors.chrome, shape: BoxShape.circle),
                          child: const Icon(Icons.camera_alt, size: 15, color: AppColors.onChrome),
                        ),
                      ),
                    ],
                  ),
                ),
                if (me?.avatarUrl != null)
                  TextButton(
                    onPressed: _uploadingAvatar ? null : _removeAvatar,
                    style: TextButton.styleFrom(foregroundColor: AppColors.muted),
                    child: const Text('Remove photo'),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 16),

          // --- Profile ---
          Text('PROFILE', style: AppTypography.sectionLabel),
          const SizedBox(height: 10),
          _label('Username'),
          TextField(controller: _usernameController, onChanged: (_) => setState(() => _dirty = true), decoration: const InputDecoration()),
          const SizedBox(height: 12),
          _label('Display name'),
          TextField(controller: _displayNameController, onChanged: (_) => setState(() => _dirty = true), decoration: const InputDecoration()),
          const SizedBox(height: 12),
          _label('Bio'),
          TextField(controller: _bioController, maxLines: 3, onChanged: (_) => setState(() => _dirty = true), decoration: const InputDecoration()),
          const SizedBox(height: 12),
          _label('Email'),
          TextField(controller: _emailController, keyboardType: TextInputType.emailAddress, onChanged: (_) => setState(() => _dirty = true), decoration: const InputDecoration()),
          const SizedBox(height: 12),
          // Country was asked once at signup and never again, so anyone who
          // joined before that step — or skipped it — had no country on their
          // account and no way to add one. Ads and videos aimed at a place
          // could never reach them. Saves immediately, like the toggles below.
          _label('Country'),
          InkWell(
            onTap: _pickCountry,
            borderRadius: BorderRadius.circular(AppRadii.md),
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 15),
              decoration: BoxDecoration(
                color: AppColors.surface,
                borderRadius: BorderRadius.circular(AppRadii.md),
              ),
              child: Row(children: [
                Expanded(
                  child: Text(
                    _country ?? 'Not set',
                    style: AppTypography.sans(
                      fontSize: 15,
                      // "Not set" is a placeholder, a real country is a value —
                      // they must not look the same.
                      color: _country == null ? AppColors.muted : AppColors.text,
                    ),
                  ),
                ),
                const Icon(Icons.expand_more, size: 20, color: AppColors.muted),
              ]),
            ),
          ),
          const SizedBox(height: 6),
          Text('Used to show you videos and ads meant for where you are',
              style: AppTypography.sans(fontSize: 12, color: AppColors.muted)),
          const SizedBox(height: 14),
          if (_dirty)
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(onPressed: _saving ? null : _save, child: Text(_saving ? 'Saving...' : 'Save changes')),
            ),

          const SizedBox(height: 24),
          // --- Privacy ---
          Text('PRIVACY', style: AppTypography.sectionLabel),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: Text('Private account', style: AppTypography.sans(fontSize: 14)),
            subtitle: Text('Only approved followers see your videos', style: AppTypography.sans(fontSize: 12, color: AppColors.muted)),
            value: _isPrivate,
            onChanged: (v) => _patch({'isPrivate': v}, () => _isPrivate = v, () => _isPrivate = !v),
          ),
          const SizedBox(height: 8),
          _label('Who can message you'),
          const SizedBox(height: 8),
          SegControl(
            labels: const ['Everyone', 'Followers', 'Nobody'],
            selectedIndex: _valueIndex(_allowMessages),
            onChanged: (i) {
              final v = _indexValue(i);
              _patch({'allowMessages': v}, () => _allowMessages = v, () => {});
            },
          ),
          const SizedBox(height: 14),
          _label('Who can comment'),
          const SizedBox(height: 8),
          SegControl(
            labels: const ['Everyone', 'Followers', 'Nobody'],
            selectedIndex: _valueIndex(_allowComments),
            onChanged: (i) {
              final v = _indexValue(i);
              _patch({'allowComments': v}, () => _allowComments = v, () => {});
            },
          ),

          const SizedBox(height: 24),
          // --- Notifications ---
          Text('NOTIFICATIONS', style: AppTypography.sectionLabel),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: Text('Likes', style: AppTypography.sans(fontSize: 14)),
            value: _notifyLikes,
            onChanged: (v) => _patch({'notifyLikes': v}, () => _notifyLikes = v, () => _notifyLikes = !v),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: Text('Comments', style: AppTypography.sans(fontSize: 14)),
            value: _notifyComments,
            onChanged: (v) => _patch({'notifyComments': v}, () => _notifyComments = v, () => _notifyComments = !v),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: Text('New followers', style: AppTypography.sans(fontSize: 14)),
            value: _notifyFollows,
            onChanged: (v) => _patch({'notifyFollows': v}, () => _notifyFollows = v, () => _notifyFollows = !v),
          ),
          // Push runs off the request path, so when it fails it fails silently
          // — "nothing arrived" with nowhere to look. This asks the server to
          // send one to this phone right now and reports what actually
          // happened, so a problem is diagnosable from the device itself.
          // The self-test row lived here while push was being brought up. Now
          // that notifications work it's removed: a "send yourself a test"
          // button in a shipped app just puts a stray notification in people's
          // trays. _testPush is kept for the next time push needs diagnosing.

          const SizedBox(height: 20),
          // --- Earning ---
          Text('EARNING', style: AppTypography.sectionLabel),
          const SizedBox(height: 8),
          _NavRow(label: 'Monetization', trailing: 'Check progress', onTap: () => context.push('/monetization')),
          _NavRow(label: 'Promote', trailing: 'Create ad', onTap: () => context.push('/promote')),
          _NavRow(label: 'My ads', trailing: 'Views & clicks', onTap: () => context.push('/my-ads')),

          // --- Staff ---
          if (me?.isStaff ?? false) ...[
            const SizedBox(height: 20),
            Text('STAFF', style: AppTypography.sectionLabel),
            const SizedBox(height: 8),
            _NavRow(label: 'Review ads', trailing: 'Approve / reject', onTap: () => context.push('/admin/ads')),
            _NavRow(
              label: 'Admin dashboard',
              trailing: me?.role ?? 'admin',
              // Straight to the admin panel, not the site's front page — the
              // bare origin dropped staff into the ordinary feed and left them
              // to find their way. `?open=admin` is the web app's own deep
              // link (handleDeepLink in index.html).
              onTap: () => launchUrl(
                Uri.parse('$kWebOrigin/?open=admin'),
                mode: LaunchMode.externalApplication,
              ),
            ),
          ],

          const SizedBox(height: 24),
          // --- Password ---
          Text('PASSWORD', style: AppTypography.sectionLabel),
          const SizedBox(height: 10),
          TextField(controller: _currentPwController, obscureText: true, decoration: const InputDecoration(hintText: 'Current password')),
          const SizedBox(height: 10),
          TextField(controller: _newPwController, obscureText: true, decoration: const InputDecoration(hintText: 'New password (min 8 characters)')),
          if (_pwError != null) ...[
            const SizedBox(height: 8),
            Text(_pwError!, style: const TextStyle(color: AppColors.error, fontSize: 13)),
          ],
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(onPressed: _changingPw ? null : _changePassword, child: Text(_changingPw ? 'Saving...' : 'Change password')),
          ),

          const SizedBox(height: 24),
          // --- Account ---
          Text('ACCOUNT', style: AppTypography.sectionLabel),
          const SizedBox(height: 8),
          OutlinedButton(
            onPressed: () async {
              await ref.read(settingsRepositoryProvider).signOutOtherDevices();
              if (context.mounted) {
                showTopToast(context, 'Signed out of other devices');
              }
            },
            child: const Text('Sign out of other devices'),
          ),
          const SizedBox(height: 8),
          OutlinedButton(
            onPressed: () async {
              await ref.read(authControllerProvider.notifier).logout();
              if (context.mounted) context.go('/');
            },
            child: const Text('Log out'),
          ),
          const SizedBox(height: 8),
          OutlinedButton(
            onPressed: _confirmDeleteAccount,
            style: OutlinedButton.styleFrom(foregroundColor: AppColors.error, side: const BorderSide(color: AppColors.danger)),
            child: const Text('Delete account'),
          ),

          const SizedBox(height: 28),
          Text('ABOUT', style: AppTypography.sectionLabel),
          const SizedBox(height: 4),
          Text('Belople · Version 1.0.0', style: AppTypography.sans(fontSize: 13, color: AppColors.muted)),
          const SizedBox(height: 20),
        ],
      ),
    );
  }

  Widget _label(String text) =>
      Padding(padding: const EdgeInsets.only(bottom: 6), child: Text(text, style: AppTypography.sans(fontSize: 12, color: AppColors.muted)));

  static int _valueIndex(String v) => switch (v) { 'followers' => 1, 'nobody' => 2, _ => 0 };
  static String _indexValue(int i) => switch (i) { 1 => 'followers', 2 => 'nobody', _ => 'everyone' };
}

class _NavRow extends StatelessWidget {
  const _NavRow({required this.label, required this.trailing, required this.onTap});
  final String label;
  final String trailing;
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
        ),
        child: Row(
          children: [
            Expanded(child: Text(label, style: AppTypography.sans(fontSize: 15, fontWeight: FontWeight.w600))),
            Text(trailing, style: AppTypography.sans(fontSize: 13, color: AppColors.muted)),
          ],
        ),
      ),
    );
  }
}
