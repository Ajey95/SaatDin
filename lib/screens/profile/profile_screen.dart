import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../models/claim_model.dart';
import '../../models/user_model.dart';
import '../../routes/app_routes.dart';
import '../../services/api_service.dart';
import '../../services/tab_router.dart';
import '../../theme/app_colors.dart';
import '../../theme/theme_controller.dart';

class ProfileScreen extends StatelessWidget {
  const ProfileScreen({super.key});

  static final ApiService _apiService = ApiService();

  Future<_ProfileViewData> _loadProfileViewData() async {
    User user = const User.empty();

    try {
      user = await _apiService.getProfile('me');
    } catch (_) {
      final status = await _apiService.getWorkerStatus();
      user = status.worker ?? User.empty(phone: status.phone);
    }

    final results = await Future.wait<dynamic>([
      _apiService.getPolicy('me').catchError((_) => <String, dynamic>{}),
      _apiService.getClaims('me').catchError((_) => const <Claim>[]),
      _apiService.getPayoutDashboard().catchError((_) => <String, dynamic>{}),
    ]);

    return _ProfileViewData(
      user: user,
      policy: results[0] as Map<String, dynamic>,
      claims: results[1] as List<Claim>,
      payoutDashboard: results[2] as Map<String, dynamic>,
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final pageBackground = isDark
        ? AppColors.nightBackground
        : AppColors.scaffoldBackground;

    return FutureBuilder<_ProfileViewData>(
      future: _loadProfileViewData(),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return Scaffold(
            backgroundColor: pageBackground,
            body: Center(child: CircularProgressIndicator()),
          );
        }

        if (snapshot.hasError || snapshot.data == null) {
          return Scaffold(
            backgroundColor: pageBackground,
            body: Center(
              child: Text(
                'Could not load settings. Please retry.',
                style: TextStyle(
                  color: isDark ? Colors.white70 : AppColors.textSecondary,
                ),
              ),
            ),
          );
        }

        final data = snapshot.data!;
        final user = data.user;
        final policy = data.policy;
        final claims = data.claims;
        final payoutDashboard = data.payoutDashboard;
        final claimCountThisMonth = _claimCountForCurrentMonth(claims);
        final perTriggerPayout = _readInt(policy, const ['perTriggerPayout']);
        final weeklyPremium = _readInt(policy, const ['weeklyPremium']);
        final activePlan = _readString(policy, const [
          'plan',
        ], fallback: user.plan);
        final locationLabel = _buildLocationLabel(user);
        final policyStatus = _readString(policy, const [
          'status',
        ], fallback: 'active').toLowerCase();
        final statusLabel = policyStatus == 'active'
            ? 'Active policy'
            : policyStatus == 'scheduled'
            ? 'Plan change scheduled'
            : 'Policy update pending';
        final nextBillingDate = _readString(policy, const ['nextBillingDate']);
        final renewalLabel = _renewalLabel(nextBillingDate);
        final payoutSummary = _readMap(payoutDashboard, const ['summary']);
        final settledTotal = _readDouble(payoutSummary, const ['settledTotal']);
        final pendingTotal = _readDouble(payoutSummary, const ['pendingTotal']);
        final primaryUpiMasked = _readString(payoutDashboard, const [
          'primaryUpiMasked',
        ]);
        final provider = _readString(payoutDashboard, const ['provider']);
        final contact = _formatPhone(user.phone);
        return Scaffold(
          backgroundColor: pageBackground,
          body: Stack(
            children: [
              Positioned(
                top: 0,
                left: 0,
                right: 0,
                child: SizedBox(
                  height: 205,
                  child: CustomPaint(
                    painter: _ProfileTopBackgroundPainter(isDark: isDark),
                  ),
                ),
              ),
              SafeArea(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(20, 16, 20, 28),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _buildTopUtilityButtons(context),
                      const SizedBox(height: 14),
                      Text(
                        'Settings',
                        style: TextStyle(
                          fontSize: 30,
                          fontWeight: FontWeight.w800,
                          color: isDark ? Colors.white : AppColors.textPrimary,
                          letterSpacing: -0.4,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        'Manage your profile, coverage, and payouts.',
                        style: TextStyle(
                          fontSize: 13,
                          color: isDark
                              ? Colors.white70
                              : AppColors.textSecondary,
                        ),
                      ),
                      const SizedBox(height: 16),
                      _buildHeader(
                        context,
                        user,
                        contact,
                        statusLabel,
                        locationLabel,
                      ),
                      _buildCoverageBanner(
                        context: context,
                        perTriggerPayout: perTriggerPayout,
                        activePlan: activePlan,
                        renewalLabel: renewalLabel,
                      ),
                      _buildSectionLabel(context, 'Insurance'),
                      _buildMenuGroup(context, [
                        _MenuItemData(
                          icon: Icons.receipt_long_outlined,
                          iconBg: const Color(0xFFE1F5EE),
                          iconColor: const Color(0xFF0F6E56),
                          title: 'Claims history',
                          subtitle: '$claimCountThisMonth claims this month',
                          onTap: () => _switchToTab(context, 1),
                        ),
                        _MenuItemData(
                          icon: Icons.payments_outlined,
                          iconBg: const Color(0xFFE1F5EE),
                          iconColor: const Color(0xFF0F6E56),
                          title: 'Payouts',
                          subtitle: pendingTotal > 0
                              ? '₹${NumberFormat('#,##0').format(settledTotal)} settled, ₹${NumberFormat('#,##0').format(pendingTotal)} pending'
                              : '₹${NumberFormat('#,##0').format(settledTotal)} settled',
                          onTap: () => _switchToTab(context, 3),
                        ),
                        _MenuItemData(
                          icon: Icons.workspace_premium_outlined,
                          iconBg: const Color(0xFFFAEEDA),
                          iconColor: const Color(0xFF854F0B),
                          title: 'Plans and pricing',
                          subtitle: activePlan.trim().isEmpty
                              ? 'Check available plans'
                              : weeklyPremium > 0
                              ? '$activePlan • ₹${NumberFormat('#,##0').format(weeklyPremium)}/week'
                              : '$activePlan plan active',
                          onTap: () => _switchToTab(context, 2),
                        ),
                      ]),
                      _buildSectionLabel(context, 'Preferences'),
                      _buildMenuGroup(context, [
                        _MenuItemData(
                          icon: Icons.payments_outlined,
                          iconBg: const Color(0xFFE1F5EE),
                          iconColor: const Color(0xFF0F6E56),
                          title: 'Payout settings',
                          subtitle: primaryUpiMasked.isNotEmpty
                              ? (provider.isNotEmpty
                                    ? '$provider • $primaryUpiMasked'
                                    : primaryUpiMasked)
                              : (provider.isNotEmpty
                                    ? provider
                                    : 'No payout account returned'),
                          onTap: () => _switchToTab(context, 3),
                        ),
                        _MenuItemData(
                          icon: Icons.workspace_premium_outlined,
                          iconBg: const Color(0xFFFAEEDA),
                          iconColor: const Color(0xFF854F0B),
                          title: 'Coverage details',
                          subtitle: '$statusLabel • $renewalLabel',
                          onTap: () => _switchToTab(context, 2),
                        ),
                        _MenuItemData(
                          icon: Icons.info_outline,
                          iconBg: const Color(0xFFE1F5EE),
                          iconColor: const Color(0xFF0F6E56),
                          title: 'Help and support',
                          subtitle: 'Contact help and review claim guidance',
                          onTap: () => _showSupportSheet(context),
                        ),
                        _MenuItemData(
                          icon: Icons.contrast_rounded,
                          iconBg: const Color(0xFFE8EEFF),
                          iconColor: const Color(0xFF2C4DAA),
                          title: 'Appearance mode',
                          subtitle: _themeSubtitle(),
                          onTap: () => _showThemeModeSheet(context),
                        ),
                      ]),
                      _buildSectionLabel(context, 'Account'),
                      _buildMenuGroup(context, [
                        _MenuItemData(
                          icon: Icons.logout,
                          iconBg: const Color(0xFFFCEBEB),
                          iconColor: const Color(0xFFA32D2D),
                          title: 'Log out',
                          titleColor: const Color(0xFFC0392B),
                          onTap: () => _confirmLogout(context),
                        ),
                      ]),
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

  // ─── Header band ───────────────────────────────────────────────────────────

  Widget _buildHeader(
    BuildContext context,
    User user,
    String contact,
    String policyStatus,
    String locationLabel,
  ) {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 14),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.primary,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 56,
                height: 56,
                decoration: BoxDecoration(
                  color: Colors.white,
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: Colors.white.withValues(alpha: 0.4),
                    width: 2,
                  ),
                ),
                child: Center(
                  child: Text(
                    _displayInitial(user.name),
                    style: const TextStyle(
                      color: AppColors.primary,
                      fontSize: 22,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      user.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w700,
                        color: Colors.white,
                        height: 1.2,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      contact,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w400,
                        color: Colors.white.withValues(alpha: 0.72),
                        fontFamily: 'monospace',
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 10),
              _editButton(context, user, contact),
            ],
          ),
          const SizedBox(height: 16),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _statusPill(
                dotColor: const Color(0xFF6EFFC4),
                label: policyStatus,
              ),
              _statusPill(
                dotColor: const Color(0xFFFFD980),
                label: locationLabel,
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildTopUtilityButtons(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        _headerIconButton(
          icon: Icons.arrow_back,
          onTap: () => _switchToTab(context, 0),
        ),
        _headerIconButton(
          icon: Icons.notifications_none,
          onTap: () => _showNotificationsSheet(context),
        ),
      ],
    );
  }

  Widget _headerIconButton({
    required IconData icon,
    required VoidCallback onTap,
  }) {
    return InkWell(
      borderRadius: BorderRadius.circular(10),
      onTap: onTap,
      child: Container(
        width: 38,
        height: 38,
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.15),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: Colors.white.withValues(alpha: 0.2)),
        ),
        child: Icon(icon, size: 20, color: Colors.white),
      ),
    );
  }

  Widget _editButton(BuildContext context, User user, String contact) {
    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: () => _showProfileDetailsSheet(context, user, contact),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.18),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: Colors.white.withValues(alpha: 0.25)),
        ),
        child: const Text(
          'Details',
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: Colors.white,
          ),
        ),
      ),
    );
  }

  Widget _statusPill({required Color dotColor, required String label}) {
    return Container(
      constraints: const BoxConstraints(maxWidth: 220),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(99),
        border: Border.all(color: Colors.white.withValues(alpha: 0.2)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 6,
            height: 6,
            decoration: BoxDecoration(color: dotColor, shape: BoxShape.circle),
          ),
          const SizedBox(width: 5),
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w500,
                color: Colors.white,
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ─── Coverage banner ───────────────────────────────────────────────────────

  Widget _buildCoverageBanner({
    required BuildContext context,
    required int perTriggerPayout,
    required String activePlan,
    required String renewalLabel,
  }) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final surfaceColor = isDark ? AppColors.nightSurface : Colors.white;
    final borderColor = isDark
        ? AppColors.nightBorder
        : const Color(0xFFE2EBE6);

    return Container(
      margin: const EdgeInsets.fromLTRB(16, 16, 16, 0),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: surfaceColor,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: borderColor),
      ),
      child: Row(
        children: [
          Container(
            width: 38,
            height: 38,
            decoration: BoxDecoration(
              color: const Color(0xFFE1F5EE),
              borderRadius: BorderRadius.circular(10),
            ),
            child: const Icon(
              Icons.verified_user_outlined,
              size: 20,
              color: Color(0xFF0F6E56),
            ),
          ),
          const SizedBox(width: 12),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                "This week's coverage",
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w500,
                  color: Color(0xFF6B8A77),
                ),
              ),
              const SizedBox(height: 2),
              Text(
                '₹$perTriggerPayout / day',
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                  color: Color(0xFF1A2E25),
                ),
              ),
              const SizedBox(height: 1),
              Text(
                renewalLabel,
                style: TextStyle(fontSize: 10, color: Colors.grey.shade500),
              ),
            ],
          ),
          const Spacer(),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
            decoration: BoxDecoration(
              color: const Color(0xFFE1F5EE),
              borderRadius: BorderRadius.circular(99),
            ),
            child: Text(
              activePlan,
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w700,
                color: Color(0xFF0F6E56),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ─── Section label ─────────────────────────────────────────────────────────

  Widget _buildSectionLabel(BuildContext context, String label) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 8),
      child: Text(
        label.toUpperCase(),
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w700,
          color: isDark ? Colors.white70 : const Color(0xFF8BA897),
          letterSpacing: 0.08 * 11,
        ),
      ),
    );
  }

  // ─── Menu group ────────────────────────────────────────────────────────────

  Widget _buildMenuGroup(BuildContext context, List<_MenuItemData> items) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final surfaceColor = isDark ? AppColors.nightSurface : Colors.white;
    final borderColor = isDark
        ? AppColors.nightBorder
        : const Color(0xFFE2EBE6);
    final dividerColor = isDark
        ? AppColors.nightBorder
        : const Color(0xFFE8F0EB);

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16),
      decoration: BoxDecoration(
        color: surfaceColor,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: borderColor),
      ),
      clipBehavior: Clip.hardEdge,
      child: Column(
        children: List.generate(items.length, (i) {
          return Column(
            children: [
              _buildMenuRow(context, items[i]),
              if (i < items.length - 1)
                Divider(
                  height: 0,
                  thickness: 0.5,
                  indent: 56,
                  color: dividerColor,
                ),
            ],
          );
        }),
      ),
    );
  }

  Widget _buildMenuRow(BuildContext context, _MenuItemData item) {
    return InkWell(
      onTap: item.onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
        child: Row(
          children: [
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: item.iconBg,
                borderRadius: BorderRadius.circular(9),
              ),
              child: Icon(item.icon, size: 18, color: item.iconColor),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    item.title,
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      color:
                          item.titleColor ??
                          Theme.of(context).colorScheme.onSurface,
                    ),
                  ),
                  if (item.subtitle != null) ...[
                    const SizedBox(height: 1),
                    Text(
                      item.subtitle!,
                      style: TextStyle(
                        fontSize: 11,
                        color: Theme.of(context).textTheme.bodySmall?.color,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            if (item.badge != null) ...[
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: const Color(0xFFE1F5EE),
                  borderRadius: BorderRadius.circular(99),
                ),
                child: Text(
                  item.badge!,
                  style: const TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.w700,
                    color: Color(0xFF0F6E56),
                  ),
                ),
              ),
              const SizedBox(width: 6),
            ],
            const Icon(Icons.chevron_right, size: 18, color: Color(0xFFB0C4B8)),
          ],
        ),
      ),
    );
  }

  // ─── Actions ───────────────────────────────────────────────────────────────

  void _showNotificationsSheet(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (_) {
        return ListView(
          shrinkWrap: true,
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 20),
          children: const [
            ListTile(
              leading: Icon(Icons.verified_outlined),
              title: Text('Profile verification completed'),
              subtitle: Text('Your account details are fully up to date'),
            ),
            ListTile(
              leading: Icon(Icons.shield_outlined),
              title: Text('Security reminder'),
              subtitle: Text('Review device activity once every week'),
            ),
          ],
        );
      },
    );
  }

  void _showProfileDetailsSheet(
    BuildContext context,
    User user,
    String contact,
  ) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (_) {
        return ListView(
          shrinkWrap: true,
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 20),
          children: [
            const Text(
              'Profile details',
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 12),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.person_outline),
              title: Text(user.name),
              subtitle: Text(contact),
            ),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.location_on_outlined),
              title: Text(user.zone.isEmpty ? 'Zone unavailable' : user.zone),
              subtitle: Text(
                user.zonePincode.isEmpty
                    ? 'Pincode unavailable'
                    : user.zonePincode,
              ),
            ),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.local_shipping_outlined),
              title: Text(
                user.platform.isEmpty ? 'Platform unavailable' : user.platform,
              ),
              subtitle: Text(
                user.plan.isEmpty ? 'Plan unavailable' : '${user.plan} plan',
              ),
            ),
          ],
        );
      },
    );
  }

  void _showSupportSheet(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (_) {
        return ListView(
          shrinkWrap: true,
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 20),
          children: const [
            Text(
              'Help and support',
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
            ),
            SizedBox(height: 12),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Icon(Icons.call_outlined),
              title: Text('Claims helpline'),
              subtitle: Text('+91 1800 00 0000'),
            ),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Icon(Icons.mail_outline),
              title: Text('Support email'),
              subtitle: Text('support@saatdin.in'),
            ),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Icon(Icons.rule_folder_outlined),
              title: Text('Escalation timeline'),
              subtitle: Text('Manual escalations are reviewed within 2 hours.'),
            ),
          ],
        );
      },
    );
  }

  void _showSimpleInfo(BuildContext context, String message) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  void _switchToTab(BuildContext context, int index) {
    TabRouter.switchTo(index);
    Navigator.of(context).popUntil((route) => route.isFirst);
  }

  Future<void> _showThemeModeSheet(BuildContext context) async {
    final mode = ThemeController.instance.themeMode;
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (_) {
        return ListView(
          shrinkWrap: true,
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 20),
          children: [
            const Text(
              'Appearance mode',
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 12),
            _themeModeTile(
              context: context,
              title: 'Dark',
              subtitle: 'Best for low light and rider dashboard mode',
              selected: mode == ThemeMode.dark,
              onTap: () =>
                  ThemeController.instance.setThemeMode(ThemeMode.dark),
            ),
            _themeModeTile(
              context: context,
              title: 'Light',
              subtitle: 'High contrast daytime theme',
              selected: mode == ThemeMode.light,
              onTap: () =>
                  ThemeController.instance.setThemeMode(ThemeMode.light),
            ),
            _themeModeTile(
              context: context,
              title: 'System',
              subtitle: 'Follow your device setting automatically',
              selected: mode == ThemeMode.system,
              onTap: () =>
                  ThemeController.instance.setThemeMode(ThemeMode.system),
            ),
          ],
        );
      },
    );
  }

  Widget _themeModeTile({
    required BuildContext context,
    required String title,
    required String subtitle,
    required bool selected,
    required VoidCallback onTap,
  }) {
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Icon(
        selected ? Icons.radio_button_checked : Icons.radio_button_off,
      ),
      title: Text(title),
      subtitle: Text(subtitle),
      onTap: () {
        onTap();
        Navigator.of(context).pop();
      },
    );
  }

  String _themeSubtitle() {
    final mode = ThemeController.instance.themeMode;
    return switch (mode) {
      ThemeMode.dark => 'Currently Dark',
      ThemeMode.light => 'Currently Light',
      ThemeMode.system => 'Following System',
    };
  }

  void _confirmLogout(BuildContext context) {
    showDialog<void>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: const Text('Log out'),
          content: const Text(
            'Are you sure you want to log out of this account?',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () {
                Navigator.pop(dialogContext);
                Navigator.pushNamedAndRemoveUntil(
                  context,
                  AppRoutes.welcome,
                  (route) => false,
                );
              },
              child: const Text('Log out'),
            ),
          ],
        );
      },
    );
  }

  String _readString(
    Map<String, dynamic> raw,
    List<String> keys, {
    String fallback = '',
  }) {
    for (final key in keys) {
      final value = raw[key];
      if (value == null) continue;
      final parsed = value.toString().trim();
      if (parsed.isNotEmpty) return parsed;
    }
    return fallback;
  }

  int _readInt(
    Map<String, dynamic> raw,
    List<String> keys, {
    int fallback = 0,
  }) {
    for (final key in keys) {
      final value = raw[key];
      if (value == null) continue;
      if (value is num) return value.toInt();
      if (value is String) {
        final parsed = int.tryParse(value.replaceAll(',', '').trim());
        if (parsed != null) return parsed;
      }
    }
    return fallback;
  }

  double _readDouble(
    Map<String, dynamic> raw,
    List<String> keys, {
    double fallback = 0,
  }) {
    for (final key in keys) {
      final value = raw[key];
      if (value == null) continue;
      if (value is num) return value.toDouble();
      if (value is String) {
        final parsed = double.tryParse(value.replaceAll(',', '').trim());
        if (parsed != null) return parsed;
      }
    }
    return fallback;
  }

  Map<String, dynamic> _readMap(Map<String, dynamic> raw, List<String> keys) {
    for (final key in keys) {
      final value = raw[key];
      if (value is Map<String, dynamic>) return value;
    }
    return <String, dynamic>{};
  }

  int _claimCountForCurrentMonth(List<Claim> claims) {
    final now = DateTime.now();
    return claims.where((claim) {
      final claimDate = claim.date;
      return claimDate.year == now.year && claimDate.month == now.month;
    }).length;
  }

  double _settledPayoutTotal(List<Claim> claims) {
    return claims
        .where((claim) => claim.status == ClaimStatus.settled)
        .fold<double>(0, (sum, claim) => sum + claim.amount);
  }

  String _renewalLabel(String nextBillingDateRaw) {
    final parsed = DateTime.tryParse(nextBillingDateRaw);
    if (parsed == null) return 'Renewal date unavailable';
    return 'Renews ${DateFormat('EEE, d MMM').format(parsed.toLocal())}';
  }

  String _buildLocationLabel(User user) {
    final platform = user.platform.trim();
    final zone = user.zone.trim();
    final pincode = user.zonePincode.trim();
    if (platform.isEmpty && zone.isEmpty && pincode.isEmpty) {
      return 'Location unavailable';
    }

    final pieces = <String>[];
    if (platform.isNotEmpty) pieces.add(platform);
    if (zone.isNotEmpty) pieces.add('Zone: $zone');
    if (pincode.isNotEmpty) pieces.add('Area: $pincode');
    return pieces.join(' · ');
  }

  String _formatPhone(String phone) {
    final digits = phone.replaceAll(RegExp(r'\D'), '');
    if (digits.length == 10) {
      return '+91 ${digits.substring(0, 5)} ${digits.substring(5)}';
    }
    return phone.trim().isEmpty ? 'No contact number' : phone.trim();
  }

  String _displayInitial(String name) {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return '?';
    return trimmed.substring(0, 1).toUpperCase();
  }
}

