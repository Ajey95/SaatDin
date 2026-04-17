import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../models/user_model.dart';
import '../../services/api_service.dart';
import '../../services/tab_router.dart';
import '../../theme/app_colors.dart';

class PayoutsScreen extends StatefulWidget {
  const PayoutsScreen({super.key});

  @override
  State<PayoutsScreen> createState() => _PayoutsScreenState();
}

class _PayoutsScreenState extends State<PayoutsScreen> {
  final ApiService _apiService = ApiService();
  final NumberFormat _currencyFormat = NumberFormat.decimalPattern('en_IN');
  final DateFormat _timeFormat = DateFormat('h:mm a');
  static const List<String> _commonUpiHandles = <String>[
    '@ybl',
    '@ibl',
    '@axl',
    '@okaxis',
    '@okhdfcbank',
    '@okicici',
    '@oksbi',
    '@paytm',
    '@upi',
  ];

  List<_PayoutEntry> _payouts = const <_PayoutEntry>[];
  User? _user;
  bool _isLoading = true;
  DateTime _lastUpdated = DateTime.now();
  String _primaryUpi = '';
  int _selectedRange = 0;
  DateTimeRange? _customDateRange;

  @override
  void initState() {
    super.initState();
    _loadPayoutData();
  }

  Future<void> _loadPayoutData() async {
    if (mounted) {
      setState(() => _isLoading = true);
    }

    User user = const User.empty();
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
            status: _coerceString(item['status'], fallback: 'pending'),
            amount: (item['amount'] as num?)?.round() ?? 0,
            upiRef: _coerceString(item['providerPayoutId'], fallback: _coerceString(item['id'])),
            upiId: _coerceString(item['upiId'], fallback: _coerceString(dashboard['primaryUpi'])),
          ),
        )
        .toList()
      ..sort((a, b) => b.date.compareTo(a.date));

    if (!mounted) return;
    setState(() {
      _user = user;
      _payouts = payouts;
      _primaryUpi = _coerceString(dashboard['primaryUpi']);
      _lastUpdated = DateTime.now();
      _isLoading = false;
    });

    if (loadIssues.isNotEmpty && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Some payout details could not be refreshed.')),
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

    final settledPayouts = _settledPayoutsForRange(_selectedRange);
    final latestSettledPayout = settledPayouts.isNotEmpty ? settledPayouts.first : null;
    final weeklyTotal = _totalReceivedForRange(_selectedRange);
    final recentCreditedUpi = _recentCreditedUpi(latestSettledPayout);

    return Scaffold(
      backgroundColor: AppColors.background,
      body: Stack(
        children: [
          const Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: SizedBox(
              height: 200,
              child: CustomPaint(
                painter: _PayoutsTopBackgroundPainter(),
              ),
            ),
          ),
          SafeArea(
            child: RefreshIndicator(
              onRefresh: _refreshPayouts,
              child: ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
                children: [
                  _buildTopUtilityButtons(),
                  const SizedBox(height: 14),
                  const Text(
                    'Payouts',
                    style: TextStyle(
                      fontSize: 30,
                      fontWeight: FontWeight.w800,
                      color: AppColors.textPrimary,
                      letterSpacing: -0.4,
                    ),
                  ),
                  const SizedBox(height: 6),
                  const Text(
                    'Track trigger settlements and payout receipts.',
                    style: TextStyle(
                      fontSize: 13,
                      color: AppColors.textSecondary,
                    ),
                  ),
                  const SizedBox(height: 12),
                  _buildWeekSelector(),
                  const SizedBox(height: 16),
                  _buildReceiptHeroCard(
                    title: _rangeTitle(_selectedRange),
                    weeklyTotal: weeklyTotal,
                    recentCreditedUpi: recentCreditedUpi,
                  ),
                  const SizedBox(height: 16),
                  _buildReceiptTimeline(
                    settledPayouts,
                    range: _selectedRange,
                  ),
                  const SizedBox(height: 14),
                  const Divider(height: 1, thickness: 1, color: Color(0xFFE6E0D7)),
                  const SizedBox(height: 18),
                  _buildReceiptActions(),
                  const SizedBox(height: 18),
                  const Text(
                    'Quick Actions',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w900,
                      color: AppColors.textPrimary,
                    ),
                  ),
                  const SizedBox(height: 10),
                  _buildPayoutAccountCard(),
                  const SizedBox(height: 14),
                  Text(
                    'Updated ${_timeFormat.format(_lastUpdated)}',
                    style: const TextStyle(
                      fontSize: 11,
                      color: AppColors.textTertiary,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTopUtilityButtons() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        _utilityIconButton(
          icon: Icons.arrow_back,
          tooltip: 'Back to Home',
          onTap: _openHome,
        ),
        const SizedBox(width: 42, height: 42),
      ],
    );
  }

  Widget _utilityIconButton({
    required IconData icon,
    required String tooltip,
    required VoidCallback onTap,
  }) {
    return Tooltip(
      message: tooltip,
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Container(
          width: 42,
          height: 42,
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.2),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: Colors.white.withValues(alpha: 0.28)),
          ),
          child: Icon(icon, size: 21, color: AppColors.textPrimary),
        ),
      ),
    );
  }

  Widget _buildWeekSelector() {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          _weekPill(
            label: 'This week',
            selected: _selectedRange == 0,
            onTap: () => setState(() => _selectedRange = 0),
          ),
          const SizedBox(width: 8),
          _weekPill(
            label: 'Previous week',
            selected: _selectedRange == 1,
            onTap: () => setState(() => _selectedRange = 1),
          ),
          const SizedBox(width: 8),
          _weekPill(
            label: 'All time',
            selected: _selectedRange == 2,
            onTap: () => setState(() => _selectedRange = 2),
          ),
          const SizedBox(width: 8),
          _weekPill(
            label: _customRangePillLabel(),
            selected: _selectedRange == 3,
            onTap: _onCustomRangeTap,
          ),
        ],
      ),
    );
  }

  Widget _weekPill({
    required String label,
    required bool selected,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(999),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: selected ? AppColors.primary : Colors.white,
          borderRadius: BorderRadius.circular(999),
          border: Border.all(
            color: selected ? AppColors.primary : AppColors.border,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w700,
            color: selected ? Colors.white : AppColors.textPrimary,
          ),
        ),
      ),
    );
  }

  Widget _buildReceiptHeroCard({
    required String title,
    required int weeklyTotal,
    required String recentCreditedUpi,
  }) {

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
      decoration: BoxDecoration(
        color: const Color(0xFF1F7A48),
        borderRadius: BorderRadius.circular(28),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: const TextStyle(
              fontSize: 19,
              fontWeight: FontWeight.w700,
              color: Colors.white,
              height: 1.05,
            ),
          ),
          const SizedBox(height: 16),
          Text(
            '₹${_currencyFormat.format(weeklyTotal)}',
            style: const TextStyle(
              fontSize: 42,
              fontWeight: FontWeight.w800,
              color: Colors.white,
              height: 0.95,
              letterSpacing: -1.4,
            ),
          ),
          const SizedBox(height: 12),
          Text(
            'Credited to $recentCreditedUpi · just now',
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w500,
              color: Colors.white.withValues(alpha: 0.88),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildReceiptTimeline(
    List<_PayoutEntry> settledPayouts, {
    required int range,
  }) {
    final steps = settledPayouts
        .map(
          (entry) => _ReceiptStep(
            title: '(₹${_currencyFormat.format(entry.amount)}) received (${_claimLabel(entry)})',
            subtitle: '${_formatTimeLabel(entry.date)} · Settled to wallet',
          ),
        )
        .toList();

    if (steps.isEmpty) {
      steps.add(
        _ReceiptStep(
          title: 'No settled payouts yet',
          subtitle: '${_rangeLabel(range)} · Waiting for settlement',
        ),
      );
    }

    return Column(
      children: [
        for (var index = 0; index < steps.length; index++)
          _timelineStep(
            step: steps[index],
            isLast: index == steps.length - 1,
          ),
      ],
    );
  }

  Widget _timelineStep({
    required _ReceiptStep step,
    required bool isLast,
  }) {
    return Padding(
      padding: EdgeInsets.only(bottom: isLast ? 0 : 18),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 20,
            child: Column(
              children: [
                Container(
                  width: 16,
                  height: 16,
                  decoration: const BoxDecoration(
                    color: Color(0xFF31C8A2),
                    shape: BoxShape.circle,
                  ),
                ),
                if (!isLast)
                  Container(
                    width: 3,
                    height: 30,
                    margin: const EdgeInsets.only(top: 2),
                    decoration: BoxDecoration(
                      color: const Color(0xFFE2DDD4),
                      borderRadius: BorderRadius.circular(99),
                    ),
                  )
                else
                  const SizedBox(height: 32),
              ],
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(top: 1),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    step.title,
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w500,
                      color: Color(0xFF1E2520),
                      height: 1.05,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    step.subtitle,
                    style: const TextStyle(
                      fontSize: 12,
                      color: AppColors.textTertiary,
                      height: 1.15,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPayoutAccountCard() {
    final upi = _primaryUpi.isNotEmpty ? _primaryUpi : 'No UPI added';
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: const Color(0xFFE5DED3)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.04),
            blurRadius: 18,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Primary UPI',
                  style: TextStyle(
                    fontSize: 12,
                    color: AppColors.textSecondary,
                    height: 1.1,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  upi,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w500,
                    color: AppColors.textPrimary,
                    height: 1.05,
                  ),
                ),
                const SizedBox(height: 15),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    _accountActionChip(
                      label: 'Update UPI ID',
                      onTap: () => _showUpdateUpiSheet(slot: 'primary'),
                    ),
                    _accountActionChip(
                      label: 'Add backup UPI',
                      onTap: () => _showUpdateUpiSheet(slot: 'backup'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _accountActionChip({
    required String label,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          color: AppColors.accentLight,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: AppColors.border),
        ),
        child: Text(
          label,
          style: const TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: AppColors.textPrimary,
          ),
        ),
      ),
    );
  }

  String _withSelectedHandle(String input, String handle) {
    final normalizedHandle = handle.startsWith('@') ? handle : '@$handle';
    final value = input.trim().toLowerCase();
    if (value.isEmpty) {
      return 'name$normalizedHandle';
    }

    final atIndex = value.indexOf('@');
    if (atIndex == -1) {
      return '$value$normalizedHandle';
    }

    final userPart = value.substring(0, atIndex).trim();
    return '${userPart.isEmpty ? 'name' : userPart}$normalizedHandle';
  }

  Future<void> _showUpdateUpiSheet({required String slot}) async {
    String draftUpi = '';
    final controller = TextEditingController();

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (sheetContext) {
        final isPrimary = slot == 'primary';
        return StatefulBuilder(
          builder: (context, setModalState) {
            return Padding(
              padding: EdgeInsets.fromLTRB(
                16,
                8,
                16,
                MediaQuery.of(sheetContext).viewInsets.bottom + 16,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    isPrimary ? 'Update UPI ID' : 'Add backup UPI',
                    style: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w700,
                      color: AppColors.textPrimary,
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: controller,
                    onChanged: (value) => draftUpi = value,
                    decoration: const InputDecoration(
                      labelText: 'UPI ID',
                      hintText: 'name@bank',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  if (!isPrimary) ...[
                    const SizedBox(height: 10),
                    const Text(
                      'Common handles',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: AppColors.textSecondary,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: _commonUpiHandles.map((handle) {
                        return ActionChip(
                          label: Text(handle),
                          onPressed: () {
                            final next = _withSelectedHandle(draftUpi, handle);
                            setModalState(() {
                              draftUpi = next;
                              controller.value = TextEditingValue(
                                text: next,
                                selection: TextSelection.collapsed(offset: next.length),
                              );
                            });
                          },
                        );
                      }).toList(),
                    ),
                    const SizedBox(height: 6),
                  ],
                  const SizedBox(height: 12),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton(
                      onPressed: () async {
                        final value = draftUpi.trim().toLowerCase();
                        if (value.isEmpty || !value.contains('@')) {
                          _showSimpleInfo('Enter a valid UPI ID');
                          return;
                        }

                        try {
                          await _apiService.updatePayoutAccount(slot: slot, upiId: value);
                          if (!sheetContext.mounted) return;
                          Navigator.pop(sheetContext);
                          await _refreshPayouts();
                          if (!mounted) return;
                          _showSimpleInfo('UPI ID updated');
                        } catch (_) {
                          if (!mounted) return;
                          _showSimpleInfo('Failed to update UPI ID');
                        }
                      },
                      child: const Text('Save UPI'),
                    ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );

    controller.dispose();
  }

  Widget _buildReceiptActions() {
    return SizedBox(
      width: double.infinity,
      child: ElevatedButton.icon(
        onPressed: () => _showSimpleInfo('Receipt download will be added next'),
        icon: const Icon(Icons.download_rounded, size: 30, color: Colors.white),
        label: const Text(
          'Download receipt',
          style: TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w700,
            color: Colors.white,
          ),
        ),
        style: ElevatedButton.styleFrom(
          backgroundColor: AppColors.primary,
          foregroundColor: Colors.white,
          minimumSize: const Size.fromHeight(56),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
          elevation: 0,
        ),
      ),
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

  String _formatTimeLabel(DateTime value) => _timeFormat.format(value);

  Future<void> _onCustomRangeTap() async {
    final now = DateTime.now();
    final picked = await showDateRangePicker(
      context: context,
      firstDate: DateTime(now.year - 5),
      lastDate: now,
      initialDateRange: _customDateRange ??
          DateTimeRange(
            start: DateTime(now.year, now.month, 1),
            end: now,
          ),
    );

    if (picked == null || !mounted) return;
    setState(() {
      _customDateRange = picked;
      _selectedRange = 3;
    });
  }

  String _customRangePillLabel() {
    final range = _customDateRange;
    if (range == null) return 'Custom';
    return '${_formatDayMonth(range.start)} - ${_formatDayMonth(range.end)}';
  }

    int _totalReceivedForRange(int range) {
    return _payouts
      .where((entry) => _isInRange(entry.date, range) && _isSettled(entry))
        .fold<int>(0, (sum, entry) => sum + entry.amount);
  }

    List<_PayoutEntry> _settledPayoutsForRange(int range) {
    final settled = _payouts
      .where((entry) => _isSettled(entry) && _isInRange(entry.date, range))
        .toList();
    settled.sort((a, b) => b.date.compareTo(a.date));
    return settled;
  }

  bool _isSettled(_PayoutEntry entry) {
    return entry.status.toLowerCase() == 'settled';
  }

  String _claimLabel(_PayoutEntry entry) {
    final label = _coerceString(entry.triggerType);
    if (label.isEmpty) return 'Claim payout';
    return label;
  }

  bool _isInRange(DateTime value, int range) {
    if (range == 2) return true;
    if (range == 3) {
      final selected = _customDateRange;
      if (selected == null) return false;
      final day = DateTime(value.year, value.month, value.day);
      final start = DateTime(selected.start.year, selected.start.month, selected.start.day);
      final end = DateTime(selected.end.year, selected.end.month, selected.end.day);
      return !day.isBefore(start) && !day.isAfter(end);
    }

    final now = DateTime.now();
    final thisWeekStart = DateTime(now.year, now.month, now.day)
        .subtract(Duration(days: now.weekday - 1));
    final targetStart = thisWeekStart.subtract(Duration(days: 7 * range));
    final targetEnd = targetStart.add(const Duration(days: 7));
    final day = DateTime(value.year, value.month, value.day);
    return !day.isBefore(targetStart) && day.isBefore(targetEnd);
  }

  String _rangeLabel(int range) {
    if (range == 1) return 'Previous week';
    if (range == 2) return 'All time';
    if (range == 3) {
      final selected = _customDateRange;
      if (selected == null) return 'Custom range';
      return '${_formatDayMonth(selected.start)} - ${_formatDayMonth(selected.end)}';
    }
    return 'This week';
  }

  String _rangeTitle(int range) {
    if (range == 1) return 'Savings for Previous Week';
    if (range == 2) return 'Savings Since Joining';
    if (range == 3) return 'Total Savings';
    return 'Savings for This Week';
  }

  String _recentCreditedUpi(_PayoutEntry? latestPayout) {
    final fromTransfer = _coerceString(latestPayout?.upiId);
    if (fromTransfer.isNotEmpty) return fromTransfer;
    if (_primaryUpi.isNotEmpty) return _primaryUpi;
    return '9876543210@okaxis';
  }

  String _coerceString(Object? value, {String fallback = ''}) {
    if (value == null) return fallback;
    final text = value.toString().trim();
    return text.isEmpty ? fallback : text;
  }

  String _formatDayMonth(DateTime value) {
    const monthAbbr = <String>[
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'May',
      'Jun',
      'Jul',
      'Aug',
      'Sep',
      'Oct',
      'Nov',
      'Dec',
    ];
    final month = (value.month >= 1 && value.month <= 12)
        ? monthAbbr[value.month - 1]
        : '---';
    return '${value.day} $month';
  }
}

class _PayoutEntry {
  const _PayoutEntry({
    required this.date,
    required this.triggerType,
    required this.triggerRawType,
    required this.status,
    required this.amount,
    required this.upiRef,
    required this.upiId,
  });

  final DateTime date;
  final String triggerType;
  final String triggerRawType;
  final String status;
  final int amount;
  final String upiRef;
  final String upiId;
}

class _ReceiptStep {
  const _ReceiptStep({required this.title, required this.subtitle});

  final String title;
  final String subtitle;
}

class _PayoutsTopBackgroundPainter extends CustomPainter {
  const _PayoutsTopBackgroundPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final base = Paint()
      ..shader = const LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [
          AppColors.accentLight,
          Color(0xFFD7F3EF),
          Color(0xFFF4FBF9),
        ],
      ).createShader(Rect.fromLTWH(0, 0, size.width, size.height));

    final basePath = Path()
      ..moveTo(0, 0)
      ..lineTo(size.width, 0)
      ..lineTo(size.width, size.height * 0.86)
      ..lineTo(size.width * 0.68, size.height * 0.78)
      ..lineTo(size.width * 0.32, size.height * 0.94)
      ..lineTo(0, size.height * 0.82)
      ..close();

    canvas.drawPath(basePath, base);

    final stripePaint = Paint()
      ..color = AppColors.primary.withValues(alpha: 0.08)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2;

    canvas.drawLine(
      Offset(size.width * 0.08, size.height * 0.22),
      Offset(size.width * 0.92, size.height * 0.42),
      stripePaint,
    );
    canvas.drawLine(
      Offset(size.width * 0.02, size.height * 0.38),
      Offset(size.width * 0.74, size.height * 0.64),
      stripePaint,
    );

    final dotPaint = Paint()..color = AppColors.accent.withValues(alpha: 0.18);
    canvas.drawCircle(Offset(size.width * 0.15, size.height * 0.12), 12, dotPaint);
    canvas.drawCircle(Offset(size.width * 0.82, size.height * 0.2), 20, dotPaint);
    canvas.drawCircle(Offset(size.width * 0.58, size.height * 0.72), 10, dotPaint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
