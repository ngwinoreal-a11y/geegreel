import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_typography.dart';
import '../../../core/widgets/skeleton.dart';
import '../application/auth_controller.dart';
import '../data/signup_options.dart';

/// Ports index.html's authScreen(): login is one form; signup is a short
/// 3-step wizard — account basics, then location, then interests (last,
/// since it's the one people skip most). Nothing is sent until the final
/// step submits, so an abandoned signup leaves no half-created account.
/// Google OAuth is deferred — see the plan's Phase 2 backend gap.
class AuthScreen extends ConsumerStatefulWidget {
  const AuthScreen({super.key});

  @override
  ConsumerState<AuthScreen> createState() => _AuthScreenState();
}

enum _Step { basics, location, interests }

class _AuthScreenState extends ConsumerState<AuthScreen> {
  bool _isSignup = false;
  _Step _step = _Step.basics;

  final _formKey = GlobalKey<FormState>();
  final _usernameOrEmailController = TextEditingController();
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  final _displayNameController = TextEditingController();
  final _cityController = TextEditingController();
  String? _country;
  final Set<String> _interests = {};
  String? _errorText;

  @override
  void dispose() {
    _usernameOrEmailController.dispose();
    _emailController.dispose();
    _passwordController.dispose();
    _displayNameController.dispose();
    _cityController.dispose();
    super.dispose();
  }

  void _swapMode() {
    setState(() {
      _isSignup = !_isSignup;
      _step = _Step.basics;
      _errorText = null;
    });
  }

  void _back() {
    setState(() {
      _errorText = null;
      _step = _Step.values[_step.index - 1];
    });
  }

  /// Advances one wizard step, or on the last step submits the whole thing.
  Future<void> _next() async {
    setState(() => _errorText = null);

    if (!_isSignup) {
      await _submitLogin();
      return;
    }

    // Signup: validate only the current step, then advance or submit.
    if (_step == _Step.basics) {
      if (!(_formKey.currentState?.validate() ?? false)) return;
      setState(() => _step = _Step.location);
      return;
    }
    if (_step == _Step.location) {
      setState(() => _step = _Step.interests);
      return;
    }
    await _submitSignup();
  }

