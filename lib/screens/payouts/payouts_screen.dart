import 'package:flutter/material.dart';
import 'dart:math' as math;
import 'package:intl/intl.dart';

import '../../theme/app_colors.dart';
import '../../models/user_model.dart';
import '../../services/api_service.dart';
import '../../services/tab_router.dart';

class PayoutsScreen extends StatefulWidget {
  const PayoutsScreen({super.key});

  @override
  State<PayoutsScreen> createState() => _PayoutsScreenState();
}

class _PayoutsScreenState extends State<PayoutsScreen> {
  final ApiService _apiService = ApiService();
  final NumberFormat _currencyFormat = NumberFormat.decimalPattern('en_IN');
  final DateFormat _dateFormat = DateFormat('d MMM yyyy');
  final DateFormat _monthFormat = DateFormat('MMMM yyyy');

  List<_PayoutEntry> _payouts = const <_PayoutEntry>[];
  User? _user;
  Map<String, dynamic>? _policy;
  bool _isLoading = true;
  DateTime _lastUpdated = DateTime.now();

  String _primaryUpi = '';
  String? _backupUpi;
  bool _primaryVerified = true;
  bool _backupVerified = false;

  @override
  void initState() {
    super.initState();
    _loadPayoutData();
  }

  Future<void> _loadPayoutData() async {
    setState(() => _isLoading = true);

    User user = const User.empty();
    Map<String, dynamic> policy = <String, dynamic>{};
    Map<String, dynamic> dashboard = <String, dynamic>{};
    final loadIssues = <String>[];

    try {
      user = await _apiService.getProfile('me');
    } catch (error) {
      if (!_isAuthRelatedError(error)) {
        loadIssues.add('profile');
      }
      try {
        final status = await _apiService.getWorkerStatus();
        user = status.worker ?? User.empty(phone: status.phone);
      } catch (_) {
        user = const User.empty();
      }
    }

    try {
      policy = await _apiService.getPolicy('me');
    } catch (error) {
      if (!_isAuthRelatedError(error)) {
        loadIssues.add('policy');
      }
      policy = <String, dynamic>{};
    }

    try {
      dashboard = await _apiService.getPayoutDashboard();
    } catch (error) {
      if (!_isAuthRelatedError(error)) {
        loadIssues.add('payouts');
      }
      dashboard = <String, dynamic>{};
    }

    final transfers = (dashboard['transfers'] as List<dynamic>? ?? const <dynamic>[])
        .whereType<Map<String, dynamic>>()
        .toList();

    final payouts = transfers
        .map(
          (item) => _PayoutEntry(
            date: DateTime.tryParse(_coerceString(item['createdAt'])) ?? DateTime.now(),
            triggerType: _coerceString(item['note'], fallback: 'Claim payout'),
            triggerRawType: _coerceString(item['provider'], fallback: 'payout'),
            amount: (item['amount'] as num?)?.round() ?? 0,
            upiRef: _coerceString(item['providerPayoutId'], fallback: _coerceString(item['id'])),
          ),
        )
        .toList()
      ..sort((a, b) => b.date.compareTo(a.date));

    if (!mounted) return;
    setState(() {
      _user = user;
      _policy = policy;
      _payouts = payouts;
      _primaryUpi = _coerceString(dashboard['primaryUpi']);
      _backupUpi = _coerceString(dashboard['backupUpi']).isEmpty
          ? null
          : _coerceString(dashboard['backupUpi']);
      _primaryVerified = dashboard['primaryVerified'] == true;
      _backupVerified = dashboard['backupVerified'] == true;
      _lastUpdated = DateTime.now();
      _isLoading = false;
    });

    if (loadIssues.isNotEmpty && mounted) {
      final issueText = switch (loadIssues.first) {
        'profile' => 'Could not load profile details.',
        'policy' => 'Could not load policy details.',
        'payouts' => 'Could not refresh payout details.',
        _ => 'Could not refresh payout details.',
      };

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            loadIssues.length == 1
                ? issueText
                : 'Some payout details could not be refreshed.',
          ),
        ),
      );
    }
  }

  bool _isAuthRelatedError(Object error) {
    final message = error.toString().toLowerCase();
    return message.contains('authentication required') ||
        message.contains('not authenticated') ||
        message.contains('unauthorized') ||
        message.contains('token') ||
        message.contains('worker not found for token subject');
  }

  Future<void> _refreshPayouts() => _loadPayoutData();

  // ─── Entry point ──────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return const Scaffold(
        backgroundColor: AppColors.background,
        body: Center(child: CircularProgressIndicator()),
      );
    }

    final user = _user;
    if (user == null) {
      return const Scaffold(
        backgroundColor: AppColors.background,
        body: Center(
          child: Text(
            'Payout data unavailable. Please retry.',
            style: TextStyle(color: AppColors.textSecondary),
          ),
        ),
      );
    }

    final now = DateTime.now();
    final currentMonthData = _monthlyData(now);
    final previousMonthData = _monthlyData(DateTime(now.year, now.month - 1));
    final totalPremiumsPaid = ((_policy?['weeklyPremium'] as num? ?? 0) * 4).round();
    final totalPayoutsReceived = _payouts.fold<int>(0, (s, p) => s + p.amount);
    final estimatedWeeklyEarnings = (user.totalEarnings / 4).round();
    final averageWeeklyPayout =
        _payouts.isEmpty ? 0 : (totalPayoutsReceived / 4).round();

    return Scaffold(
      backgroundColor: AppColors.background,
      body: SafeArea(
        top: false,
        child: Stack(
          children: [
            const Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: SizedBox(
                height: 205,
                child: CustomPaint(
                  painter: _PayoutsTopBackgroundPainter(),
                ),
              ),
            ),
            RefreshIndicator(
              onRefresh: _refreshPayouts,
              child: ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.fromLTRB(0, 0, 0, 28),
                children: [
                  // ── Hero gradient header ──────────────────────────────────────
                  _buildHeroHeader(
                    user: user,
                    totalPremiumsPaid: totalPremiumsPaid,
                    totalPayoutsReceived: totalPayoutsReceived,
                    currentMonthData: currentMonthData,
                  ),
                  // ── Body content ──────────────────────────────────────────────
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 20, 20, 0),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _buildKpiStrip(currentMonthData: currentMonthData),
                        const SizedBox(height: 24),
                        _buildSectionHeader(
                          title: 'Performance',
                          subtitle: 'Monthly trend and your protection ratio',
                        ),
                        const SizedBox(height: 10),
                        _buildMonthlySummaryCard(
                          currentMonthData: currentMonthData,
                          previousMonthData: previousMonthData,
                        ),
                        const SizedBox(height: 10),
                        _buildValueRatioCard(
                          estimatedWeeklyEarnings: estimatedWeeklyEarnings,
                          averageWeeklyPayout: averageWeeklyPayout,
                        ),
                        const SizedBox(height: 24),
                        _buildSectionHeader(
                          title: 'Payout Accounts',
                          subtitle: 'Manage where settlements are sent',
                        ),
                        const SizedBox(height: 10),
                        _buildUpiManagementCard(context),
                        const SizedBox(height: 24),
                        _buildSectionHeader(
                          title: 'Statements',
                          subtitle: 'Download records for accounting and tax',
                        ),
                        const SizedBox(height: 10),
                        _buildStatementCard(context),
                        const SizedBox(height: 24),
                        _buildSectionHeader(
                          title: 'Recent Transfers',
                          subtitle: '${_payouts.length} settled payouts · pull down to refresh',
                        ),
                        const SizedBox(height: 10),
                        ..._payouts.map(
                          (entry) => Padding(
                            padding: const EdgeInsets.only(bottom: 8),
                            child: _buildPayoutTile(entry),
                          ),
                        ),
                        if (_payouts.isEmpty)
                          _emptyState(
                            icon: Icons.account_balance_wallet_outlined,
                            message: 'No settled payouts yet.\nYour transfers will appear here.',
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ─── Hero header ──────────────────────────────────────────────────────────

  Widget _buildHeroHeader({
    required User user,
    required int totalPremiumsPaid,
    required int totalPayoutsReceived,
    required _MonthlySummary currentMonthData,
  }) {
    final netValue = totalPayoutsReceived - totalPremiumsPaid;
    final isPositive = netValue >= 0;
    final initials = _userInitials(user.name);

    return SafeArea(
      bottom: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                _headerIconButton(
                  icon: Icons.arrow_back_rounded,
                  onTap: _openHome,
                ),
                Row(
                  children: [
                    _headerIconButton(
                      icon: Icons.notifications_none_rounded,
                      onTap: () => _showSimpleInfo('No new payout alerts'),
                    ),
                    const SizedBox(width: 8),
                    GestureDetector(
                      onTap: () => _showAccountSheet(user),
                      child: Container(
                        width: 38,
                        height: 38,
                        decoration: BoxDecoration(
                          color: AppColors.primary,
                          shape: BoxShape.circle,
                        ),
                        child: Center(
                          child: Text(
                            initials,
                            style: const TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w700,
                              color: Colors.white,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
            const SizedBox(height: 16),
            const Text(
              'Payouts',
              style: TextStyle(
                fontSize: 28,
                fontWeight: FontWeight.w800,
                color: AppColors.textPrimary,
                letterSpacing: -0.5,
                height: 1.1,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              'Updated ${DateFormat('h:mm a').format(_lastUpdated)}',
              style: const TextStyle(
                fontSize: 12,
                color: AppColors.textSecondary,
              ),
            ),
            const SizedBox(height: 14),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: AppColors.primary,
                borderRadius: BorderRadius.circular(18),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: _heroPill(
                      label: 'Total received',
                      value: '₹${_currencyFormat.format(totalPayoutsReceived)}',
                      icon: Icons.south_west_rounded,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: _heroPill(
                      label: isPositive ? 'Net gain' : 'Coverage note',
                      value: isPositive
                          ? '+₹${_currencyFormat.format(netValue.abs())}'
                          : _payoutMomentumQuote(
                              totalPayoutsReceived: totalPayoutsReceived,
                              payoutCount: _payouts.length,
                            ),
                      icon: isPositive
                          ? Icons.trending_up_rounded
                          : Icons.shield_outlined,
                      valueColor: isPositive
                          ? const Color(0xFF6EFFC2)
                          : Colors.white,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _heroPill({
    required String label,
    required String value,
    required IconData icon,
    Color valueColor = Colors.white,
  }) {
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.white.withValues(alpha: 0.2)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 13, color: Colors.white.withValues(alpha: 0.65)),
              const SizedBox(width: 4),
              Text(
                label,
                style: TextStyle(
                  fontSize: 11,
                  color: Colors.white.withValues(alpha: 0.7),
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
          const SizedBox(height: 5),
          Text(
            value,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 17,
              fontWeight: FontWeight.w800,
              color: valueColor,
              letterSpacing: -0.3,
              height: 1.2,
            ),
          ),
        ],
      ),
    );
  }

  // ignore: unused_element
  Widget _iconButton({required IconData icon, required VoidCallback onTap}) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 38,
        height: 38,
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.14),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: Colors.white.withValues(alpha: 0.25)),
        ),
        child: Icon(icon, size: 18, color: Colors.white),
      ),
    );
  }

  Widget _headerIconButton({required IconData icon, required VoidCallback onTap}) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 38,
        height: 38,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
        ),
        child: Icon(icon, size: 18, color: AppColors.textPrimary),
      ),
    );
  }

  // ─── KPI strip ────────────────────────────────────────────────────────────

  Widget _buildKpiStrip({required _MonthlySummary currentMonthData}) {
    return Row(
      children: [
        Expanded(
          child: _kpiChip(
            label: 'This month',
            value: '₹${_currencyFormat.format(currentMonthData.totalReceived)}',
            icon: Icons.calendar_today_outlined,
            iconColor: const Color(0xFF185FA5),
            iconBg: const Color(0xFFE6F1FB),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: _kpiChip(
            label: 'Avg payout',
            value: '₹${_currencyFormat.format(currentMonthData.average)}',
            icon: Icons.show_chart_rounded,
            iconColor: const Color(0xFF3B6D11),
            iconBg: const Color(0xFFEAF3DE),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: _kpiChip(
            label: 'Transfers',
            value: '${_payouts.length}',
            icon: Icons.swap_horiz_rounded,
            iconColor: AppColors.primary,
            iconBg: AppColors.accentLight,
          ),
        ),
      ],
    );
  }

  Widget _kpiChip({
    required String label,
    required String value,
    required IconData icon,
    required Color iconColor,
    required Color iconBg,
  }) {
    return Container(
      padding: const EdgeInsets.fromLTRB(10, 12, 10, 12),
      decoration: BoxDecoration(
        color: AppColors.cardBackground,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 28,
            height: 28,
            decoration: BoxDecoration(
              color: iconBg,
              borderRadius: BorderRadius.circular(7),
            ),
            child: Icon(icon, size: 14, color: iconColor),
          ),
          const SizedBox(height: 8),
          Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              fontSize: 10,
              color: AppColors.textSecondary,
              fontWeight: FontWeight.w500,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w800,
              color: AppColors.textPrimary,
              letterSpacing: -0.2,
            ),
          ),
        ],
      ),
    );
  }

  // ─── Section header ───────────────────────────────────────────────────────

  Widget _buildSectionHeader({required String title, required String subtitle}) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: const TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w700,
            color: AppColors.textPrimary,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          subtitle,
          style: const TextStyle(
            fontSize: 11,
            color: AppColors.textSecondary,
          ),
        ),
      ],
    );
  }

  // ─── Monthly summary card ─────────────────────────────────────────────────

  Widget _buildMonthlySummaryCard({
    required _MonthlySummary currentMonthData,
    required _MonthlySummary previousMonthData,
  }) {
    final thisMonth = currentMonthData.totalReceived;
    final lastMonth = previousMonthData.totalReceived;
    final maxValue = math.max(thisMonth, lastMonth).clamp(1, 999999);
    final changePercent = lastMonth == 0
        ? null
        : ((thisMonth - lastMonth) / lastMonth * 100).round();

    return _card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Three metrics in a row
          Row(
            children: [
              Expanded(
                child: _metricItem(
                  label: 'Total received',
                  value: '₹${_currencyFormat.format(thisMonth)}',
                ),
              ),
              _verticalDivider(),
              Expanded(
                child: _metricItem(
                  label: 'Payouts',
                  value: '${currentMonthData.count}',
                ),
              ),
              _verticalDivider(),
              Expanded(
                child: _metricItem(
                  label: 'Avg / claim',
                  value: '₹${_currencyFormat.format(currentMonthData.average)}',
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          // Month-over-month change indicator
          if (changePercent != null)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: changePercent >= 0
                    ? const Color(0xFFEAF3DE)
                    : const Color(0xFFFCEBEB),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    changePercent >= 0
                        ? Icons.arrow_upward_rounded
                        : Icons.arrow_downward_rounded,
                    size: 12,
                    color: changePercent >= 0
                        ? const Color(0xFF3B6D11)
                        : const Color(0xFFA32D2D),
                  ),
                  const SizedBox(width: 3),
                  Text(
                    '${changePercent.abs()}% vs last month',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: changePercent >= 0
                          ? const Color(0xFF3B6D11)
                          : const Color(0xFFA32D2D),
                    ),
                  ),
                ],
              ),
            ),
          const SizedBox(height: 14),
          // Bar comparison
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Expanded(
                child: _bar(
                  label: 'This month',
                  amount: thisMonth,
                  heightFactor: thisMonth / maxValue,
                  color: AppColors.primary,
                  maxBarHeight: 60,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _bar(
                  label: 'Last month',
                  amount: lastMonth,
                  heightFactor: lastMonth / maxValue,
                  color: const Color(0xFFB5D4F4),
                  maxBarHeight: 60,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _bar({
    required String label,
    required int amount,
    required double heightFactor,
    required Color color,
    required double maxBarHeight,
  }) {
    final clampedFactor = heightFactor.clamp(0.04, 1.0);
    final barHeight = maxBarHeight * clampedFactor;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          height: maxBarHeight,
          alignment: Alignment.bottomLeft,
          child: Container(
            width: double.infinity,
            height: barHeight,
            decoration: BoxDecoration(
              color: color,
              borderRadius: const BorderRadius.vertical(top: Radius.circular(6)),
            ),
          ),
        ),
        const SizedBox(height: 6),
        Text(
          label,
          style: const TextStyle(
            fontSize: 11,
            color: AppColors.textSecondary,
            fontWeight: FontWeight.w500,
          ),
        ),
        const SizedBox(height: 1),
        Text(
          '₹${_currencyFormat.format(amount)}',
          style: const TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w700,
            color: AppColors.textPrimary,
          ),
        ),
      ],
    );
  }

  // ─── Protection value ratio card ──────────────────────────────────────────

  Widget _buildValueRatioCard({
    required int estimatedWeeklyEarnings,
    required int averageWeeklyPayout,
  }) {
    final maxValue =
        math.max(estimatedWeeklyEarnings, averageWeeklyPayout).clamp(1, 999999);
    final coverageRatio = estimatedWeeklyEarnings == 0
        ? 0.0
        : (averageWeeklyPayout / estimatedWeeklyEarnings).clamp(0.0, 1.0);

    return _card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Expanded(
                child: Text(
                  'Protection value ratio',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    color: AppColors.textPrimary,
                  ),
                ),
              ),
              // Coverage percentage badge
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: AppColors.accentLight,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  '${(coverageRatio * 100).round()}% covered',
                  style: const TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    color: AppColors.primary,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          const Text(
            'Payouts vs estimated weekly earnings',
            style: TextStyle(fontSize: 11, color: AppColors.textSecondary),
          ),
          const SizedBox(height: 14),
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Expanded(
                child: _bar(
                  label: 'Est. earnings',
                  amount: estimatedWeeklyEarnings,
                  heightFactor: estimatedWeeklyEarnings / maxValue,
                  color: const Color(0xFFD3D1C7),
                  maxBarHeight: 80,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _bar(
                  label: 'Payouts received',
                  amount: averageWeeklyPayout,
                  heightFactor: averageWeeklyPayout / maxValue,
                  color: AppColors.primary,
                  maxBarHeight: 80,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  // ─── UPI management card ──────────────────────────────────────────────────

  Widget _buildUpiManagementCard(BuildContext context) {
    return _card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _upiRow(
            context: context,
            label: 'Primary UPI',
            upiId: _primaryUpi,
            verified: _primaryVerified,
            onChangeLabel: 'Change',
            onChange: () => _editUpi(
              context,
              title: 'Change primary UPI',
              currentValue: _primaryUpi,
              onSaved: (v) => setState(() {
                _primaryUpi = v;
                _primaryVerified = false;
              }),
            ),
            onVerify: _primaryVerified ? null : () { _verifyPrimary(); },
          ),
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 14),
            child: Container(height: 1, color: AppColors.border),
          ),
          _upiRow(
            context: context,
            label: 'Backup UPI',
            upiId: _backupUpi ?? 'Not added',
            verified: _backupVerified,
            onChangeLabel: _backupUpi == null ? 'Add' : 'Change',
            onChange: () => _editUpi(
              context,
              title: _backupUpi == null ? 'Add backup UPI' : 'Change backup UPI',
              currentValue: _backupUpi,
              onSaved: (v) => setState(() {
                _backupUpi = v;
                _backupVerified = false;
              }),
            ),
            onVerify: _backupUpi == null ? null : () { _verifyBackup(); },
          ),
        ],
      ),
    );
  }

  Widget _upiRow({
    required BuildContext context,
    required String label,
    required String upiId,
    required bool verified,
    required String onChangeLabel,
    required VoidCallback onChange,
    VoidCallback? onVerify,
  }) {
    final isAdded = upiId.toLowerCase() != 'not added';

    return Row(
      children: [
        // Left: icon + text
        Container(
          width: 36,
          height: 36,
          decoration: BoxDecoration(
            color: verified && isAdded
                ? const Color(0xFFEAF3DE)
                : const Color(0xFFF1EFE8),
            borderRadius: BorderRadius.circular(9),
          ),
          child: Icon(
            verified && isAdded
                ? Icons.verified_outlined
                : Icons.account_balance_wallet_outlined,
            size: 17,
            color: verified && isAdded
                ? const Color(0xFF3B6D11)
                : AppColors.textSecondary,
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label,
                style: const TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: AppColors.textSecondary,
                ),
              ),
              const SizedBox(height: 1),
              Text(
                upiId,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: isAdded ? AppColors.textPrimary : AppColors.textSecondary,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(width: 8),
        // Right: verified badge + action buttons
        Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
              decoration: BoxDecoration(
                color: verified && isAdded
                    ? const Color(0xFFEAF3DE)
                    : const Color(0xFFFAEEDA),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text(
                verified && isAdded ? 'Verified' : 'Unverified',
                style: TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.w700,
                  color: verified && isAdded
                      ? const Color(0xFF3B6D11)
                      : const Color(0xFFBA7517),
                ),
              ),
            ),
            const SizedBox(height: 6),
            Row(
              children: [
                _smallAction(
                  label: onChangeLabel,
                  onTap: onChange,
                ),
                if (onVerify != null) ...[
                  const SizedBox(width: 6),
                  _smallAction(
                    label: 'Verify',
                    onTap: onVerify,
                    primary: true,
                  ),
                ],
              ],
            ),
          ],
        ),
      ],
    );
  }

  Widget _smallAction({
    required String label,
    required VoidCallback onTap,
    bool primary = false,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: primary ? AppColors.accentLight : Colors.transparent,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: primary ? AppColors.primary.withValues(alpha: 0.4) : AppColors.border,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w600,
            color: primary ? AppColors.primary : AppColors.textSecondary,
          ),
        ),
      ),
    );
  }

  // ─── Statement card ───────────────────────────────────────────────────────

  Widget _buildStatementCard(BuildContext context) {
    return _card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: const Color(0xFFE6F1FB),
                  borderRadius: BorderRadius.circular(9),
                ),
                child: const Icon(
                  Icons.description_outlined,
                  size: 17,
                  color: Color(0xFF185FA5),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'PDF statements',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                        color: AppColors.textPrimary,
                      ),
                    ),
                    Text(
                      _monthFormat.format(DateTime.now()),
                      style: const TextStyle(
                        fontSize: 11,
                        color: AppColors.textSecondary,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(
                child: _statementButton(
                  icon: Icons.download_outlined,
                  label: 'This month',
                  onTap: _showCurrentMonthStatement,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _statementButton(
                  icon: Icons.date_range_outlined,
                  label: 'Custom range',
                  onTap: () => _pickCustomRange(context),
                  primary: true,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _statementButton({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
    bool primary = false,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 11),
        decoration: BoxDecoration(
          color: primary ? AppColors.accentLight : Colors.transparent,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: primary
                ? AppColors.primary.withValues(alpha: 0.4)
                : AppColors.border,
          ),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              icon,
              size: 15,
              color: primary ? AppColors.primary : AppColors.textSecondary,
            ),
            const SizedBox(width: 5),
            Text(
              label,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: primary ? AppColors.primary : AppColors.textSecondary,
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ─── Payout tile ──────────────────────────────────────────────────────────

  Widget _buildPayoutTile(_PayoutEntry entry) {
    final iconData = _triggerIconData(entry.triggerRawType);

    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      decoration: BoxDecoration(
        color: AppColors.cardBackground,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.border),
      ),
      child: Row(
        children: [
          Container(
            width: 38,
            height: 38,
            decoration: BoxDecoration(
              color: iconData.background,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(iconData.icon, size: 18, color: iconData.color),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  entry.triggerType,
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    color: AppColors.textPrimary,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  _dateFormat.format(entry.date),
                  style: const TextStyle(
                    fontSize: 11,
                    color: AppColors.textSecondary,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  'Ref: ${entry.upiRef}',
                  style: const TextStyle(
                    fontSize: 10,
                    color: AppColors.textSecondary,
                    fontFamily: 'monospace',
                  ),
                ),
              ],
            ),
          ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                '₹${_currencyFormat.format(entry.amount)}',
                style: const TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w800,
                  color: AppColors.primary,
                  letterSpacing: -0.2,
                ),
              ),
              const SizedBox(height: 4),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                decoration: BoxDecoration(
                  color: const Color(0xFFEAF3DE),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: const Text(
                  'Settled',
                  style: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.w700,
                    color: Color(0xFF3B6D11),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  // ─── Helpers ──────────────────────────────────────────────────────────────

  Widget _card({required Widget child}) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.cardBackground,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.border),
      ),
      child: child,
    );
  }

  Widget _metricItem({required String label, required String value}) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: const TextStyle(
            fontSize: 10,
            color: AppColors.textSecondary,
            fontWeight: FontWeight.w500,
          ),
        ),
        const SizedBox(height: 3),
        Text(
          value,
          style: const TextStyle(
            fontSize: 15,
            fontWeight: FontWeight.w800,
            color: AppColors.textPrimary,
            letterSpacing: -0.2,
          ),
        ),
      ],
    );
  }

  Widget _verticalDivider() {
    return Container(
      width: 1,
      height: 32,
      color: AppColors.border,
      margin: const EdgeInsets.symmetric(horizontal: 10),
    );
  }

  Widget _emptyState({required IconData icon, required String message}) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(vertical: 32),
      decoration: BoxDecoration(
        color: AppColors.cardBackground,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        children: [
          Icon(icon, size: 36, color: AppColors.textSecondary),
          const SizedBox(height: 10),
          Text(
            message,
            textAlign: TextAlign.center,
            style: const TextStyle(
              fontSize: 13,
              color: AppColors.textSecondary,
              height: 1.5,
            ),
          ),
        ],
      ),
    );
  }

  ({IconData icon, Color color, Color background}) _triggerIconData(String rawType) {
    switch (rawType.toLowerCase()) {
      case 'rainlock':
        return (
          icon: Icons.water_drop_outlined,
          color: const Color(0xFF185FA5),
          background: const Color(0xFFE6F1FB),
        );
      case 'trafficblock':
        return (
          icon: Icons.traffic_outlined,
          color: const Color(0xFFBA7517),
          background: const Color(0xFFFAEEDA),
        );
      case 'zonelock':
        return (
          icon: Icons.location_off_outlined,
          color: const Color(0xFF993556),
          background: const Color(0xFFFBEAF0),
        );
      case 'aqiguard':
        return (
          icon: Icons.air_outlined,
          color: const Color(0xFF3B6D11),
          background: const Color(0xFFEAF3DE),
        );
      case 'heatblock':
        return (
          icon: Icons.thermostat_outlined,
          color: const Color(0xFFA32D2D),
          background: const Color(0xFFFCEBEB),
        );
      default:
        return (
          icon: Icons.account_balance_wallet_outlined,
          color: AppColors.primary,
          background: AppColors.accentLight,
        );
    }
  }

  String _userInitials(String? name) {
    final safeName = _coerceString(name);
    final parts = safeName.trim().split(' ').where((p) => p.isNotEmpty).toList();
    if (parts.isEmpty) return '?';
    if (parts.length == 1) return parts.first.substring(0, 1).toUpperCase();
    return '${parts.first[0]}${parts.last[0]}'.toUpperCase();
  }

  String _coerceString(Object? value, {String fallback = ''}) {
    if (value == null) return fallback;
    final text = value.toString().trim();
    return text.isEmpty ? fallback : text;
  }

  String _payoutMomentumQuote({
    required int totalPayoutsReceived,
    required int payoutCount,
  }) {
    if (payoutCount >= 3) return 'Strong cover';
    if (totalPayoutsReceived > 0) return 'Covered';
    return 'Safety active';
  }

  _MonthlySummary _monthlyData(DateTime month) {
    final entries = _payouts.where(
      (e) => e.date.year == month.year && e.date.month == month.month,
    );
    final count = entries.length;
    final total = entries.fold<int>(0, (s, e) => s + e.amount);
    return _MonthlySummary(
      totalReceived: total,
      count: count,
      average: count == 0 ? 0 : (total / count).round(),
    );
  }

  // ─── Actions / sheets ─────────────────────────────────────────────────────

  Future<void> _editUpi(
    BuildContext context, {
    required String title,
    required String? currentValue,
    required ValueChanged<String> onSaved,
  }) async {
    String draftUpi = currentValue?.trim() ?? '';

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (sheetContext) {
        return Padding(
          padding: EdgeInsets.fromLTRB(
            16,
            8,
            16,
            math.max(0.0, MediaQuery.of(sheetContext).viewInsets.bottom) + 16,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: const TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w700,
                  color: AppColors.textPrimary,
                ),
              ),
              const SizedBox(height: 12),
              TextFormField(
                initialValue: draftUpi,
                onChanged: (value) => draftUpi = value,
                decoration: const InputDecoration(
                  labelText: 'UPI ID',
                  hintText: 'name@bank',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: () {
                    final value = draftUpi.trim();
                    if (value.isEmpty || !value.contains('@')) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('Enter a valid UPI ID')),
                      );
                      return;
                    }
                    final isPrimary = title.toLowerCase().contains('primary');
                    _apiService
                        .updatePayoutAccount(
                          slot: isPrimary ? 'primary' : 'backup',
                          upiId: value,
                        )
                        .then((_) async {
                      onSaved(value);
                      Navigator.pop(sheetContext);
                      await _refreshPayouts();
                      if (!mounted) return;
                      _showSimpleInfo('UPI updated successfully');
                    }).catchError((_) {
                      if (!mounted) return;
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('Failed to update UPI ID.')),
                      );
                    });
                  },
                  child: const Text('Save UPI'),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Future<void> _verifyPrimary() async {
    try {
      await _apiService.verifyPayoutAccount('primary');
      await _refreshPayouts();
      if (!mounted) return;
      _showSimpleInfo('Primary UPI verified');
    } catch (_) {
      if (!mounted) return;
      _showSimpleInfo('Primary UPI verification failed');
    }
  }

  Future<void> _verifyBackup() async {
    try {
      await _apiService.verifyPayoutAccount('backup');
      await _refreshPayouts();
      if (!mounted) return;
      _showSimpleInfo('Backup UPI verified');
    } catch (_) {
      if (!mounted) return;
      _showSimpleInfo('Backup UPI verification failed');
    }
  }

  Future<void> _showCurrentMonthStatement() async {
    final now = DateTime.now();
    try {
      final statement = await _apiService.getPayoutStatement(
        startDate: DateTime(now.year, now.month, 1),
        endDate: now,
      );
      if (!mounted) return;
      await _showStatementSheet(statement);
    } catch (_) {
      if (!mounted) return;
      _showSimpleInfo('Failed to generate monthly statement');
    }
  }

  Future<void> _pickCustomRange(BuildContext context) async {
    final now = DateTime.now();
    final range = await showDateRangePicker(
      context: context,
      firstDate: DateTime(now.year - 2),
      lastDate: now,
      initialDateRange: DateTimeRange(
        start: DateTime(now.year, now.month, 1),
        end: now,
      ),
    );
    if (range == null) return;
    try {
      final statement = await _apiService.getPayoutStatement(
        startDate: range.start,
        endDate: range.end,
      );
      if (!mounted) return;
      await _showStatementSheet(statement);
    } catch (_) {
      if (!mounted) return;
      _showSimpleInfo('Failed to generate statement');
    }
  }

  Future<void> _showStatementSheet(Map<String, dynamic> statement) {
    return showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (_) {
        return Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Statement ready',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 8),
              Text(
                "Transfers: ${statement['transferCount']}  Total: Rs ${statement['totalAmount']}",
              ),
              const SizedBox(height: 12),
              SelectableText(
                _coerceString(statement['csv']),
                style: const TextStyle(fontSize: 12),
              ),
            ],
          ),
        );
      },
    );
  }

  void _showSimpleInfo(String message) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  void _switchToTab(int index) {
    TabRouter.switchTo(index);
    Navigator.of(context).popUntil((route) => route.isFirst);
  }

  void _openHome() => _switchToTab(0);

  void _showAccountSheet(User user) {
    final safeName = _coerceString(user.name, fallback: 'User');
    final safePhone = _coerceString(user.phone, fallback: 'No phone on file');

    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: CircleAvatar(
                  backgroundColor: AppColors.primary,
                  child: Text(
                    _userInitials(safeName).substring(0, 1),
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                title: Text(safeName),
                subtitle: Text(safePhone),
                onTap: () {
                  Navigator.pop(sheetContext);
                  _switchToTab(4);
                },
              ),
              ListTile(
                leading: const Icon(Icons.home_outlined),
                title: const Text('Home'),
                onTap: () {
                  Navigator.pop(sheetContext);
                  _switchToTab(0);
                },
              ),
              ListTile(
                leading: const Icon(Icons.receipt_long_outlined),
                title: const Text('Claims'),
                onTap: () {
                  Navigator.pop(sheetContext);
                  _switchToTab(1);
                },
              ),
              ListTile(
                leading: const Icon(Icons.shield_outlined),
                title: const Text('Coverage details'),
                onTap: () {
                  Navigator.pop(sheetContext);
                  _switchToTab(2);
                },
              ),
            ],
          ),
        );
      },
    );
  }
}

