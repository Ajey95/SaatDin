import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:sms_autofill/sms_autofill.dart';

import '../routes/app_routes.dart';
import '../services/api_service.dart';
import '../theme/app_colors.dart';

class OtpVerificationScreen extends StatefulWidget {
  const OtpVerificationScreen({super.key});

  @override
  State<OtpVerificationScreen> createState() => _OtpVerificationScreenState();
}

class _OtpVerificationScreenState extends State<OtpVerificationScreen>
    with CodeAutoFill {
  static const int _otpLength = 6;
  static const Color _verifyColor = AppColors.primary;

  final TextEditingController _otpController = TextEditingController();
  final FocusNode _otpFocusNode = FocusNode();
  final ApiService _apiService = ApiService();
  Timer? _resendTimer;
  Timer? _codeExpiryTimer;
  int _resendSecondsLeft = 120;
  int _codeExpiresSecondsLeft = 300;

  bool _isVerifying = false;
  bool _isResending = false;

  bool get _canVerify {
    return _otpValue.trim().length == _otpLength;
  }

  @override
  void initState() {
    super.initState();
    _otpController.addListener(() {
      if (mounted) setState(() {});
    });
    _startCodeExpiryCountdown();
    _startResendCountdown();
    _startOtpAutoFillListener();
  }

  Future<void> _startOtpAutoFillListener() async {
    try {
      listenForCode();
    } catch (_) {
      // Ignore if listener is unavailable on this platform/device.
    }
  }

  @override
  void codeUpdated() {
    final detected = code?.trim() ?? '';
    if (detected.isEmpty) return;
    final digitsOnly = detected.replaceAll(RegExp(r'[^0-9]'), '');
    if (digitsOnly.isEmpty) return;
    final capped = digitsOnly.length > _otpLength
        ? digitsOnly.substring(0, _otpLength)
        : digitsOnly;
    _otpController.text = capped;
    _otpController.selection = TextSelection.collapsed(offset: capped.length);
    if (mounted) {
      setState(() {});
    }
  }

  @override
  void dispose() {
    _resendTimer?.cancel();
    _codeExpiryTimer?.cancel();
    cancel();
    _otpController.dispose();
    _otpFocusNode.dispose();
    super.dispose();
  }

  String get _otpValue => _otpController.text;

  String get _resendTimeLabel {
    final minutes = (_resendSecondsLeft ~/ 60).toString().padLeft(2, '0');
    final seconds = (_resendSecondsLeft % 60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }

  String get _codeExpiryLabel {
    final minutes = (_codeExpiresSecondsLeft ~/ 60).toString().padLeft(2, '0');
    final seconds = (_codeExpiresSecondsLeft % 60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }

  void _startCodeExpiryCountdown() {
    _codeExpiryTimer?.cancel();
    _codeExpiresSecondsLeft = 300;

    _codeExpiryTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }
      if (_codeExpiresSecondsLeft <= 1) {
        setState(() {
          _codeExpiresSecondsLeft = 0;
        });
        timer.cancel();
        return;
      }
      setState(() {
        _codeExpiresSecondsLeft -= 1;
      });
    });
  }

  void _startResendCountdown() {
    _resendTimer?.cancel();
    _resendSecondsLeft = 120;

    _resendTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }
      if (_resendSecondsLeft <= 1) {
        setState(() {
          _resendSecondsLeft = 0;
        });
        timer.cancel();
        return;
      }
      setState(() {
        _resendSecondsLeft -= 1;
      });
    });
  }

  Future<void> _verifyOtp(String phone) async {
    if (!_canVerify || _isVerifying) return;

    setState(() {
      _isVerifying = true;
    });

    final ok = await _apiService.verifyOtp(phone, _otpValue.trim());

    if (!mounted) return;

    setState(() {
      _isVerifying = false;
    });

    if (!ok) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(_apiService.lastError ?? 'Invalid OTP. Please try again.'),
        ),
      );
      return;
    }

    Navigator.pushNamedAndRemoveUntil(
      context,
      AppRoutes.checkWorkerStatus,
      (route) => false,
      arguments: {'phone': phone},
    );
  }

  Future<void> _resendOtp(String phone) async {
    if (_isResending || _resendSecondsLeft > 0) return;

    _otpController.clear();

    setState(() {
      _isResending = true;
    });

    final ok = await _apiService.sendOtp(phone);

    if (!mounted) return;

    setState(() {
      _isResending = false;
    });

    if (ok) {
      _startResendCountdown();
      _startOtpAutoFillListener();
    }

    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          ok ? 'OTP sent again.' : (_apiService.lastError ?? 'Failed to resend OTP.'),
        ),
      ),
    );
  }



  Widget _buildDigitField(int index) {
    final hasDigit = index < _otpController.text.length;
    final digit = hasDigit ? _otpController.text[index] : '';
    final isActive = index == _otpController.text.length && index < _otpLength;

    return Expanded(
      child: Padding(
      padding: EdgeInsets.only(right: index == _otpLength - 1 ? 0 : 14),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              height: 56,
              child: Center(
                child: Text(
                  digit,
                  style: GoogleFonts.inter(
                    fontSize: 30,
                    fontWeight: FontWeight.w700,
                    color: const Color(0xFF1F2937),
                    height: 1,
                  ),
                ),
              ),
            ),
            AnimatedContainer(
              duration: const Duration(milliseconds: 140),
              height: 2,
              decoration: BoxDecoration(
                color: hasDigit || isActive ? _verifyColor : const Color(0xFFBFC5C7),
                borderRadius: BorderRadius.circular(999),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildOtpInput() {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => _otpFocusNode.requestFocus(),
      child: Stack(
        alignment: Alignment.center,
        children: [
          Row(
            children: List.generate(_otpLength, _buildDigitField),
          ),
          Positioned.fill(
            child: Opacity(
              opacity: 0.01,
              child: AutofillGroup(
                child: TextField(
                  controller: _otpController,
                  focusNode: _otpFocusNode,
                  autofocus: true,
                  keyboardType: TextInputType.number,
                  textInputAction: TextInputAction.done,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  maxLength: _otpLength,
                  autofillHints: const [AutofillHints.oneTimeCode],
                  showCursor: false,
                  onChanged: (value) {
                    if (value.length > _otpLength) {
                      _otpController.text = value.substring(0, _otpLength);
                      _otpController.selection = TextSelection.collapsed(
                        offset: _otpController.text.length,
                      );
                    }
                  },
                  decoration: const InputDecoration(
                    counterText: '',
                    border: InputBorder.none,
                    enabledBorder: InputBorder.none,
                    focusedBorder: InputBorder.none,
                    contentPadding: EdgeInsets.zero,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPrimaryButton(String phone) {
    return SizedBox(
      width: double.infinity,
      height: 54,
      child: ElevatedButton(
        onPressed: _canVerify && !_isVerifying ? () => _verifyOtp(phone) : null,
        style: ElevatedButton.styleFrom(
          backgroundColor: _verifyColor,
          foregroundColor: Colors.white,
          disabledBackgroundColor: const Color(0xFFD6DEDE),
          disabledForegroundColor: Colors.white,
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(28),
          ),
        ),
        child: Text(
          _isVerifying ? 'Verifying...' : 'Verify Code',
          style: GoogleFonts.inter(
            fontSize: 16,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
    );
  }

  Widget _buildResendButton() {
    final canResend = _resendSecondsLeft == 0;

    return SizedBox(
      width: double.infinity,
      height: 54,
      child: OutlinedButton(
        onPressed: canResend && !_isResending ? () => _resendOtp(_currentPhone!) : null,
        style: OutlinedButton.styleFrom(
          foregroundColor: _verifyColor,
          side: const BorderSide(color: _verifyColor, width: 1.2),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(28),
          ),
        ),
        child: Text(
          _isResending
              ? 'Resending...'
              : canResend
                  ? 'Resend Code'
                  : 'Resend Code in $_resendTimeLabel s',
          style: GoogleFonts.inter(
            fontSize: 15,
            fontWeight: FontWeight.w700,
            color: _verifyColor,
          ),
        ),
      ),
    );
  }

  String? _currentPhone;

  @override
  Widget build(BuildContext context) {
    final args =
        ModalRoute.of(context)?.settings.arguments as Map<String, dynamic>?;
    final phone = (args?['phone'] as String?)?.trim() ?? '';
    _currentPhone = phone;

    if (phone.isEmpty) {
      return Scaffold(
        backgroundColor: Colors.white,
        appBar: AppBar(
          backgroundColor: Colors.transparent,
          elevation: 0,
          foregroundColor: Colors.white,
        ),
        body: const Center(
          child: Text(
            'Phone number missing. Please restart onboarding.',
            style: TextStyle(color: Colors.white70),
          ),
        ),
      );
    }

    return Scaffold(
      backgroundColor: Colors.white,       appBar: AppBar(
         backgroundColor: Colors.white,
         elevation: 0,
         leading: IconButton(
           icon: const Icon(Icons.arrow_back, color: AppColors.textPrimary),
           onPressed: () => Navigator.pop(context),
         ),
       ),      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            return Center(
              child: Padding(
                padding: EdgeInsets.zero,
                child: ConstrainedBox(
                  constraints: BoxConstraints(
                    maxWidth: 430,
                    minHeight: constraints.maxHeight,
                  ),
                  child: Container(
                    width: double.infinity,
                    decoration: BoxDecoration(
                      color: Colors.white,
                    ),
                    child: Stack(
                      children: [
                        SingleChildScrollView(
                          padding: const EdgeInsets.fromLTRB(18, 24, 18, 18),
                          child: ConstrainedBox(
                            constraints: BoxConstraints(
                              minHeight: constraints.maxHeight - 24,
                            ),
                            child: IntrinsicHeight(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  const SizedBox(height: 32),
                                  Center(
                                    child: Image.asset(
                                      'assets/images/otp.png',
                                      width: 200,
                                      height: 200,
                                      fit: BoxFit.contain,
                                    ),
                                  ),
                                  const SizedBox(height: 48),
                                  Text(
                                    'Enter Verification Code',
                                    textAlign: TextAlign.center,
                                    style: GoogleFonts.inter(
                                      fontSize: 22,
                                      fontWeight: FontWeight.w800,
                                      color: AppColors.textPrimary,
                                      height: 1.15,
                                    ),
                                  ),
                                  const SizedBox(height: 12),
                                  Text(
                                    'We\'ve sent a code in your number',
                                    textAlign: TextAlign.center,
                                    style: GoogleFonts.inter(
                                      fontSize: 15,
                                      fontWeight: FontWeight.w500,
                                      color: AppColors.textSecondary,
                                      height: 1.35,
                                    ),
                                  ),
                                  const SizedBox(height: 4),
                                  Text.rich(
                                    TextSpan(
                                      style: GoogleFonts.inter(
                                        fontSize: 15,
                                        fontWeight: FontWeight.w500,
                                        color: AppColors.textSecondary,
                                        height: 1.35,
                                      ),
                                      children: [
                                        const TextSpan(text: 'This code will expire in '),
                                        TextSpan(
                                          text: '$_codeExpiryLabel s',
                                          style: const TextStyle(
                                            color: _verifyColor,
                                            fontWeight: FontWeight.w700,
                                          ),
                                        ),
                                      ],
                                    ),
                                    textAlign: TextAlign.center,
                                  ),
                                  const SizedBox(height: 26),
                                  _buildOtpInput(),
                                  const Spacer(),
                                  _buildPrimaryButton(phone),
                                  const SizedBox(height: 12),
                                  _buildResendButton(),
                                  const SizedBox(height: 12),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}