  Future<void> _submitLogin() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    await ref.read(authControllerProvider.notifier).login(
          _usernameOrEmailController.text.trim(),
          _passwordController.text,
        );
    _handleResult();
  }

  Future<void> _submitSignup() async {
    await ref.read(authControllerProvider.notifier).signup(
          username: _usernameOrEmailController.text.trim(),
          email: _emailController.text.trim(),
          password: _passwordController.text,
          displayName: _displayNameController.text.trim().isEmpty
              ? null
              : _displayNameController.text.trim(),
          country: _country,
          city: _cityController.text.trim().isEmpty ? null : _cityController.text.trim(),
          interests: _interests.isEmpty ? null : _interests.toList(),
        );
    _handleResult();
  }

  void _handleResult() {
    final authState = ref.read(authControllerProvider);
    if (authState.hasError && mounted) {
      setState(() => _errorText = _messageFor(authState.error));
    }
  }

  String _messageFor(Object? error) {
    final message = error.toString();
    if (message.contains('already') || message.contains('taken')) {
      return 'That username or email is already in use.';
    }
    if (message.contains('401') || message.contains('Invalid')) {
      return 'Incorrect email/username or password.';
    }
    return "Couldn't connect — check your internet and try again.";
  }

  String _buttonLabel() {
    if (!_isSignup) return 'Log in';
    if (_step != _Step.interests) return 'Next';
    return _interests.isEmpty ? 'Skip for now' : 'Create account';
  }

  String _heading() {
    if (!_isSignup) return 'Welcome back';
    return switch (_step) {
      _Step.basics => 'Create account',
      _Step.location => 'Where are you?',
      _Step.interests => 'What do you like?',
    };
  }

  String _subheading() {
    if (!_isSignup) return 'Log in to keep watching';
    return switch (_step) {
      _Step.basics => 'Start sharing your videos',
      _Step.location => 'Helps us show you relevant content',
      _Step.interests => 'Pick up to $kMaxInterests — you can change these later',
    };
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(authControllerProvider, (previous, next) {
      if (next.valueOrNull != null && Navigator.of(context).canPop()) {
        Navigator.of(context).pop();
      }
    });
    final authState = ref.watch(authControllerProvider);
    final isLoading = authState.isLoading;

    return Scaffold(
      backgroundColor: AppColors.bg,
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.pageHorizontal,
            40,
            AppSpacing.pageHorizontal,
            40,
          ),
          child: Form(
            key: _formKey,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Belople', style: AppTypography.display(fontSize: 30)),
                const SizedBox(height: 6),
                Text(_heading(), style: AppTypography.sans(fontSize: 18, color: AppColors.text)),
                const SizedBox(height: 2),
                Text(_subheading(),
                    style: AppTypography.sans(fontSize: 14, color: AppColors.muted)),
                const SizedBox(height: 24),

                if (_isSignup) ...[
                  _StepDots(current: _step.index),
                  const SizedBox(height: 20),
                ],

                ..._stepFields(),

                if (_errorText != null) ...[
                  const SizedBox(height: 10),
                  Text(_errorText!, style: const TextStyle(color: AppColors.error, fontSize: 13)),
                ],

                const SizedBox(height: 22),
                ElevatedButton(
                  onPressed: isLoading ? null : _next,
                  child: isLoading
                      ? const SizedBox(
                          height: 18,
                          width: 18,
                          child: LoadingDots(color: AppColors.bg, size: 5),
                        )
                      : Text(_buttonLabel()),
                ),

                if (_isSignup && _step != _Step.basics) ...[
                  const SizedBox(height: 10),
                  Center(
                    child: TextButton(
                      onPressed: isLoading ? null : _back,
                      child: const Text('Back', style: TextStyle(color: AppColors.muted)),
                    ),
                  ),
                ],

                const SizedBox(height: 10),
                Center(
                  child: TextButton(
                    onPressed: isLoading ? null : _swapMode,
                    child: Text(
                      _isSignup
                          ? 'Already have an account? Log in'
                          : "Don't have an account? Sign up",
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  List<Widget> _stepFields() {
    if (!_isSignup) {
      return [
        TextFormField(
          controller: _usernameOrEmailController,
          decoration: const InputDecoration(hintText: 'Email or username'),
          validator: (v) => (v == null || v.trim().isEmpty) ? 'Required' : null,
        ),
        const SizedBox(height: 12),
        TextFormField(
          controller: _passwordController,
          obscureText: true,
          decoration: const InputDecoration(hintText: 'Password'),
          validator: (v) => (v == null || v.isEmpty) ? 'Required' : null,
        ),
      ];
    }

    return switch (_step) {
      _Step.basics => [
          TextFormField(
            controller: _displayNameController,
            decoration: const InputDecoration(hintText: 'Display name (optional)'),
          ),
          const SizedBox(height: 12),
          TextFormField(
            controller: _usernameOrEmailController,
            decoration: const InputDecoration(hintText: 'Username'),
            validator: (v) {
              if (v == null || v.trim().isEmpty) return 'Required';
              if (!RegExp(r'^[a-zA-Z0-9_]{3,20}$').hasMatch(v.trim())) {
                return '3-20 characters: letters, numbers, underscore';
              }
              return null;
            },
          ),
          const SizedBox(height: 12),
          TextFormField(
            controller: _emailController,
            keyboardType: TextInputType.emailAddress,
            decoration: const InputDecoration(hintText: 'Email'),
            validator: (v) =>
                (v == null || !v.contains('@')) ? 'Enter a valid email' : null,
          ),
          const SizedBox(height: 12),
          TextFormField(
            controller: _passwordController,
            obscureText: true,
            decoration: const InputDecoration(hintText: 'Password'),
            validator: (v) {
              if (v == null || v.isEmpty) return 'Required';
              if (v.length < 8) return 'At least 8 characters';
              return null;
            },
          ),
        ],
      _Step.location => [
          DropdownButtonFormField<String>(
            initialValue: _country,
            isExpanded: true,
            decoration: const InputDecoration(hintText: 'Country (optional)'),
            hint: const Text('Country (optional)', style: TextStyle(color: AppColors.muted)),
            dropdownColor: AppColors.surface,
            items: [
              for (final c in kCountries)
                DropdownMenuItem(
                  value: c,
                  child: Text(c,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: AppColors.text)),
                ),
            ],
            onChanged: (v) => setState(() => _country = v),
          ),
          const SizedBox(height: 12),
          TextFormField(
            controller: _cityController,
            decoration: const InputDecoration(hintText: 'City (optional)'),
          ),
        ],
      _Step.interests => [
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final interest in kInterests)
                _InterestChip(
                  label: interest,
                  selected: _interests.contains(interest),
                  onTap: () => setState(() {
                    if (_interests.contains(interest)) {
                      _interests.remove(interest);
                    } else if (_interests.length < kMaxInterests) {
                      _interests.add(interest);
                    }
                  }),
                ),
            ],
          ),
        ],
    };
  }
}

/// The three-dot progress indicator shown across the signup wizard —
/// mirrors index.html's `.step-dots` (filled = current, faded = done/todo).
class _StepDots extends StatelessWidget {
  const _StepDots({required this.current});
  final int current;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        for (var i = 0; i < _Step.values.length; i++) ...[
          AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            width: i == current ? 22 : 8,
            height: 8,
            decoration: BoxDecoration(
              color: i <= current ? AppColors.text : AppColors.border,
              borderRadius: BorderRadius.circular(4),
            ),
          ),
          if (i < _Step.values.length - 1) const SizedBox(width: 6),
        ],
      ],
    );
  }
}

/// Ports design's `.interest-chip` — a pill that fills white when selected.
class _InterestChip extends StatelessWidget {
  const _InterestChip({required this.label, required this.selected, required this.onTap});
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        decoration: BoxDecoration(
          color: selected ? AppColors.chrome : AppColors.surface,
          borderRadius: BorderRadius.circular(22),
          border: Border.all(color: selected ? AppColors.chrome : AppColors.border),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w600,
            color: selected ? AppColors.onChrome : AppColors.text,
          ),
        ),
      ),
    );
  }
}