// ─── Data models ──────────────────────────────────────────────────────────────

class _PayoutEntry {
  const _PayoutEntry({
    required this.date,
    required this.triggerType,
    required this.triggerRawType,
    required this.amount,
    required this.upiRef,
  });

  final DateTime date;
  final String triggerType;
  final String triggerRawType;
  final int amount;
  final String upiRef;
}

class _MonthlySummary {
  const _MonthlySummary({
    required this.totalReceived,
    required this.count,
    required this.average,
  });

  final int totalReceived;
  final int count;
  final int average;
}

class _PayoutsTopBackgroundPainter extends CustomPainter {
  const _PayoutsTopBackgroundPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final backgroundPaint = Paint()
      ..shader = const LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [
          Color(0xFFF4F8F5),
          Color(0xFFEDF4F0),
          Color(0xFFE7EFEA),
        ],
      ).createShader(Rect.fromLTWH(0, 0, size.width, size.height));

    canvas.drawRect(Rect.fromLTWH(0, 0, size.width, size.height), backgroundPaint);

    final accentPaint = Paint()
      ..color = AppColors.primary.withValues(alpha: 0.07)
      ..style = PaintingStyle.fill;

    canvas.drawCircle(Offset(size.width * 0.12, size.height * 0.22), 54, accentPaint);
    canvas.drawCircle(Offset(size.width * 0.84, size.height * 0.26), 34, accentPaint);

    final curvePaint = Paint()..color = Colors.white.withValues(alpha: 0.4);
    final curvePath = Path()
      ..moveTo(0, size.height * 0.72)
      ..cubicTo(
        size.width * 0.16,
        size.height * 0.60,
        size.width * 0.34,
        size.height * 0.84,
        size.width * 0.52,
        size.height * 0.72,
      )
      ..cubicTo(
        size.width * 0.70,
        size.height * 0.60,
        size.width * 0.84,
        size.height * 0.80,
        size.width,
        size.height * 0.70,
      )
      ..lineTo(size.width, size.height)
      ..lineTo(0, size.height)
      ..close();

    canvas.drawPath(curvePath, curvePaint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

