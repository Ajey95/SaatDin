import 'package:flutter/material.dart';
import 'dart:math' as math;
import 'dart:async';
import 'package:showcaseview/showcaseview.dart';

import '../../theme/app_colors.dart';
import '../../models/claim_model.dart';
import '../../models/user_model.dart';
import '../../services/api_service.dart';
import '../../services/guide_preferences.dart';
import '../../widgets/claim_card.dart';
import '../../services/tab_router.dart';
import 'zone_lock_report_screen.dart';
import 'escalation_screen.dart';

class ClaimsScreen extends StatefulWidget {
  const ClaimsScreen({super.key});

  @override
  State<ClaimsScreen> createState() => _ClaimsScreenState();
}

class _ClaimsScreenState extends State<ClaimsScreen> {
  final ApiService _apiService = ApiService();
  final GlobalKey _guideSummaryKey = GlobalKey();
  int _selectedTab = 0;
  final _tabs = ['All Claims', 'In Review', 'Settled'];
  List<Claim> _claims = [];
  User? _user;
  Map<String, dynamic>? _policy;
  bool _isLoadingClaims = true;
  bool _shouldShowGuide = false;
  bool _guidePreferenceResolved = false;
  bool _guideStarted = false;

  @override
  void initState() {
    super.initState();
    _loadClaims();
    unawaited(_resolveGuidePreference());
  }

  Future<void> _resolveGuidePreference() async {
    final shouldShow = await GuidePreferences.shouldShow(
      GuidePreferences.claimsGuideSeen,
    );
    if (!mounted) return;
    setState(() {
      _shouldShowGuide = shouldShow;
      _guidePreferenceResolved = true;
    });
  }

