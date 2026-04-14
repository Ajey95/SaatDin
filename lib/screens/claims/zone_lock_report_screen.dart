import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../services/api_service.dart';
import '../../theme/app_colors.dart';

/// Full-screen form to submit a ZoneLock manual report (Issue #8).
class ZoneLockReportScreen extends StatefulWidget {
  const ZoneLockReportScreen({super.key});

  @override
  State<ZoneLockReportScreen> createState() => _ZoneLockReportScreenState();
}

class _ZoneLockReportScreenState extends State<ZoneLockReportScreen>
    with SingleTickerProviderStateMixin {
  final ApiService _apiService = ApiService();
  final _formKey = GlobalKey<FormState>();
  final _descriptionController = TextEditingController();
  final _locationController = TextEditingController();

  // Duration options
  String _selectedDuration = '< 30 min';
  final List<String> _durationOptions = [
    '< 30 min',
    '30–60 min',
    '1–2 hrs',
    '> 2 hrs',
  ];

  // Impact options
  String _selectedImpact = 'Partial';
  final List<String> _impactOptions = ['Partial', 'Full', 'Critical'];

  _SubmitState _submitState = _SubmitState.idle;
  late final AnimationController _successAnimController;
  late final Animation<double> _successScale;

  @override
  void initState() {
    super.initState();
    _successAnimController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 600),
    );
    _successScale = CurvedAnimation(
      parent: _successAnimController,
      curve: Curves.elasticOut,
    );
  }

  @override
  void dispose() {
    _descriptionController.dispose();
    _locationController.dispose();
    _successAnimController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;

    setState(() => _submitState = _SubmitState.loading);

    final description =
        'ZoneLock Report\n'
        'Location: ${_locationController.text.trim()}\n'
        'Duration: $_selectedDuration\n'
        'Impact: $_selectedImpact\n'
        'Details: ${_descriptionController.text.trim()}';

    try {
      await _apiService.submitZoneLockReport(
        description: description,
      );

      if (!mounted) return;
      setState(() => _submitState = _SubmitState.success);
      _successAnimController.forward();

      await Future<void>.delayed(const Duration(seconds: 2));
      if (!mounted) return;
      Navigator.of(context).pop(true); // pop with success flag
    } catch (e) {
      if (!mounted) return;
      setState(() => _submitState = _SubmitState.idle);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          backgroundColor: AppColors.error,
          behavior: SnackBarBehavior.floating,
          content: Row(
            children: [
              const Icon(Icons.error_outline, color: Colors.white, size: 18),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Submission failed. Please try again.',
                  style: const TextStyle(color: Colors.white),
                ),
              ),
            ],
          ),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.scaffoldBackground,
      body: Stack(
        children: [
          // Decorative background gradient top
          const Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: SizedBox(
              height: 220,
              child: CustomPaint(painter: _ZoneLockHeaderPainter()),
            ),
          ),

          SafeArea(
            child: _submitState == _SubmitState.success
                ? _buildSuccessView()
                : _buildFormView(),
          ),
        ],
      ),
    );
  }

  Widget _buildFormView() {
    final isLoading = _submitState == _SubmitState.loading;
    return SingleChildScrollView(
      padding: EdgeInsets.only(
        left: 20,
        right: 20,
        bottom: math.max(20.0, MediaQuery.of(context).viewInsets.bottom + 20),
      ),
      child: Form(
        key: _formKey,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SizedBox(height: 16),

            // Back + title row
            Row(
              children: [
                _IconBtn(
                  icon: Icons.arrow_back,
                  onTap: () => Navigator.of(context).pop(),
                ),
                const SizedBox(width: 12),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: const [
                    Text(
                      'ZoneLock Report',
                      style: TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.w800,
                        color: AppColors.textPrimary,
                        letterSpacing: -0.4,
                      ),
                    ),
                    Text(
                      'Manual zone-block incident submission',
                      style: TextStyle(
                        fontSize: 12,
                        color: AppColors.textSecondary,
                      ),
                    ),
                  ],
                ),
              ],
            ),
            const SizedBox(height: 24),

            // Info banner
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: AppColors.warningLight,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(
                  color: AppColors.warning.withValues(alpha: 0.4),
                ),
              ),
              child: Row(
                children: [
                  const Icon(
                    Icons.info_outline,
                    color: AppColors.warning,
                    size: 20,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'Use this form when your delivery zone is blocked by '
                      'geo-restrictions or platform-level zone closures.',
                      style: TextStyle(
                        fontSize: 12,
                        color: AppColors.warning.withValues(alpha: 0.85),
                        height: 1.4,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 24),

            _SectionLabel(label: 'Affected Location / Zone'),
            const SizedBox(height: 8),
            _StyledTextField(
              controller: _locationController,
              hint: 'e.g. Koramangala, Zone-4',
              icon: Icons.location_on_outlined,
              validator: (v) =>
                  (v == null || v.trim().isEmpty) ? 'Location is required' : null,
            ),
            const SizedBox(height: 20),

            _SectionLabel(label: 'Block Duration'),
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: _durationOptions.map((d) {
                final sel = d == _selectedDuration;
                return GestureDetector(
                  onTap: () => setState(() => _selectedDuration = d),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 200),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 10,
                    ),
                    decoration: BoxDecoration(
                      color: sel ? AppColors.primary : AppColors.surfaceLight,
                      borderRadius: BorderRadius.circular(24),
                      border: Border.all(
                        color: sel
                            ? AppColors.primary
                            : AppColors.border,
                      ),
                    ),
                    child: Text(
                      d,
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color:
                            sel ? Colors.white : AppColors.textSecondary,
                      ),
                    ),
                  ),
                );
              }).toList(),
            ),
            const SizedBox(height: 20),

            _SectionLabel(label: 'Impact Level'),
            const SizedBox(height: 10),
            Row(
              children: _impactOptions.map((imp) {
                final sel = imp == _selectedImpact;
                final color = imp == 'Critical'
                    ? AppColors.error
                    : imp == 'Full'
                        ? AppColors.warning
                        : AppColors.primary;
                return Padding(
                  padding: const EdgeInsets.only(right: 10),
                  child: GestureDetector(
                    onTap: () => setState(() => _selectedImpact = imp),
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 200),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 18,
                        vertical: 10,
                      ),
                      decoration: BoxDecoration(
                        color: sel
                            ? color.withValues(alpha: 0.12)
                            : AppColors.surfaceLight,
                        borderRadius: BorderRadius.circular(24),
                        border: Border.all(
                          color: sel ? color : AppColors.border,
                          width: sel ? 1.5 : 1,
                        ),
                      ),
                      child: Text(
                        imp,
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: sel ? color : AppColors.textSecondary,
                        ),
                      ),
                    ),
                  ),
                );
              }).toList(),
            ),
            const SizedBox(height: 20),

            _SectionLabel(label: 'Describe What Happened'),
            const SizedBox(height: 8),
            _StyledTextField(
              controller: _descriptionController,
              hint: 'Explain the zone block situation in detail…',
              icon: Icons.edit_note,
              maxLines: 4,
              validator: (v) =>
                  (v == null || v.trim().isEmpty)
                      ? 'Description is required'
                      : null,
            ),
            const SizedBox(height: 32),

            // SLA Disclaimer
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: AppColors.accentLight,
                borderRadius: BorderRadius.circular(14),
              ),
              child: Row(
                children: [
                  const Icon(
                    Icons.schedule_outlined,
                    color: AppColors.primary,
                    size: 18,
                  ),
                  const SizedBox(width: 10),
                  const Expanded(
                    child: Text(
                      'Reports are reviewed within 2 hours. You will be '
                      'notified once your claim is processed.',
                      style: TextStyle(
                        fontSize: 12,
                        color: AppColors.primaryDark,
                        height: 1.4,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 24),

            // Submit button
            SizedBox(
              width: double.infinity,
              height: 52,
              child: ElevatedButton(
                onPressed: isLoading ? null : _submit,
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.primary,
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                  ),
                  elevation: 0,
                ),
                child: isLoading
                    ? const SizedBox(
                        width: 22,
                        height: 22,
                        child: CircularProgressIndicator(
                          strokeWidth: 2.5,
                          color: Colors.white,
                        ),
                      )
                    : const Text(
                        'Submit ZoneLock Report',
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
              ),
            ),
            const SizedBox(height: 12),
          ],
        ),
      ),
    );
  }

  Widget _buildSuccessView() {
    return Center(
      child: ScaleTransition(
        scale: _successScale,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 90,
              height: 90,
              decoration: BoxDecoration(
                color: AppColors.accentLight,
                shape: BoxShape.circle,
              ),
              child: const Icon(
                Icons.check_circle_rounded,
                color: AppColors.primary,
                size: 52,
              ),
            ),
            const SizedBox(height: 20),
            const Text(
              'Report Submitted!',
              style: TextStyle(
                fontSize: 24,
                fontWeight: FontWeight.w800,
                color: AppColors.textPrimary,
              ),
            ),
            const SizedBox(height: 8),
            const Text(
              'Your ZoneLock report has been received.\nCorroborated reports are auto-confirmed, otherwise review completes within 2 hours.',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 14,
                color: AppColors.textSecondary,
                height: 1.5,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────── Helpers ───────────────────────────

enum _SubmitState { idle, loading, success }

class _SectionLabel extends StatelessWidget {
  const _SectionLabel({required this.label});
  final String label;

  @override
  Widget build(BuildContext context) {
    return Text(
      label,
      style: const TextStyle(
        fontSize: 14,
        fontWeight: FontWeight.w700,
        color: AppColors.textPrimary,
      ),
    );
  }
}

class _StyledTextField extends StatelessWidget {
  const _StyledTextField({
    required this.controller,
    required this.hint,
    required this.icon,
    this.maxLines = 1,
    this.validator,
  });

  final TextEditingController controller;
  final String hint;
  final IconData icon;
  final int maxLines;
  final FormFieldValidator<String>? validator;

  @override
  Widget build(BuildContext context) {
    return TextFormField(
      controller: controller,
      maxLines: maxLines,
      validator: validator,
      decoration: InputDecoration(
        hintText: hint,
        hintStyle: const TextStyle(color: AppColors.textTertiary, fontSize: 13),
        prefixIcon: Icon(icon, color: AppColors.textTertiary, size: 20),
        filled: true,
        fillColor: AppColors.cardBackground,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 16,
          vertical: 14,
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: const BorderSide(color: AppColors.border),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: const BorderSide(color: AppColors.border),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: const BorderSide(color: AppColors.primary, width: 1.5),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: const BorderSide(color: AppColors.error),
        ),
      ),
    );
  }
}

class _IconBtn extends StatelessWidget {
  const _IconBtn({required this.icon, required this.onTap});
  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: onTap,
      child: Container(
        width: 42,
        height: 42,
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.2),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Colors.white.withValues(alpha: 0.3)),
        ),
        child: Icon(icon, size: 20, color: AppColors.textPrimary),
      ),
    );
  }
}

class _ZoneLockHeaderPainter extends CustomPainter {
  const _ZoneLockHeaderPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final bgPaint = Paint()
      ..shader = const LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [Color(0xFFE7F8F6), Color(0xFFF0F9F8), Color(0xFFF8FBFF)],
      ).createShader(Rect.fromLTWH(0, 0, size.width, size.height));
    canvas.drawRect(
        Rect.fromLTWH(0, 0, size.width, size.height), bgPaint);

    final shapePaint = Paint()
      ..color = AppColors.primary.withValues(alpha: 0.08);
    final path = Path()
      ..moveTo(-20, size.height * 0.7)
      ..lineTo(size.width * 0.5, size.height * 0.5)
      ..lineTo(size.width + 30, size.height * 0.8)
      ..lineTo(size.width + 30, size.height)
      ..lineTo(-20, size.height)
      ..close();
    canvas.drawPath(path, shapePaint);

    final ringPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5
      ..color = AppColors.primary.withValues(alpha: 0.12);
    canvas.drawCircle(
        Offset(size.width * 0.85, size.height * 0.2), 40, ringPaint);
    canvas.drawCircle(
        Offset(size.width * 0.1, size.height * 0.6), 28, ringPaint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
