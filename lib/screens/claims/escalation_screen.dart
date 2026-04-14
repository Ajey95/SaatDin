import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../models/claim_model.dart';
import '../../services/api_service.dart';
import '../../theme/app_colors.dart';

/// Modal sheet + dedicated screen for escalating a claim (Issue #9).
/// Call [EscalationSheet.show] to present over a claim card.
class EscalationSheet {
  EscalationSheet._();

  /// Show the escalation bottom-sheet for [claim]. Returns `true` if the
  /// escalation was submitted successfully.
  static Future<bool?> show(BuildContext context, Claim claim) {
    return showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      useSafeArea: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (_) => _EscalationSheetBody(claim: claim),
    );
  }
}

class _EscalationSheetBody extends StatefulWidget {
  const _EscalationSheetBody({required this.claim});
  final Claim claim;

  @override
  State<_EscalationSheetBody> createState() => _EscalationSheetBodyState();
}

class _EscalationSheetBodyState extends State<_EscalationSheetBody>
    with SingleTickerProviderStateMixin {
  final ApiService _apiService = ApiService();
  final _formKey = GlobalKey<FormState>();
  final _reasonController = TextEditingController();

  String _selectedReason = 'Delayed beyond SLA';
  final List<String> _reasonOptions = [
    'Delayed beyond SLA',
    'Incorrect assessment',
    'Missing documentation',
    'Underpaid settlement',
    'Other',
  ];

  _EscalateState _state = _EscalateState.idle;
  late final AnimationController _anim;
  late final Animation<double> _scale;

  @override
  void initState() {
    super.initState();
    _anim = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 600),
    );
    _scale = CurvedAnimation(parent: _anim, curve: Curves.elasticOut);
  }

  @override
  void dispose() {
    _reasonController.dispose();
    _anim.dispose();
    super.dispose();
  }

  Future<void> _submitEscalation() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;

    setState(() => _state = _EscalateState.loading);

    // Build rich description for the escalation claim
    final reason =
        '$_selectedReason – ${_reasonController.text.trim().isEmpty ? "No additional details" : _reasonController.text.trim()}';

    try {
      // Escalation is represented as a new claim of the same type with an
      // escalation prefix, hooking into the existing submit endpoint.
      await _apiService.escalateClaim(
        claimId: widget.claim.id,
        reason: reason,
      );

      if (!mounted) return;
      setState(() => _state = _EscalateState.success);
      _anim.forward();

      await Future<void>.delayed(const Duration(seconds: 2));
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } catch (_) {
      if (!mounted) return;
      setState(() => _state = _EscalateState.idle);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          backgroundColor: AppColors.error,
          behavior: SnackBarBehavior.floating,
          content: const Row(
            children: [
              Icon(Icons.error_outline, color: Colors.white, size: 18),
              SizedBox(width: 8),
              Text(
                'Escalation failed. Please try again.',
                style: TextStyle(color: Colors.white),
              ),
            ],
          ),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.fromLTRB(
        20,
        4,
        20,
        math.max(20.0, MediaQuery.of(context).viewInsets.bottom + 20),
      ),
      child: _state == _EscalateState.success
          ? _buildSuccess()
          : _buildForm(),
    );
  }

  Widget _buildForm() {
    final claim = widget.claim;
    final isLoading = _state == _EscalateState.loading;

    return Form(
      key: _formKey,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header
            Row(
              children: [
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: AppColors.errorLight,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: const Icon(
                    Icons.escalator_warning_rounded,
                    color: AppColors.error,
                    size: 22,
                  ),
                ),
                const SizedBox(width: 12),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Escalate Claim',
                      style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w800,
                        color: AppColors.textPrimary,
                      ),
                    ),
                    Text(
                      'Claim ${claim.id} · ${claim.typeShortName}',
                      style: const TextStyle(
                        fontSize: 12,
                        color: AppColors.textSecondary,
                      ),
                    ),
                  ],
                ),
              ],
            ),
            const SizedBox(height: 20),

            // SLA info banner
            _SlaBanner(claim: claim),
            const SizedBox(height: 20),

            // Reason selection
            const Text(
              'Escalation Reason',
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w700,
                color: AppColors.textPrimary,
              ),
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: _reasonOptions.map((r) {
                final sel = r == _selectedReason;
                return GestureDetector(
                  onTap: () => setState(() => _selectedReason = r),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 180),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 9,
                    ),
                    decoration: BoxDecoration(
                      color: sel
                          ? AppColors.error.withValues(alpha: 0.1)
                          : AppColors.surfaceLight,
                      borderRadius: BorderRadius.circular(24),
                      border: Border.all(
                        color: sel ? AppColors.error : AppColors.border,
                        width: sel ? 1.5 : 1,
                      ),
                    ),
                    child: Text(
                      r,
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color:
                            sel ? AppColors.error : AppColors.textSecondary,
                      ),
                    ),
                  ),
                );
              }).toList(),
            ),
            const SizedBox(height: 20),

            // Additional details
            const Text(
              'Additional Details (optional)',
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w700,
                color: AppColors.textPrimary,
              ),
            ),
            const SizedBox(height: 8),
            TextFormField(
              controller: _reasonController,
              maxLines: 3,
              decoration: InputDecoration(
                hintText:
                    'Describe why this claim needs escalation…',
                hintStyle: const TextStyle(
                  color: AppColors.textTertiary,
                  fontSize: 13,
                ),
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
                  borderSide: const BorderSide(
                    color: AppColors.error,
                    width: 1.5,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 24),

            // Action buttons
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed:
                        isLoading ? null : () => Navigator.of(context).pop(),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: AppColors.textSecondary,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                      ),
                      side: const BorderSide(color: AppColors.border),
                    ),
                    child: const Text('Cancel'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  flex: 2,
                  child: ElevatedButton(
                    onPressed: isLoading ? null : _submitEscalation,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppColors.error,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                      ),
                      elevation: 0,
                    ),
                    child: isLoading
                        ? const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.white,
                            ),
                          )
                        : const Text(
                            'Submit Escalation',
                            style: TextStyle(fontWeight: FontWeight.w700),
                          ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  Widget _buildSuccess() {
    return ScaleTransition(
      scale: _scale,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 40),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 80,
              height: 80,
              decoration: BoxDecoration(
                color: AppColors.errorLight,
                shape: BoxShape.circle,
              ),
              child: const Icon(
                Icons.check_circle_rounded,
                color: AppColors.error,
                size: 46,
              ),
            ),
            const SizedBox(height: 16),
            const Text(
              'Escalation Submitted',
              style: TextStyle(
                fontSize: 22,
                fontWeight: FontWeight.w800,
                color: AppColors.textPrimary,
              ),
            ),
            const SizedBox(height: 8),
            const Text(
              'A reviewer will assess your claim\nwithin the next 2 hours.',
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

// ─────────────────────────── SLA Banner ───────────────────────────

class _SlaBanner extends StatelessWidget {
  const _SlaBanner({required this.claim});
  final Claim claim;

  String get _slaMessage {
    final daysSinceSubmit =
        DateTime.now().difference(claim.date).inDays;
    if (daysSinceSubmit >= 7) {
      return 'This claim is ${daysSinceSubmit}d old. '
          'You are eligible for priority escalation.';
    }
    if (daysSinceSubmit >= 3) {
      return 'This claim has been open for $daysSinceSubmit days. '
          'Standard SLA is 5 business days.';
    }
    return 'Escalation available within the standard 5-day SLA window. '
        'Please provide a clear reason.';
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.infoLight,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.info.withValues(alpha: 0.3)),
      ),
      child: Row(
        children: [
          const Icon(Icons.schedule, color: AppColors.info, size: 18),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              _slaMessage,
              style: const TextStyle(
                fontSize: 12,
                color: AppColors.info,
                height: 1.4,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

enum _EscalateState { idle, loading, success }
