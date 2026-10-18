import 'dart:async';
import 'package:flutter/material.dart';
import 'package:tgcloud/services/app_lock_service.dart';
import 'package:tgcloud/services/database_service.dart';
import 'package:tgcloud/theme/app_theme.dart';
import 'package:tgcloud/widgets/adaptive.dart';

class LockScreen extends StatefulWidget {
  final DatabaseService databaseService;
  final VoidCallback onUnlocked;

  const LockScreen({
    super.key,
    required this.databaseService,
    required this.onUnlocked,
  });

  @override
  State<LockScreen> createState() => _LockScreenState();
}

class _LockScreenState extends State<LockScreen> {
  String _enteredPin = '';
  String _correctPin = '123456';
  int _failedAttempts = 0;
  int _lockoutSeconds = 0;
  Timer? _lockoutTimer;
  bool _canBiometric = false;
  bool _bioEnabled = false;

  @override
  void initState() {
    super.initState();
    _initLock();
  }

  @override
  void dispose() {
    _lockoutTimer?.cancel();
    super.dispose();
  }

  Future<void> _initLock() async {
    final pin = await widget.databaseService.getSetting('user_pin');
    if (pin != null && pin.isNotEmpty) {
      _correctPin = pin;
    }
    _bioEnabled = await AppLockService.isBiometricEnabled(widget.databaseService);
    _canBiometric = await AppLockService.canUseBiometric();

    if (mounted) {
      setState(() {});
    }

    if (_bioEnabled && _canBiometric) {
      _triggerBiometric();
    }
  }

  Future<void> _triggerBiometric() async {
    if (_lockoutSeconds > 0) return;
    final ok = await AppLockService.authenticateBiometric();
    if (ok && mounted) {
      widget.onUnlocked();
    }
  }

  void _onDigitPressed(String digit) {
    if (_lockoutSeconds > 0 || _enteredPin.length >= 6) return;

    setState(() {
      _enteredPin += digit;
    });

    if (_enteredPin.length == 6) {
      _verifyPin();
    }
  }

  void _onBackspacePressed() {
    if (_lockoutSeconds > 0 || _enteredPin.isEmpty) return;
    setState(() {
      _enteredPin = _enteredPin.substring(0, _enteredPin.length - 1);
    });
  }

  void _verifyPin() {
    if (_enteredPin == _correctPin) {
      widget.onUnlocked();
    } else {
      _failedAttempts++;
      setState(() {
        _enteredPin = '';
      });

      if (_failedAttempts >= 5) {
        _startLockout(60);
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('PIN salah ($_failedAttempts/5)'),
            backgroundColor: AppTheme.danger,
            duration: const Duration(seconds: 1),
          ),
        );
      }
    }
  }

  void _startLockout(int seconds) {
    setState(() {
      _lockoutSeconds = seconds;
    });
    _lockoutTimer?.cancel();
    _lockoutTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }
      if (_lockoutSeconds <= 1) {
        timer.cancel();
        setState(() {
          _lockoutSeconds = 0;
          _failedAttempts = 0;
        });
      } else {
        setState(() {
          _lockoutSeconds--;
        });
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final locked = _lockoutSeconds > 0;

    return Scaffold(
      backgroundColor: AppTheme.background,
      body: SafeArea(
        child: CenteredConstrained(
          maxWidth: 400,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 20),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Spacer(flex: 1),
                Container(
                  padding: const EdgeInsets.all(18),
                  decoration: BoxDecoration(
                    color: AppTheme.surface,
                    shape: BoxShape.circle,
                    border: Border.all(color: AppTheme.border),
                  ),
                  child: const Icon(
                    Icons.lock_rounded,
                    color: AppTheme.primary,
                    size: 42,
                  ),
                ),
                const SizedBox(height: 20),
                const Text(
                  'TGCloud Terkunci',
                  style: TextStyle(
                    color: AppTheme.textPrimary,
                    fontSize: 22,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  locked
                      ? 'Terlalu banyak percobaan. Tunggu $_lockoutSeconds detik.'
                      : 'Masukkan 6 digit PIN untuk membuka aplikasi',
                  style: TextStyle(
                    color: locked ? AppTheme.danger : AppTheme.textMuted,
                    fontSize: 13,
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 28),
                // Indikator 6 digit
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: List.generate(6, (index) {
                    final filled = index < _enteredPin.length;
                    return Container(
                      margin: const EdgeInsets.symmetric(horizontal: 8),
                      width: 14,
                      height: 14,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: filled ? AppTheme.primary : AppTheme.surfaceLight,
                        border: Border.all(
                          color: filled ? AppTheme.primary : AppTheme.border,
                        ),
                      ),
                    );
                  }),
                ),
                const Spacer(flex: 1),
                // Numpad 1-9, biometrik / kosong, 0, hapus
                _buildNumpad(locked),
                const Spacer(flex: 1),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildNumpad(bool locked) {
    return Column(
      children: [
        for (var row = 0; row < 3; row++)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                for (var col = 1; col <= 3; col++)
                  _buildDigitButton((row * 3 + col).toString(), locked),
              ],
            ),
          ),
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              // Tombol biometrik bila ada
              _canBiometric && _bioEnabled
                  ? _buildActionButton(
                      icon: Icons.fingerprint_rounded,
                      onPressed: locked ? null : _triggerBiometric,
                    )
                  : const SizedBox(width: 72, height: 72),
              _buildDigitButton('0', locked),
              _buildActionButton(
                icon: Icons.backspace_outlined,
                onPressed: locked || _enteredPin.isEmpty ? null : _onBackspacePressed,
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildDigitButton(String digit, bool locked) {
    return SizedBox(
      width: 72,
      height: 72,
      child: Material(
        color: AppTheme.surface,
        shape: const CircleBorder(),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: locked ? null : () => _onDigitPressed(digit),
          child: Center(
            child: Text(
              digit,
              style: TextStyle(
                color: locked ? AppTheme.textMuted : AppTheme.textPrimary,
                fontSize: 24,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildActionButton({
    required IconData icon,
    required VoidCallback? onPressed,
  }) {
    return SizedBox(
      width: 72,
      height: 72,
      child: Material(
        color: Colors.transparent,
        shape: const CircleBorder(),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onPressed,
          child: Center(
            child: Icon(
              icon,
              color: onPressed != null ? AppTheme.primary : AppTheme.textMuted,
              size: 28,
            ),
          ),
        ),
      ),
    );
  }
}
