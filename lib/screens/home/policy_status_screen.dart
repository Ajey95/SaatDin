import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../models/plan_model.dart';
import '../../models/user_model.dart';
import '../../services/api_service.dart';
import '../../theme/app_colors.dart';

class CoverageStatusScreen extends StatefulWidget {
  const CoverageStatusScreen({super.key});

  @override
  State<CoverageStatusScreen> createState() => _CoverageStatusScreenState();
}

class _CoverageStatusScreenState extends State<CoverageStatusScreen> {
  final ApiService _apiService = ApiService();
  final DateFormat _dayLabelFormat = DateFormat('MMM d');

  bool _isLoading = true;
  User _user = const User.empty();
  InsurancePlan _activePlan = const InsurancePlan(
    name: 'Standard',
    weeklyPremium: 0,
    perTriggerPayout: 0,
    maxDaysPerWeek: 0,
    isPopular: false,
  );
  String _cycleStartDate = '';
  String _cycleEndDate = '';
  String _paidOnDate = '';
  int _daysLeft = 0;
  double _amountPaidThisWeek = 0;
  String _paidVia = '';

  @override
  void initState() {
    super.initState();
    _loadCoverageStatus();
  }

  Future<void> _loadCoverageStatus() async {
    User user = const User.empty();
    Map<String, dynamic> policy = <String, dynamic>{};
    Map<String, dynamic> payoutDashboard = <String, dynamic>{};

    try {
      user = await _apiService.getProfile('me');
    } catch (_) {
      user = const User.empty();
    }

    try {
      policy = await _apiService.getPolicy('me');
    } catch (_) {
      policy = <String, dynamic>{};
    }

    try {
      payoutDashboard = await _apiService.getPayoutDashboard();
    } catch (_) {
      payoutDashboard = <String, dynamic>{};
    }

    final plan = InsurancePlan(
      name: _coerceString(policy['plan'], fallback: user.plan.isEmpty ? 'Standard' : user.plan),
      weeklyPremium: (policy['weeklyPremium'] as num? ?? 0).toInt(),
      perTriggerPayout: (policy['perTriggerPayout'] as num? ?? 0).toInt(),
      maxDaysPerWeek: (policy['maxDaysPerWeek'] as num? ?? 0).toInt(),
      isPopular: false,
    );

    final cycleStartDate = _coerceString(policy['cycleStartDate']);
    final cycleEndDate = _coerceString(policy['cycleEndDate'], fallback: _coerceString(policy['nextBillingDate']));
    final paidOnDate = _coerceString(policy['paidOnDate'], fallback: cycleStartDate);
    final daysLeft = (policy['daysLeft'] as num? ?? 0).toInt();
    final amountPaidThisWeek = (policy['amountPaidThisWeek'] as num? ?? policy['weeklyPremium'] as num? ?? 0).toDouble();

    String paidVia = _coerceString(payoutDashboard['primaryUpi']);
    if (paidVia.isEmpty) {
      paidVia = _coerceString(payoutDashboard['backupUpi']);
    }
    if (paidVia.isEmpty) {
      paidVia = 'Not configured';
    }

    if (!mounted) return;
    setState(() {
      _user = user;
      _activePlan = plan;
      _cycleStartDate = cycleStartDate;
      _cycleEndDate = cycleEndDate;
      _paidOnDate = paidOnDate;
      _daysLeft = daysLeft;
      _amountPaidThisWeek = amountPaidThisWeek;
      _paidVia = paidVia;
      _isLoading = false;
    });
  }

  String _coerceString(Object? value, {String fallback = ''}) {
    final parsed = value?.toString().trim() ?? '';
    return parsed.isEmpty ? fallback : parsed;
  }

  String _zoneLabel() {
    final zone = _user.zone.trim();
    final zonePincode = _user.zonePincode.trim();
    if (zone.isEmpty && zonePincode.isEmpty) {
      return 'Zone not set';
    }
    if (zone.isEmpty) {
      return zonePincode;
    }
    return zone;
  }

  String _platformLabel() {
    final platform = _user.platform.trim();
    return platform.isEmpty ? 'Not set' : platform;
  }

