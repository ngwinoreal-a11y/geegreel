import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';
import '../../../core/network/api_client.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_typography.dart';
import '../../../core/widgets/app_avatar.dart';
import '../../auth/application/auth_controller.dart';
import '../data/settings_repository.dart';

/// Ports index.html's settingsPage(): profile edit fields auto-save on
/// change, sign-out. Privacy toggles / notification prefs / monetization /
/// admin entry points / account deletion land as their own screens exist to
/// link to.
class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  late final TextEditingController _displayNameController;
  late final TextEditingController _bioController;
  bool _saving = false;
  bool _dirty = false;
  bool _uploadingAvatar = false;
  late bool _isPrivate;

  @override
  void initState() {
    super.initState();
    final me = ref.read(authControllerProvider).valueOrNull;
    _displayNameController = TextEditingController(text: me?.displayName ?? '');
    _bioController = TextEditingController(text: me?.bio ?? '');
    _isPrivate = me?.isPrivate ?? false;
  }

  Future<void> _toggleField(String key, bool value, void Function(bool) apply) async {
    final previous = value;
    setState(() => apply(!previous));
    try {
      await ref.read(settingsRepositoryProvider).update({key: !previous});
      ref.invalidate(authControllerProvider);
    } catch (_) {
      if (mounted) setState(() => apply(previous));
    }
  }

  @override
  void dispose() {
    _displayNameController.dispose();
    _bioController.dispose();
    super.dispose();
  }

  Future<void> _pickAndUploadAvatar() async {
    final picked = await ImagePicker().pickImage(
      source: ImageSource.gallery,
      maxWidth: 1024,
      imageQuality: 85,
    );
    if (picked == null) return;
    setState(() => _uploadingAvatar = true);
    try {
      await ref.read(settingsRepositoryProvider).uploadAvatar(picked.path);
      ref.invalidate(authControllerProvider);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text("Couldn't update photo — try a smaller image")));
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
      // Best-effort; leave the current photo on failure.
    } finally {
      if (mounted) setState(() => _uploadingAvatar = false);
    }
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      await ref.read(settingsRepositoryProvider).update({
        'displayName': _displayNameController.text.trim(),
        'bio': _bioController.text.trim(),
      });
      ref.invalidate(authControllerProvider);
      if (mounted) setState(() { _saving = false; _dirty = false; });
    } catch (_) {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _changePassword(BuildContext context) async {
    final currentController = TextEditingController();
    final newController = TextEditingController();
    final formKey = GlobalKey<FormState>();
    var submitting = false;
    String? error;

    await showDialog<void>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialogState) => AlertDialog(
          backgroundColor: AppColors.surface,
          title: const Text('Change password'),
          content: Form(
            key: formKey,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextFormField(
                  controller: currentController,
                  obscureText: true,
                  decoration: const InputDecoration(hintText: 'Current password'),
                  validator: (v) => (v == null || v.isEmpty) ? 'Required' : null,
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: newController,
                  obscureText: true,
                  decoration: const InputDecoration(hintText: 'New password'),
                  validator: (v) =>
                      (v == null || v.length < 8) ? 'At least 8 characters' : null,
                ),
                if (error != null) ...[
                  const SizedBox(height: 10),
                  Text(error!, style: const TextStyle(color: AppColors.error, fontSize: 13)),
                ],
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: submitting ? null : () => Navigator.of(dialogContext).pop(),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: submitting
                  ? null
                  : () async {
                      if (!(formKey.currentState?.validate() ?? false)) return;
                      setDialogState(() { submitting = true; error = null; });
                      try {
                        await ref.read(settingsRepositoryProvider).changePassword(
                              current: currentController.text,
                              next: newController.text,
                            );
                        if (dialogContext.mounted) Navigator.of(dialogContext).pop();
                        if (context.mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(content: Text('Password changed')));
                        }
                      } catch (_) {
                        setDialogState(() {
                          submitting = false;
                          error = 'Your current password is incorrect';
                        });
                      }
                    },
              child: Text(submitting ? 'Saving...' : 'Save'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _confirmDeleteAccount(BuildContext context) async {
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
            TextField(
              controller: passwordController,
              obscureText: true,
              decoration: const InputDecoration(hintText: 'Password'),
            ),
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
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text("Couldn't delete account — check your password")));
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
          Text('PROFILE', style: AppTypography.sectionLabel),
          const SizedBox(height: 14),
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
                            decoration: BoxDecoration(
                              color: Colors.black54,
                              shape: BoxShape.circle,
                            ),
                            child: Center(
                              child: SizedBox(
                                width: 22,
                                height: 22,
                                child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                              ),
                            ),
                          ),
                        ),
                      Positioned(
                        right: -2,
                        bottom: -2,
                        child: Container(
                          padding: const EdgeInsets.all(6),
                          decoration: const BoxDecoration(
                            color: AppColors.chrome,
                            shape: BoxShape.circle,
                          ),
                          child: const Icon(Icons.camera_alt, size: 15, color: AppColors.onChrome),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 8),
                TextButton(
                  onPressed: _uploadingAvatar ? null : _pickAndUploadAvatar,
                  child: const Text('Change photo'),
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
          const SizedBox(height: 10),
          TextField(
            controller: _displayNameController,
            onChanged: (_) => setState(() => _dirty = true),
            decoration: const InputDecoration(hintText: 'Display name'),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _bioController,
            onChanged: (_) => setState(() => _dirty = true),
            maxLines: 3,
            decoration: const InputDecoration(hintText: 'Bio'),
          ),
          const SizedBox(height: 12),
          if (_dirty)
            ElevatedButton(
              onPressed: _saving ? null : _save,
              child: Text(_saving ? 'Saving...' : 'Save changes'),
            ),

          const SizedBox(height: 28),
          Text('PRIVACY', style: AppTypography.sectionLabel),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: Text('Private account', style: AppTypography.sans(fontSize: 14)),
            subtitle: Text('Approve who can follow you', style: AppTypography.sans(fontSize: 12, color: AppColors.muted)),
            value: _isPrivate,
            onChanged: (_) => _toggleField(
              'isPrivate',
              _isPrivate,
              (v) => _isPrivate = v,
            ),
          ),

          const SizedBox(height: 20),
          Text('ACCOUNT', style: AppTypography.sectionLabel),
          const SizedBox(height: 6),
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(me?.email ?? '', style: AppTypography.sans(fontSize: 14, color: AppColors.muted)),
            subtitle: const Text('Signed in'),
          ),
          const SizedBox(height: 4),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.lock_outline, color: AppColors.text),
            title: Text('Change password', style: AppTypography.sans(fontSize: 14)),
            trailing: const Icon(Icons.chevron_right, color: AppColors.muted),
            onTap: () => _changePassword(context),
          ),
          const SizedBox(height: 8),
          OutlinedButton(
            onPressed: () async {
              await ref.read(authControllerProvider.notifier).logout();
              if (context.mounted) context.go('/');
            },
            child: const Text('Log out'),
          ),
          const SizedBox(height: 24),
          TextButton(
            onPressed: () => _confirmDeleteAccount(context),
            style: TextButton.styleFrom(foregroundColor: AppColors.error),
            child: const Text('Delete account'),
          ),
        ],
      ),
    );
  }
}
