import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../data/parental_control_service.dart';
import '../theme/app_colors.dart';

/// Shows a dialog asking the user to enter a 4-digit PIN to unlock
/// adult content.
///
/// Returns `true` if the PIN was verified successfully, `false` otherwise.
Future<bool> showPinVerifyDialog(BuildContext context) async {
  final result = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (_) => const _PinVerifyDialog(),
  );
  return result ?? false;
}

/// Shows a dialog for setting or changing the parental control PIN.
///
/// If [isChanging] is `true`, the dialog title says "Change PIN" instead
/// of "Set PIN". Returns `true` if a new PIN was saved.
Future<bool> showPinSetDialog(BuildContext context,
    {bool isChanging = false}) async {
  final result = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _PinSetDialog(isChanging: isChanging),
  );
  return result ?? false;
}

// =============================================================================
// Verify dialog (enter existing PIN)
// =============================================================================

class _PinVerifyDialog extends StatefulWidget {
  const _PinVerifyDialog();

  @override
  State<_PinVerifyDialog> createState() => _PinVerifyDialogState();
}

class _PinVerifyDialogState extends State<_PinVerifyDialog> {
  final _controller = TextEditingController();
  final _focusNode = FocusNode();
  String? _error;
  bool _verifying = false;

  @override
  void initState() {
    super.initState();
    // Auto-focus the text field when the dialog appears.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _focusNode.requestFocus();
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final pin = _controller.text.trim();
    if (pin.length != 4) {
      setState(() => _error = 'PIN must be 4 digits');
      return;
    }

    setState(() {
      _verifying = true;
      _error = null;
    });

    final ok =
        await ParentalControlService.instance.verifyPin(pin);

    if (!mounted) return;

    if (ok) {
      Navigator.of(context).pop(true);
    } else {
      setState(() {
        _verifying = false;
        _error = 'Incorrect PIN';
        _controller.clear();
      });
      _focusNode.requestFocus();
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: AppColors.bgElevated,
      title: const Row(
        children: [
          Icon(Icons.lock_outline, color: AppColors.accentPrimary, size: 24),
          SizedBox(width: 8),
          Text(
            'Enter PIN',
            style: TextStyle(color: AppColors.textPrimary),
          ),
        ],
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text(
            'Enter your 4-digit PIN to unlock adult content.',
            style: TextStyle(color: AppColors.textSecondary, fontSize: 14),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _controller,
            focusNode: _focusNode,
            keyboardType: TextInputType.number,
            obscureText: true,
            obscuringCharacter: '*',
            maxLength: 4,
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: AppColors.textPrimary,
              fontSize: 28,
              letterSpacing: 12,
            ),
            inputFormatters: [
              FilteringTextInputFormatter.digitsOnly,
            ],
            decoration: InputDecoration(
              counterText: '',
              filled: true,
              fillColor: AppColors.bgSurface,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
                borderSide: BorderSide.none,
              ),
              errorText: _error,
              errorStyle: const TextStyle(color: Colors.redAccent),
            ),
            onSubmitted: (_) => _submit(),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text(
            'Cancel',
            style: TextStyle(color: AppColors.textSecondary),
          ),
        ),
        TextButton(
          onPressed: _verifying ? null : _submit,
          child: _verifying
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: AppColors.accentPrimary,
                  ),
                )
              : const Text(
                  'Unlock',
                  style: TextStyle(color: AppColors.accentPrimary),
                ),
        ),
      ],
    );
  }
}

// =============================================================================
// Set / Change PIN dialog (enter + confirm)
// =============================================================================

class _PinSetDialog extends StatefulWidget {
  const _PinSetDialog({required this.isChanging});

  final bool isChanging;

  @override
  State<_PinSetDialog> createState() => _PinSetDialogState();
}

class _PinSetDialogState extends State<_PinSetDialog> {
  final _controller = TextEditingController();
  final _confirmController = TextEditingController();
  final _focusNode = FocusNode();
  final _confirmFocusNode = FocusNode();
  String? _error;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _focusNode.requestFocus();
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    _confirmController.dispose();
    _focusNode.dispose();
    _confirmFocusNode.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final pin = _controller.text.trim();
    final confirm = _confirmController.text.trim();

    if (pin.length != 4) {
      setState(() => _error = 'PIN must be 4 digits');
      return;
    }
    if (pin != confirm) {
      setState(() => _error = 'PINs do not match');
      return;
    }

    setState(() {
      _saving = true;
      _error = null;
    });

    await ParentalControlService.instance.setPin(pin);

    if (!mounted) return;
    Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final title = widget.isChanging ? 'Change PIN' : 'Set PIN';

    return AlertDialog(
      backgroundColor: AppColors.bgElevated,
      title: Row(
        children: [
          const Icon(Icons.shield_outlined,
              color: AppColors.accentPrimary, size: 24),
          const SizedBox(width: 8),
          Text(title,
              style: const TextStyle(color: AppColors.textPrimary)),
        ],
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text(
            'Set a 4-digit PIN to restrict adult content. '
            'Content rated 18+ or containing "XXX" will be hidden '
            'until the PIN is entered.',
            style:
                const TextStyle(color: AppColors.textSecondary, fontSize: 14),
          ),
          const SizedBox(height: 16),
          // -- New PIN --
          TextField(
            controller: _controller,
            focusNode: _focusNode,
            keyboardType: TextInputType.number,
            obscureText: true,
            obscuringCharacter: '*',
            maxLength: 4,
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: AppColors.textPrimary,
              fontSize: 28,
              letterSpacing: 12,
            ),
            inputFormatters: [
              FilteringTextInputFormatter.digitsOnly,
            ],
            decoration: InputDecoration(
              counterText: '',
              hintText: 'PIN',
              hintStyle: TextStyle(
                color: AppColors.textSecondary.withValues(alpha: 0.5),
                fontSize: 16,
                letterSpacing: 2,
              ),
              filled: true,
              fillColor: AppColors.bgSurface,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
                borderSide: BorderSide.none,
              ),
            ),
            onChanged: (_) {
              if (_controller.text.length == 4) {
                _confirmFocusNode.requestFocus();
              }
            },
          ),
          const SizedBox(height: 12),
          // -- Confirm PIN --
          TextField(
            controller: _confirmController,
            focusNode: _confirmFocusNode,
            keyboardType: TextInputType.number,
            obscureText: true,
            obscuringCharacter: '*',
            maxLength: 4,
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: AppColors.textPrimary,
              fontSize: 28,
              letterSpacing: 12,
            ),
            inputFormatters: [
              FilteringTextInputFormatter.digitsOnly,
            ],
            decoration: InputDecoration(
              counterText: '',
              hintText: 'Confirm',
              hintStyle: TextStyle(
                color: AppColors.textSecondary.withValues(alpha: 0.5),
                fontSize: 16,
                letterSpacing: 2,
              ),
              filled: true,
              fillColor: AppColors.bgSurface,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
                borderSide: BorderSide.none,
              ),
              errorText: _error,
              errorStyle: const TextStyle(color: Colors.redAccent),
            ),
            onSubmitted: (_) => _submit(),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text(
            'Cancel',
            style: TextStyle(color: AppColors.textSecondary),
          ),
        ),
        TextButton(
          onPressed: _saving ? null : _submit,
          child: _saving
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: AppColors.accentPrimary,
                  ),
                )
              : Text(
                  title,
                  style: const TextStyle(color: AppColors.accentPrimary),
                ),
        ),
      ],
    );
  }
}