  String _dateLabel(String value) {
    final parsed = DateTime.tryParse(value);
    if (parsed == null) {
      return value.isEmpty ? 'Not set' : value;
    }
    return _dayLabelFormat.format(parsed.toLocal());
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF7F4ED),
      body: SafeArea(
        child: _isLoading
            ? const Center(child: CircularProgressIndicator())
            : SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(18, 10, 18, 20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Align(
                      alignment: Alignment.centerLeft,
                      child: _BackButton(
                        onTap: () => Navigator.of(context).pop(),
                      ),
                    ),
                    const SizedBox(height: 18),
                    Center(
                      child: Container(
                        width: 82,
                        height: 82,
                        decoration: const BoxDecoration(
                          color: Color(0xFFEAF7F0),
                          shape: BoxShape.circle,
                        ),
                        child: Center(
                          child: Container(
                            width: 50,
                            height: 50,
                            decoration: const BoxDecoration(
                              color: AppColors.primary,
                              shape: BoxShape.circle,
                            ),
                            child: const Icon(
                              Icons.check_rounded,
                              color: Colors.white,
                              size: 30,
                            ),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 14),
                    const Text(
                      "You're covered!",
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 24,
                        fontWeight: FontWeight.w800,
                        color: AppColors.textPrimary,
                        height: 1.05,
                        letterSpacing: -0.4,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      '₹${_amountPaidThisWeek.toInt()} debited. ${_activePlan.name} plan active from\ntoday.',
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        fontSize: 14,
                        color: AppColors.textSecondary,
                        height: 1.25,
                      ),
                    ),
                    const SizedBox(height: 16),
                    Container(
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(22),
                        border: Border.all(color: AppColors.border),
                      ),
                      child: Column(
                        children: [
                          _DetailRow(
                            label: 'Plan',
                            value: _activePlan.name,
                          ),
                          _DetailRow(
                            label: 'Start date',
                            value: _dateLabel(_cycleStartDate),
                          ),
                          _DetailRow(
                            label: 'End date',
                            value: _dateLabel(_cycleEndDate),
                          ),
                          _DetailRow(
                            label: 'Amount paid this week',
                            value: '₹${_amountPaidThisWeek.toInt()}',
                            valueColor: AppColors.primary,
                          ),
                          _DetailRow(
                            label: 'Max days/week',
                            value: '${_activePlan.maxDaysPerWeek} days',
                          ),
                          _DetailRow(
                            label: 'Days left',
                            value: '$_daysLeft days',
                          ),
                          _DetailRow(
                            label: 'Zone',
                            value: _zoneLabel(),
                          ),
                          _DetailRow(
                            label: 'Platform',
                            value: _platformLabel(),
                          ),
                          _DetailRow(
                            label: 'Paid on',
                            value: _dateLabel(_paidOnDate),
                          ),
                          _DetailRow(
                            label: 'Paid via',
                            value: _paidVia,
                            isLast: true,
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 14),
                    Center(
                      child: RichText(
                        text: TextSpan(
                          style: const TextStyle(
                            fontSize: 11,
                            color: AppColors.textSecondary,
                            height: 1.2,
                          ),
                          children: [
                            const TextSpan(text: 'Next auto-debit: '),
                            TextSpan(
                              text: _dateLabel(_cycleEndDate),
                              style: const TextStyle(
                                color: AppColors.textPrimary,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            TextSpan(
                              text: ' · ₹${_amountPaidThisWeek.toInt()}',
                              style: const TextStyle(
                                color: AppColors.textPrimary,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
      ),
    );
  }
}

class _BackButton extends StatelessWidget {
  const _BackButton({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 40,
        height: 40,
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppColors.border),
        ),
        child: const Icon(
          Icons.arrow_back_ios_new_rounded,
          size: 16,
          color: AppColors.textPrimary,
        ),
      ),
    );
  }
}

class _DetailRow extends StatelessWidget {
  const _DetailRow({
    required this.label,
    required this.value,
    this.valueColor,
    this.isLast = false,
  });

  final String label;
  final String value;
  final Color? valueColor;
  final bool isLast;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        border: Border(
          bottom: isLast ? BorderSide.none : const BorderSide(color: Color(0xFFEAE5DE)),
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Text(
              label,
              style: const TextStyle(
                fontSize: 13,
                color: AppColors.textSecondary,
                height: 1.2,
              ),
            ),
          ),
          const SizedBox(width: 12),
          Flexible(
            child: Text(
              value,
              textAlign: TextAlign.right,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w700,
                color: valueColor ?? AppColors.textPrimary,
                height: 1.2,
              ),
            ),
          ),
        ],
      ),
    );
  }
}