// ─── Data class for menu items ────────────────────────────────────────────────

class _MenuItemData {
  final IconData icon;
  final Color iconBg;
  final Color iconColor;
  final String title;
  final Color? titleColor;
  final String? subtitle;
  final String? badge;
  final VoidCallback onTap;

  const _MenuItemData({
    required this.icon,
    required this.iconBg,
    required this.iconColor,
    required this.title,
    required this.onTap,
    this.titleColor,
    this.subtitle,
    this.badge,
  });
}

class _ProfileViewData {
  const _ProfileViewData({
    required this.user,
    required this.policy,
    required this.claims,
    required this.payoutDashboard,
  });

  final User user;
  final Map<String, dynamic> policy;
  final List<Claim> claims;
  final Map<String, dynamic> payoutDashboard;
}

class _ProfileTopBackgroundPainter extends CustomPainter {
  const _ProfileTopBackgroundPainter({required this.isDark});

  final bool isDark;

  @override
  void paint(Canvas canvas, Size size) {
    final backgroundPaint = Paint()
      ..shader = LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: isDark
            ? <Color>[
                AppColors.nightSurface,
                AppColors.nightSurfaceElevated,
                AppColors.nightBackground,
              ]
            : <Color>[
                const Color(0xFFE7F8F4),
                const Color(0xFFF1FBF8),
                const Color(0xFFF8FCFA),
              ],
      ).createShader(Rect.fromLTWH(0, 0, size.width, size.height));

    canvas.drawRect(
      Rect.fromLTWH(0, 0, size.width, size.height),
      backgroundPaint,
    );

    final shapePaint = Paint()
      ..color = (isDark ? AppColors.neonGreen : AppColors.primary).withValues(
        alpha: 0.12,
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
      ..color = (isDark ? AppColors.neonCyan : AppColors.primary).withValues(
        alpha: 0.16,
      );

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
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