  void _maybeStartGuide(BuildContext context) {
    if (!_guidePreferenceResolved || !_shouldShowGuide || _guideStarted) return;
    _guideStarted = true;
    unawaited(GuidePreferences.markSeen(GuidePreferences.claimsGuideSeen));
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ShowCaseWidget.of(context).startShowCase([_guideSummaryKey]);
    });
  }

  Future<void> _loadClaims() async {
    setState(() {
      _isLoadingClaims = true;
    });

    User? user;
    Map<String, dynamic>? policy;
    List<Claim> claims = const <Claim>[];
    final loadIssues = <String>[];

    try {
      try {
        user = await _apiService.getProfile('me');
      } catch (error) {
        if (!_isAuthRelatedError(error)) {
          loadIssues.add('profile');
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
        claims = await _apiService.getClaims('me');
      } catch (error) {
        if (!_isAuthRelatedError(error)) {
          loadIssues.add('claims');
        }
        claims = const <Claim>[];
      }

      if (!mounted) return;
      setState(() {
        _user = user ?? const User.empty();
        _policy = policy ?? <String, dynamic>{};
        _claims = claims;
      });

      if (loadIssues.isNotEmpty) {
        final issueText = switch (loadIssues.first) {
          'profile' => 'Could not load profile details.',
          'policy' => 'Could not load policy details.',
          'claims' => 'Could not load claim history.',
          _ => 'Could not refresh claim details.',
        };

        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              loadIssues.length == 1
                  ? issueText
                  : 'Some claim details could not be refreshed.',
            ),
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _isLoadingClaims = false;
        });
      }
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

  Widget _buildTopUtilityButtons(User user, {required bool isDark}) {
    final safeName = _coerceString(user.name, fallback: 'U');

    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        _utilityIconButton(
          icon: Icons.arrow_back,
          tooltip: 'Back to Home',
          isDark: isDark,
          onTap: () {
            _switchToTab(0);
          },
        ),
        Row(
          children: [
            _utilityIconButton(
              icon: Icons.notifications_none,
              tooltip: 'Notifications',
              isDark: isDark,
              onTap: () {
                _showNotificationsSheet();
              },
            ),
            const SizedBox(width: 10),
            Tooltip(
              message: 'Account',
              child: GestureDetector(
                onTap: () {
                  _showAccountSheet(user);
                },
                child: Container(
                  width: 42,
                  height: 42,
                  decoration: const BoxDecoration(
                    color: AppColors.primary,
                    shape: BoxShape.circle,
                  ),
                  child: Center(
                    child: Text(
                      _userInitials(safeName),
                      style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                        color: Colors.white,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _utilityIconButton({
    required IconData icon,
    required String tooltip,
    required bool isDark,
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
            color: isDark
                ? AppColors.nightSurface.withValues(alpha: 0.92)
                : Colors.white,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: isDark ? AppColors.nightBorder : AppColors.border,
            ),
          ),
          child: Icon(
            icon,
            size: 21,
            color: isDark ? Colors.white : AppColors.textPrimary,
          ),
        ),
      ),
    );
  }

  List<Claim> get _filteredClaims {
    switch (_selectedTab) {
      case 1:
        return _claims
            .where(
              (c) =>
                  c.status == ClaimStatus.inReview ||
                  c.status == ClaimStatus.escalated,
            )
            .toList();
      case 2:
        return _claims.where((c) => c.status == ClaimStatus.settled).toList();
      default:
        return _claims;
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final pageBackground = isDark
        ? AppColors.nightBackground
        : AppColors.scaffoldBackground;
    final primaryText = isDark ? Colors.white : AppColors.textPrimary;
    final secondaryText = isDark ? Colors.white70 : AppColors.textSecondary;
    final chipBackground = isDark
        ? AppColors.nightSurface
        : AppColors.cardBackground;
    final chipBorder = isDark ? AppColors.nightBorder : AppColors.border;

    final user = _user;
    final weeklyPremium = (_policy?['weeklyPremium'] as num? ?? 0).toInt();
    final policyStatus = ((_policy?['status'] as String?) ?? 'active')
        .toUpperCase();
    final inReviewCount = _claims
        .where(
          (c) =>
              c.status == ClaimStatus.inReview ||
              c.status == ClaimStatus.escalated,
        )
        .length;
    final settledCount = _claims
        .where((c) => c.status == ClaimStatus.settled)
        .length;
    final pendingCount = _claims
        .where((c) => c.status == ClaimStatus.pending)
        .length;
    final rejectedCount = _claims
        .where((c) => c.status == ClaimStatus.rejected)
        .length;
    final totalClaims = _claims.length;

    if (_isLoadingClaims) {
      return Scaffold(
        backgroundColor: pageBackground,
        body: Center(
          child: CircularProgressIndicator(color: AppColors.neonGreen),
        ),
      );
    }

    if (user == null) {
      return Scaffold(
        backgroundColor: pageBackground,
        body: Center(
          child: Text(
            'Failed to load claims data.',
            style: TextStyle(color: secondaryText),
          ),
        ),
      );
    }

    return ShowCaseWidget(
      builder: (guideContext) {
        _maybeStartGuide(guideContext);
        return Scaffold(
          backgroundColor: pageBackground,
          floatingActionButton: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Tooltip(
                message: 'Report ZoneLock',
                child: FloatingActionButton.small(
                  heroTag: 'fab_zonelock',
                  onPressed: _openZoneLockReport,
                  backgroundColor: AppColors.neonAmber,
                  child: const Icon(
                    Icons.lock_person_outlined,
                    color: Colors.white,
                  ),
                ),
              ),
              const SizedBox(height: 10),
              FloatingActionButton(
                heroTag: 'fab_new_claim',
                onPressed: () {
                  _showNewClaimSheet();
                },
                backgroundColor: AppColors.primary,
                child: Icon(
                  Icons.add,
                  color: isDark ? Colors.white : Colors.black,
                ),
              ),
            ],
          ),
          body: Stack(
            children: [
              Positioned(
                top: 0,
                left: 0,
                right: 0,
                child: SizedBox(
                  height: 205,
                  child: CustomPaint(
                    painter: _ClaimsTopBackgroundPainter(isDark: isDark),
                  ),
                ),
              ),
              SafeArea(
                child: RefreshIndicator(
                  color: AppColors.neonGreen,
                  backgroundColor: isDark
                      ? AppColors.nightSurface
                      : AppColors.cardBackground,
                  onRefresh: _loadClaims,
                  child: ListView(
                    physics: const AlwaysScrollableScrollPhysics(),
                    padding: const EdgeInsets.fromLTRB(20, 16, 20, 28),
                    children: [
                      _buildTopUtilityButtons(user, isDark: isDark),
                      const SizedBox(height: 18),
                      Text(
                        'Claims',
                        style: TextStyle(
                          fontSize: 30,
                          fontWeight: FontWeight.w900,
                          color: primaryText,
                          letterSpacing: -0.5,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'Track status, proof, and settlements in one place.',
                        style: TextStyle(fontSize: 13, color: secondaryText),
                      ),
                      const SizedBox(height: 16),
                      Showcase(
                        key: _guideSummaryKey,
                        title: 'Claim Health Snapshot',
                        description:
                            'This card gives your active policy status, weekly premium context, and the fastest summary of claim outcomes.',
                        child: _buildClaimSummaryCard(
                          context: context,
                          weeklyPremium: weeklyPremium,
                          policyStatus: policyStatus,
                          inReviewCount: inReviewCount,
                          pendingCount: pendingCount,
                          settledCount: settledCount,
                          rejectedCount: rejectedCount,
                          totalClaims: totalClaims,
                        ),
                      ),
                      const SizedBox(height: 14),
                      Row(
                        children: [
                          Expanded(
                            child: _claimStatPill(
                              context: context,
                              label: 'Pending',
                              value: pendingCount.toString(),
                              icon: Icons.schedule_rounded,
                              color: AppColors.neonAmber,
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: _claimStatPill(
                              context: context,
                              label: 'In review',
                              value: inReviewCount.toString(),
                              icon: Icons.rate_review_outlined,
                              color: AppColors.neonCyan,
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: _claimStatPill(
                              context: context,
                              label: 'Settled',
                              value: settledCount.toString(),
                              icon: Icons.verified_rounded,
                              color: AppColors.neonGreen,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 18),
                      Text(
                        'Filter',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w800,
                          color: primaryText,
                        ),
                      ),
                      const SizedBox(height: 10),
                      Wrap(
                        spacing: 10,
                        runSpacing: 10,
                        children: _tabs.asMap().entries.map((entry) {
                          final isSelected = _selectedTab == entry.key;
                          return ChoiceChip(
                            label: Text(entry.value),
                            selected: isSelected,
                            onSelected: (_) {
                              setState(() {
                                _selectedTab = entry.key;
                              });
                            },
                            selectedColor: AppColors.neonGreen.withValues(
                              alpha: 0.18,
                            ),
                            backgroundColor: chipBackground,
                            labelStyle: TextStyle(
                              color: isSelected ? primaryText : secondaryText,
                              fontWeight: FontWeight.w700,
                            ),
                            side: BorderSide(
                              color: isSelected
                                  ? AppColors.neonGreen.withValues(alpha: 0.32)
                                  : chipBorder,
                            ),
                          );
                        }).toList(),
                      ),
                      const SizedBox(height: 18),
                      Row(
                        children: [
                          Text(
                            'Recent Activity',
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w800,
                              color: primaryText,
                            ),
                          ),
                          const Spacer(),
                          Text(
                            '${_filteredClaims.length} shown',
                            style: TextStyle(
                              fontSize: 11,
                              color: secondaryText,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 10),
                      if (_filteredClaims.isEmpty)
                        _buildEmptyClaimsState(context)
                      else
                        ..._filteredClaims.map(
                          (claim) => Padding(
                            padding: const EdgeInsets.only(bottom: 12),
                            child: ClaimCard(
                              claim: claim,
                              onTap: () => _showClaimDetails(claim),
                            ),
                          ),
                        ),
                      const SizedBox(height: 10),
                      _buildClaimsHelpCard(context),
                    ],
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildClaimSummaryCard({
    required BuildContext context,
    required int weeklyPremium,
    required String policyStatus,
    required int inReviewCount,
    required int pendingCount,
    required int settledCount,
    required int rejectedCount,
    required int totalClaims,
  }) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final cardBg = isDark
        ? AppColors.nightSurface
        : Theme.of(context).colorScheme.surface;
    final cardBorder = isDark
        ? AppColors.nightBorder
        : Theme.of(context).colorScheme.outline.withValues(alpha: 0.28);
    final primaryText = Theme.of(context).colorScheme.onSurface;
    final secondaryText = Theme.of(
      context,
    ).colorScheme.onSurface.withValues(alpha: isDark ? 0.68 : 0.76);
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: cardBg,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: cardBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                'Current protection',
                style: TextStyle(
                  color: primaryText,
                  fontSize: 16,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const Spacer(),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 6,
                ),
                decoration: BoxDecoration(
                  color: AppColors.neonGreen.withValues(alpha: 0.16),
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text(
                  policyStatus,
                  style: TextStyle(
                    color: primaryText,
                    fontSize: 10,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 0.8,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                '₹$weeklyPremium',
                style: TextStyle(
                  color: primaryText,
                  fontSize: 34,
                  fontWeight: FontWeight.w900,
                  letterSpacing: -0.6,
                ),
              ),
              const SizedBox(width: 10),
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Text(
                  '/ week',
                  style: TextStyle(color: secondaryText, fontSize: 13),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            '$inReviewCount live settlements · $totalClaims claims total',
            style: TextStyle(color: secondaryText, fontSize: 12),
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(
                child: _miniStatusRow(
                  context: context,
                  label: 'Pending',
                  value: pendingCount.toString(),
                  color: AppColors.neonAmber,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _miniStatusRow(
                  context: context,
                  label: 'In review',
                  value: inReviewCount.toString(),
                  color: AppColors.neonCyan,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _miniStatusRow(
                  context: context,
                  label: 'Settled',
                  value: settledCount.toString(),
                  color: AppColors.neonGreen,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _miniStatusRow(
                  context: context,
                  label: 'Rejected',
                  value: rejectedCount.toString(),
                  color: AppColors.neonRed,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _miniStatusRow({
    required BuildContext context,
    required String label,
    required String value,
    required Color color,
  }) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bgColor = isDark
        ? AppColors.nightSurfaceElevated
        : Theme.of(
            context,
          ).colorScheme.surfaceContainerHighest.withValues(alpha: 0.75);
    final labelColor = Theme.of(
      context,
    ).colorScheme.onSurface.withValues(alpha: isDark ? 0.58 : 0.72);
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: TextStyle(color: labelColor, fontSize: 10)),
          const SizedBox(height: 4),
          Text(
            value,
            style: TextStyle(
              color: color,
              fontSize: 15,
              fontWeight: FontWeight.w900,
            ),
          ),
        ],
      ),
    );
  }

  Widget _claimStatPill({
    required BuildContext context,
    required String label,
    required String value,
    required IconData icon,
    required Color color,
  }) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bgColor = isDark
        ? AppColors.nightSurface
        : Theme.of(context).colorScheme.surface;
    final valueColor = Theme.of(context).colorScheme.onSurface;
    final labelColor = Theme.of(
      context,
    ).colorScheme.onSurface.withValues(alpha: isDark ? 0.65 : 0.74);
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: color.withValues(alpha: 0.18)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 17, color: color),
          const SizedBox(height: 8),
          Text(
            value,
            style: TextStyle(
              color: valueColor,
              fontSize: 18,
              fontWeight: FontWeight.w900,
              letterSpacing: -0.2,
            ),
          ),
          const SizedBox(height: 2),
          Text(label, style: TextStyle(color: labelColor, fontSize: 10)),
        ],
      ),
    );
  }

  Widget _buildEmptyClaimsState(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bgColor = isDark
        ? AppColors.nightSurface
        : Theme.of(context).colorScheme.surface;
    final borderColor = isDark
        ? AppColors.nightBorder
        : Theme.of(context).colorScheme.outline.withValues(alpha: 0.28);
    final primaryText = Theme.of(context).colorScheme.onSurface;
    final secondaryText = Theme.of(
      context,
    ).colorScheme.onSurface.withValues(alpha: isDark ? 0.62 : 0.74);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: borderColor),
      ),
      child: Column(
        children: [
          Icon(
            Icons.receipt_long_outlined,
            size: 38,
            color: secondaryText.withValues(alpha: 0.78),
          ),
          const SizedBox(height: 10),
          Text(
            'No claims in this category',
            style: TextStyle(
              color: primaryText,
              fontSize: 15,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            'Your claim activity will appear here once a threshold is crossed.',
            textAlign: TextAlign.center,
            style: TextStyle(color: secondaryText, fontSize: 12, height: 1.35),
          ),
        ],
      ),
    );
  }

  Widget _buildClaimsHelpCard(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bgColor = isDark
        ? AppColors.nightSurface
        : Theme.of(context).colorScheme.surface;
    final borderColor = isDark
        ? AppColors.nightBorder
        : Theme.of(context).colorScheme.outline.withValues(alpha: 0.28);
    final primaryText = Theme.of(context).colorScheme.onSurface;
    final secondaryText = Theme.of(
      context,
    ).colorScheme.onSurface.withValues(alpha: isDark ? 0.68 : 0.76);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: borderColor),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Need help with a claim?',
            style: TextStyle(
              color: primaryText,
              fontSize: 16,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            'Our claim specialists are available 24/7 in Kannada, Hindi, and English.',
            style: TextStyle(color: secondaryText, fontSize: 12, height: 1.35),
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _openZoneLockReport,
                  icon: const Icon(Icons.lock_person_outlined),
                  label: const Text('Report ZoneLock'),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: ElevatedButton.icon(
                  onPressed: _showNewClaimSheet,
                  icon: const Icon(Icons.add_rounded),
                  label: const Text('New claim'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  String _coerceString(Object? value, {String fallback = ''}) {
    if (value == null) return fallback;
    final text = value.toString().trim();
    return text.isEmpty ? fallback : text;
  }

  String _userInitials(String? name) {
    final safeName = _coerceString(name);
    final parts = safeName
        .trim()
        .split(' ')
        .where((p) => p.isNotEmpty)
        .toList();
    if (parts.isEmpty) return 'U';
    if (parts.length == 1) return parts.first.substring(0, 1).toUpperCase();
    return '${parts.first[0]}${parts.last[0]}'.toUpperCase();
  }

  void _openProfile() {
    _switchToTab(4);
  }

  void _switchToTab(int index) {
    TabRouter.switchTo(index);
    Navigator.of(context).popUntil((route) => route.isFirst);
  }

  void _showNotificationsSheet() {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final sheetBg = isDark
        ? AppColors.nightSurface
        : Theme.of(context).colorScheme.surface;
    final primaryText = Theme.of(context).colorScheme.onSurface;
    final secondaryText = Theme.of(
      context,
    ).colorScheme.onSurface.withValues(alpha: isDark ? 0.7 : 0.8);
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (_) {
        return Container(
          color: sheetBg,
          child: ListView(
            shrinkWrap: true,
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 20),
            children: [
              ListTile(
                leading: Icon(Icons.update_outlined, color: primaryText),
                title: Text(
                  'Claim #17210 moved to review',
                  style: TextStyle(color: primaryText),
                ),
                subtitle: Text(
                  'Our team requested one additional proof image',
                  style: TextStyle(color: secondaryText),
                ),
              ),
              ListTile(
                leading: Icon(
                  Icons.account_balance_wallet_outlined,
                  color: primaryText,
                ),
                title: Text(
                  'Settlement complete for #17209',
                  style: TextStyle(color: primaryText),
                ),
                subtitle: Text(
                  'Rs 1,450 transferred to your linked bank',
                  style: TextStyle(color: secondaryText),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  void _showAccountSheet(User user) {
    final safeName = _coerceString(user.name, fallback: 'User');
    final safePhone = _coerceString(user.phone, fallback: 'No phone');

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
                    _userInitials(safeName),
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
                  _openProfile();
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
              ListTile(
                leading: const Icon(Icons.payments_outlined),
                title: const Text('Payouts'),
                onTap: () {
                  Navigator.pop(sheetContext);
                  _switchToTab(3);
                },
              ),
            ],
          ),
        );
      },
    );
  }

  Future<void> _showNewClaimSheet() async {
    String selectedType = 'TrafficBlock';
    final descriptionController = TextEditingController();

    try {
      await showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        showDragHandle: true,
        builder: (sheetContext) {
          return StatefulBuilder(
            builder: (sheetContext, setSheetState) {
              return Padding(
                padding: EdgeInsets.fromLTRB(
                  16,
                  8,
                  16,
                  math.max(0.0, MediaQuery.of(sheetContext).viewInsets.bottom) +
                      16,
                ),
                child: ConstrainedBox(
                  constraints: BoxConstraints(
                    maxHeight: MediaQuery.of(sheetContext).size.height * 0.85,
                  ),
                  child: SingleChildScrollView(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Report a new claim',
                          style: TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 12),
                        const Text(
                          'Trigger type',
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                            color: AppColors.textPrimary,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children:
                              [
                                'TrafficBlock',
                                'RainLock',
                                'AQI Guard',
                                'ZoneLock',
                                'HeatBlock',
                              ].map((type) {
                                final isSelected = selectedType == type;
                                return ChoiceChip(
                                  label: Text(type),
                                  selected: isSelected,
                                  onSelected: (_) {
                                    setSheetState(() {
                                      selectedType = type;
                                    });
                                  },
                                );
                              }).toList(),
                        ),
                        const SizedBox(height: 10),
                        TextField(
                          controller: descriptionController,
                          maxLines: 3,
                          decoration: const InputDecoration(
                            labelText: 'What happened?',
                            border: OutlineInputBorder(),
                          ),
                        ),
                        const SizedBox(height: 12),
                        SizedBox(
                          width: double.infinity,
                          child: ElevatedButton(
                            onPressed: () async {
                              final messenger = ScaffoldMessenger.of(context);
                              final navigator = Navigator.of(sheetContext);
                              final desc =
                                  descriptionController.text.trim().isEmpty
                                  ? 'No additional details provided'
                                  : descriptionController.text.trim();
                              ClaimType claimType = ClaimType.trafficBlock;
                              if (selectedType == 'RainLock') {
                                claimType = ClaimType.rainLock;
                              }
                              if (selectedType == 'AQI Guard') {
                                claimType = ClaimType.aqiGuard;
                              }
                              if (selectedType == 'ZoneLock') {
                                claimType = ClaimType.zoneLock;
                              }
                              if (selectedType == 'HeatBlock') {
                                claimType = ClaimType.heatBlock;
                              }

                              try {
                                await _apiService.submitClaim(
                                  userId: 'me',
                                  type: claimType,
                                  description: desc,
                                );
                                if (!context.mounted) return;
                                navigator.pop();
                                await _loadClaims();
                              } catch (_) {
                                if (!context.mounted) return;
                                messenger.showSnackBar(
                                  const SnackBar(
                                    content: Text(
                                      'Claim submission failed. Please try again.',
                                    ),
                                  ),
                                );
                                return;
                              }

                              if (!context.mounted) return;
                              messenger.showSnackBar(
                                SnackBar(
                                  content: Text(
                                    'Claim submitted: $selectedType · $desc',
                                  ),
                                ),
                              );
                            },
                            child: const Text('Submit claim'),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              );
            },
          );
        },
      );
    } finally {
      descriptionController.dispose();
    }
  }

  void _showClaimDetails(Claim claim) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final sheetBg = isDark
        ? AppColors.nightSurface
        : Theme.of(context).colorScheme.surface;
    final cardBg = isDark
        ? AppColors.nightSurfaceElevated
        : Theme.of(
            context,
          ).colorScheme.surfaceContainerHighest.withValues(alpha: 0.75);
    final borderColor = isDark
        ? AppColors.nightBorder
        : Theme.of(context).colorScheme.outline.withValues(alpha: 0.28);
    final primaryText = Theme.of(context).colorScheme.onSurface;
    final secondaryText = Theme.of(
      context,
    ).colorScheme.onSurface.withValues(alpha: isDark ? 0.68 : 0.78);
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      useSafeArea: true,
      backgroundColor: sheetBg,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (sheetCtx) {
        return Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                      color: claim.statusColor.withValues(alpha: 0.14),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Icon(
                      Icons.receipt_long_outlined,
                      color: claim.statusColor,
                      size: 20,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Claim ${claim.id}',
                        style: TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.w800,
                          color: primaryText,
                        ),
                      ),
                      Text(
                        '${claim.typeShortName} · ${claim.statusLabel}',
                        style: TextStyle(fontSize: 12, color: secondaryText),
                      ),
                    ],
                  ),
                ],
              ),
              const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: cardBg,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: borderColor),
                ),
                child: Row(
                  children: [
                    _DetailItem(
                      isDark: isDark,
                      label: 'Amount',
                      value: '₹${claim.amount.toStringAsFixed(0)}',
                    ),
                    Container(width: 1, height: 32, color: borderColor),
                    _DetailItem(
                      isDark: isDark,
                      label: 'Status',
                      value: claim.statusLabel,
                    ),
                    Container(width: 1, height: 32, color: borderColor),
                    _DetailItem(
                      isDark: isDark,
                      label: 'Type',
                      value: claim.typeShortName,
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 14),
              Text(
                'Our reviewer will update this timeline as soon as verification completes.',
                style: TextStyle(
                  color: secondaryText,
                  fontSize: 13,
                  height: 1.35,
                ),
              ),
              const SizedBox(height: 20),
              if (claim.status == ClaimStatus.inReview ||
                  claim.status == ClaimStatus.escalated ||
                  claim.status == ClaimStatus.pending)
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    icon: const Icon(
                      Icons.escalator_warning_rounded,
                      color: AppColors.neonAmber,
                      size: 18,
                    ),
                    label: const Text(
                      'Escalate this claim',
                      style: TextStyle(
                        color: AppColors.neonAmber,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    onPressed: () async {
                      Navigator.of(sheetCtx).pop();
                      final submitted = await EscalationSheet.show(
                        context,
                        claim,
                      );
                      if (submitted == true && mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            content: Text(
                              'Escalation submitted. A reviewer will contact you within 2 hrs.',
                            ),
                          ),
                        );
                        await _loadClaims();
                      }
                    },
                    style: OutlinedButton.styleFrom(
                      side: const BorderSide(color: AppColors.neonAmber),
                      foregroundColor: AppColors.neonAmber,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                      ),
                      padding: const EdgeInsets.symmetric(vertical: 14),
                    ),
                  ),
                ),
              if (claim.status == ClaimStatus.settled &&
                  claim.bankInfo != null) ...[
                const SizedBox(height: 14),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: AppColors.neonGreen.withValues(alpha: 0.10),
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(
                      color: AppColors.neonGreen.withValues(alpha: 0.20),
                    ),
                  ),
                  child: Text(
                    'Settled to ${claim.bankInfo}',
                    style: TextStyle(
                      color: primaryText.withValues(alpha: 0.88),
                      fontSize: 12,
                    ),
                  ),
                ),
              ],
            ],
          ),
        );
      },
    );
  }

  Future<void> _openZoneLockReport() async {
    final submitted = await Navigator.of(context).push<bool>(
      MaterialPageRoute<bool>(builder: (_) => const ZoneLockReportScreen()),
    );
    if (submitted == true && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('ZoneLock report submitted successfully!'),
        ),
      );
      await _loadClaims();
    }
  }
}

// Helper widget for claim detail row items
class _DetailItem extends StatelessWidget {
  const _DetailItem({
    required this.label,
    required this.value,
    required this.isDark,
  });
  final String label;
  final String value;
  final bool isDark;

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Column(
        children: [
          Text(
            label,
            style: TextStyle(
              fontSize: 11,
              color: isDark ? Colors.white70 : AppColors.textSecondary,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            value,
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w700,
              color: isDark ? Colors.white : AppColors.textPrimary,
            ),
          ),
        ],
      ),
    );
  }
}

class _ClaimsTopBackgroundPainter extends CustomPainter {
  const _ClaimsTopBackgroundPainter({required this.isDark});

  final bool isDark;

  @override
  void paint(Canvas canvas, Size size) {
    final backgroundPaint = Paint()
      ..shader =
          (isDark
                  ? const LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [
                        Color(0xFF07111F),
                        Color(0xFF0B1728),
                        Color(0xFF13263A),
                      ],
                    )
                  : const LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [
                        Color(0xFFE7F0FF),
                        Color(0xFFF1F6FF),
                        Color(0xFFFAFCFF),
                      ],
                    ))
              .createShader(Rect.fromLTWH(0, 0, size.width, size.height));

    canvas.drawRect(
      Rect.fromLTWH(0, 0, size.width, size.height),
      backgroundPaint,
    );

    final shapePaint = Paint()
      ..color = (isDark ? AppColors.neonCyan : AppColors.info).withValues(
        alpha: isDark ? 0.12 : 0.10,
      );
    final shapePath = Path()
      ..moveTo(-20, size.height * 0.74)
      ..lineTo(size.width * 0.42, size.height * 0.56)
      ..lineTo(size.width + 30, size.height * 0.84)
      ..lineTo(size.width + 30, size.height)
      ..lineTo(-20, size.height)
      ..close();
    canvas.drawPath(shapePath, shapePaint);

    final ringPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5
      ..color = AppColors.info.withValues(alpha: isDark ? 0.15 : 0.22);

    canvas.drawCircle(
      Offset(size.width * 0.18, size.height * 0.2),
      32,
      ringPaint,
    );
    canvas.drawCircle(
      Offset(size.width * 0.86, size.height * 0.3),
      48,
      ringPaint,
    );
    final glowPaint = Paint()
      ..color = (isDark ? AppColors.neonGreen : AppColors.success).withValues(
        alpha: isDark ? 0.08 : 0.10,
      );
    canvas.drawCircle(
      Offset(size.width * 0.82, size.height * 0.18),
      size.shortestSide * 0.28,
      glowPaint,
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
