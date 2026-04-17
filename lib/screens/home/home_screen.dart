import 'dart:math' as math;
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:showcaseview/showcaseview.dart';

import '../../models/claim_model.dart';
import '../../models/plan_model.dart';
import '../../models/user_model.dart';
import '../../models/zone_risk_model.dart';
import '../../services/api_service.dart';
import '../../services/guide_preferences.dart';
import '../../services/tab_router.dart';
import '../../services/zone_risk_service.dart';
import '../../theme/app_colors.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final ApiService _apiService = ApiService();
  final ZoneRiskService _zoneRiskService = ZoneRiskService();
  final NumberFormat _currency = NumberFormat.currency(
    locale: 'en_IN',
    symbol: '₹',
    decimalDigits: 0,
  );
  final DateFormat _timeFormat = DateFormat('ha');

  final GlobalKey _tourStatusKey = GlobalKey();
  final GlobalKey _tourForecastKey = GlobalKey();
  final GlobalKey _tourActionsKey = GlobalKey();

  late Future<_DashboardData> _dashboardFuture;
  bool _shouldShowTour = false;
  bool _tourPreferenceResolved = false;
  bool _tourStarted = false;

  @override
  void initState() {
    super.initState();
    _dashboardFuture = _loadDashboard();
    unawaited(_resolveTourPreference());
  }

  Future<void> _resolveTourPreference() async {
    final shouldShow = await GuidePreferences.shouldShow(
      GuidePreferences.homeGuideSeen,
    );
    if (!mounted) return;
    setState(() {
      _shouldShowTour = shouldShow;
      _tourPreferenceResolved = true;
    });
  }

  Future<void> _markTourSeen() async {
    await GuidePreferences.markSeen(GuidePreferences.homeGuideSeen);
  }

  void _maybeStartTour(BuildContext context) {
    if (!_tourPreferenceResolved || !_shouldShowTour || _tourStarted) return;
    _tourStarted = true;
    unawaited(_markTourSeen());
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ShowCaseWidget.of(
        context,
      ).startShowCase([_tourStatusKey, _tourForecastKey, _tourActionsKey]);
    });
  }

  Future<void> _refresh() async {
    setState(() {
      _dashboardFuture = _loadDashboard();
    });
    await _dashboardFuture;
  }

  Future<_DashboardData> _loadDashboard() async {
    User user = const User.empty();
    Map<String, dynamic> policy = <String, dynamic>{};
    Map<String, dynamic> payoutDashboard = <String, dynamic>{};
    Map<String, dynamic> activeTriggers = <String, dynamic>{};
    List<Claim> claims = const <Claim>[];
    ZoneRisk? zoneRisk;

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
      claims = await _apiService.getClaims('me');
    } catch (_) {
      claims = const <Claim>[];
    }

    try {
      payoutDashboard = await _apiService.getPayoutDashboard();
    } catch (_) {
      payoutDashboard = <String, dynamic>{};
    }

    final zoneKey = _coerceString(
      user.zonePincode,
      fallback: _coerceString(policy['zonePincode']),
    );
    if (zoneKey.isNotEmpty) {
      try {
        zoneRisk = await _zoneRiskService.getByPincode(zoneKey);
      } catch (_) {
        zoneRisk = null;
      }
    }

    final zoneLabel = _zoneLabel(user, policy, zoneKey);
    if (zoneLabel.isNotEmpty) {
      try {
        activeTriggers = await _apiService.getActiveTriggers(zoneLabel);
      } catch (_) {
        activeTriggers = <String, dynamic>{};
      }
    }

    final plan = InsurancePlan(
      name: _coerceString(
        policy['plan'],
        fallback: user.plan.isEmpty ? 'Standard' : user.plan,
      ),
      weeklyPremium: _coerceInt(policy['weeklyPremium'], fallback: 35),
      perTriggerPayout: _coerceInt(policy['perTriggerPayout'], fallback: 250),
      maxDaysPerWeek: _coerceInt(policy['maxDaysPerWeek'], fallback: 6),
      isPopular: false,
    );

    final metrics = _buildMetrics(policy, zoneRisk, activeTriggers);
    final heroMetric = metrics.reduce(
      (left, right) => left.ratio >= right.ratio ? left : right,
    );
    final status = _deriveStatus(activeTriggers, metrics, claims);
    final latestSettled = _latestClaim(claims, ClaimStatus.settled);
    final latestProcessing =
        _latestClaim(claims, ClaimStatus.inReview) ??
        _latestClaim(claims, ClaimStatus.escalated);
    final latestRelevant =
        latestProcessing ?? latestSettled ?? _latestClaim(claims, null);
    final nearMiss = _buildNearMissSignal(metrics, activeTriggers);
    final payoutVault = _buildPayoutVault(payoutDashboard, claims, plan);

    return _DashboardData(
      user: user,
      plan: plan,
      policy: policy,
      payoutDashboard: payoutDashboard,
      activeTriggers: activeTriggers,
      claims: claims,
      zoneRisk: zoneRisk,
      metrics: metrics,
      forecast: _buildForecast(zoneRisk, status),
      status: status,
      heroMetric: heroMetric,
      latestClaim: latestRelevant,
      latestSettledClaim: latestSettled,
      upiId: _extractUpiId(payoutDashboard),
      safetyBanner: _buildSafetyBanner(zoneRisk, activeTriggers),
      safetyDetail: _buildSafetyDetail(zoneRisk, activeTriggers, zoneLabel),
      premiumBreakdown: _buildPremiumBreakdown(zoneRisk),
      nearMiss: nearMiss,
      payoutVault: payoutVault,
    );
  }

  _NearMissSignal _buildNearMissSignal(
    List<_RiskMetric> metrics,
    Map<String, dynamic> activeTriggers,
  ) {
    final sorted = metrics.toList()
      ..sort((left, right) => right.ratio.compareTo(left.ratio));
    final nearMiss = sorted.firstWhere(
      (metric) => metric.ratio < 1,
      orElse: () => sorted.first,
    );

    final fallbackMinutes = nearMiss.ratio >= 0.9 ? 12 : 24;
    final monitoringMinutes = _coerceInt(
      activeTriggers['monitoringWindowMins'],
      fallback: fallbackMinutes,
    );

    return _NearMissSignal(
      metric: nearMiss,
      monitoringMinutes: monitoringMinutes,
    );
  }

  _PayoutVault _buildPayoutVault(
    Map<String, dynamic> payoutDashboard,
    List<Claim> claims,
    InsurancePlan plan,
  ) {
    final settledAmount = claims
        .where((claim) => claim.status == ClaimStatus.settled)
        .fold<double>(0, (sum, claim) => sum + claim.amount);
    final securedAmount = _coerceDouble(
      payoutDashboard['securedAmount'],
      fallback: settledAmount,
    );

    final pendingAmount = _coerceDouble(
      payoutDashboard['potentialAmount'],
      fallback: (plan.perTriggerPayout * 2).toDouble(),
    );

    final total = securedAmount + pendingAmount;
    final securedRatio = total <= 0
        ? 0.0
        : (securedAmount / total).clamp(0.0, 1.0);

    return _PayoutVault(
      securedAmount: securedAmount,
      potentialAmount: pendingAmount,
      securedRatio: securedRatio,
    );
  }

  _ClaimSnapshot? _latestClaim(List<Claim> claims, ClaimStatus? status) {
    final filtered = status == null
        ? claims.toList()
        : claims.where((claim) => claim.status == status).toList();
    if (filtered.isEmpty) return null;
    filtered.sort((left, right) => right.date.compareTo(left.date));
    return _ClaimSnapshot.fromClaim(filtered.first);
  }

  List<_RiskMetric> _buildMetrics(
    Map<String, dynamic> policy,
    ZoneRisk? zoneRisk,
    Map<String, dynamic> activeTriggers,
  ) {
    final activeType = _coerceString(activeTriggers['alertType']).toLowerCase();
    final rainThreshold =
        (zoneRisk?.customRainLockThresholdMm3hr ??
                _coerceInt(policy['rainThresholdMm'], fallback: 50))
            .toDouble();
    final aqiThreshold = _coerceDouble(policy['aqiThreshold'], fallback: 400);
    final heatThreshold = _coerceDouble(policy['heatThresholdC'], fallback: 40);
    final trafficThreshold = _coerceDouble(
      policy['trafficThreshold'],
      fallback: 70,
    );

    final rainCurrent = _metricCurrent(
      activeTriggers,
      const ['rainMm', 'rainfallMm', 'currentRainMm', 'reading'],
      fallback:
          rainThreshold * (0.35 + ((zoneRisk?.floodRiskScore ?? 35) / 200)),
    );
    final aqiCurrent = _metricCurrent(activeTriggers, const [
      'aqi',
      'currentAqi',
      'airQuality',
      'reading',
    ], fallback: 180 + ((zoneRisk?.aqiRiskScore ?? 35) * 1.8));
    final heatCurrent = _metricCurrent(activeTriggers, const [
      'heat',
      'temperature',
      'currentHeatC',
      'reading',
    ], fallback: 32 + ((zoneRisk?.compositeRiskScore ?? 42) / 20));
    final trafficCurrent = _metricCurrent(activeTriggers, const [
      'traffic',
      'trafficScore',
      'currentTraffic',
      'reading',
    ], fallback: 28 + ((zoneRisk?.trafficCongestionScore ?? 40) * 0.8));

    return <_RiskMetric>[
      _RiskMetric(
        key: 'rain',
        label: 'Rain',
        icon: Icons.water_drop_rounded,
        current: rainCurrent,
        threshold: rainThreshold,
        unit: 'mm',
        detail:
            'Policy threshold: ${_metricLabel(rainThreshold, 'mm')} crossed at the rain-lock layer.',
        state: _metricState('rain', activeType, rainCurrent, rainThreshold),
      ),
      _RiskMetric(
        key: 'aqi',
        label: 'AQI',
        icon: Icons.air_rounded,
        current: aqiCurrent,
        threshold: aqiThreshold,
        unit: 'AQI',
        detail:
            'Policy threshold: ${_metricLabel(aqiThreshold, 'AQI')} for hazardous air.',
        state: _metricState('aqi', activeType, aqiCurrent, aqiThreshold),
      ),
      _RiskMetric(
        key: 'heat',
        label: 'Heat',
        icon: Icons.thermostat_rounded,
        current: heatCurrent,
        threshold: heatThreshold,
        unit: '°C',
        detail:
            'Policy threshold: ${_metricLabel(heatThreshold, '°C')} for extreme heat.',
        state: _metricState('heat', activeType, heatCurrent, heatThreshold),
      ),
      _RiskMetric(
        key: 'traffic',
        label: 'Traffic',
        icon: Icons.traffic_rounded,
        current: trafficCurrent,
        threshold: trafficThreshold,
        unit: 'score',
        detail:
            'Policy threshold: ${_metricLabel(trafficThreshold, 'score')} for traffic lock.',
        state: _metricState(
          'traffic',
          activeType,
          trafficCurrent,
          trafficThreshold,
        ),
      ),
    ];
  }

  List<_ForecastBlock> _buildForecast(ZoneRisk? zoneRisk, _RiskStatus status) {
    final composite = (zoneRisk?.compositeRiskScore ?? 45)
        .clamp(0, 100)
        .toDouble();
    final baseColor = switch (status.level) {
      _RiskLevel.safe => AppColors.neonGreen,
      _RiskLevel.watch => AppColors.neonAmber,
      _RiskLevel.alert => AppColors.neonRed,
      _RiskLevel.critical => AppColors.neonPurple,
    };

    return List<_ForecastBlock>.generate(12, (index) {
      final hour = DateTime.now().add(Duration(hours: index + 1));
      final intensity = (composite + (index * 4)).clamp(10, 100).toDouble();
      final severity = intensity > 80
          ? _RiskLevel.critical
          : intensity > 62
          ? _RiskLevel.alert
          : intensity > 42
          ? _RiskLevel.watch
          : _RiskLevel.safe;
      final color = switch (severity) {
        _RiskLevel.safe => AppColors.neonGreen.withValues(alpha: 0.35),
        _RiskLevel.watch => AppColors.neonAmber.withValues(alpha: 0.50),
        _RiskLevel.alert => AppColors.neonRed.withValues(alpha: 0.50),
        _RiskLevel.critical => AppColors.neonPurple.withValues(alpha: 0.60),
      };
      return _ForecastBlock(
        label: _timeFormat
            .format(hour)
            .replaceAll('AM', 'A')
            .replaceAll('PM', 'P'),
        color: color,
        caption: severity.label,
        shimmer: baseColor,
      );
    });
  }

  _RiskStatus _deriveStatus(
    Map<String, dynamic> activeTriggers,
    List<_RiskMetric> metrics,
    List<Claim> claims,
  ) {
    if (_latestClaim(claims, ClaimStatus.inReview) != null ||
        _latestClaim(claims, ClaimStatus.escalated) != null) {
      return const _RiskStatus(
        level: _RiskLevel.critical,
        label: 'Payout paused for review',
        summary:
            'Verification is active. Funds are protected until the check clears.',
      );
    }

    final activeType = _coerceString(activeTriggers['alertType']).toLowerCase();
    final hasActiveAlert =
        activeTriggers['hasActiveAlert'] == true || activeType.isNotEmpty;
    if (hasActiveAlert) {
      final breached = metrics
          .where(
            (metric) =>
                metric.state == _RiskMetricState.critical ||
                metric.state == _RiskMetricState.alert,
          )
          .toList();
      if (breached.isNotEmpty) {
        final topMetric = breached.reduce(
          (left, right) => left.ratio >= right.ratio ? left : right,
        );
        return _RiskStatus(
          level: topMetric.state == _RiskMetricState.critical
              ? _RiskLevel.critical
              : _RiskLevel.alert,
          label: '${topMetric.label} threshold crossed',
          summary:
              'A live reading is at or above the trigger. Receipt flow is ready.',
        );
      }
      return const _RiskStatus(
        level: _RiskLevel.alert,
        label: 'Conditions building fast',
        summary: 'One or more readings are approaching the payout line.',
      );
    }

    final topMetric = metrics.reduce(
      (left, right) => left.ratio >= right.ratio ? left : right,
    );
    if (topMetric.ratio >= 0.8) {
      return _RiskStatus(
        level: _RiskLevel.alert,
        label: '${topMetric.label} near trigger',
        summary:
            'The nearest signal is close enough to matter. Keep it on screen.',
      );
    }
    if (topMetric.ratio >= 0.65) {
      return const _RiskStatus(
        level: _RiskLevel.watch,
        label: 'Conditions rising',
        summary: 'The shift forecaster says keep scanning. No trigger yet.',
      );
    }
    return const _RiskStatus(
      level: _RiskLevel.safe,
      label: 'ZONE SAFE',
      summary: 'No live trigger crossed. The co-pilot is still watching.',
    );
  }

  List<_AllocationSlice> _buildPremiumBreakdown(ZoneRisk? zoneRisk) {
    final riskBoost = (zoneRisk?.compositeRiskScore ?? 50) / 100;
    final rain = (40 + (riskBoost * 12)).round().clamp(34, 52);
    final heat = (30 + (riskBoost * 4)).round().clamp(24, 36);
    final traffic = 100 - rain - heat;
    return [
      _AllocationSlice(label: 'Rain', share: rain, color: AppColors.neonCyan),
      _AllocationSlice(label: 'Heat', share: heat, color: AppColors.neonAmber),
      _AllocationSlice(
        label: 'Traffic',
        share: traffic,
        color: AppColors.neonPurple,
      ),
    ];
  }

  String _buildSafetyBanner(
    ZoneRisk? zoneRisk,
    Map<String, dynamic> activeTriggers,
  ) {
    final activeType = _coerceString(activeTriggers['alertType']).toLowerCase();
    if (activeType.contains('rain')) {
      return 'Rain is the closest trigger. Keep waterproof gear ready and stay in the thumb zone.';
    }
    if (activeType.contains('aqi') || activeType.contains('air')) {
      return 'AQI is elevated. An N95 mask is strongly recommended before the next batch of orders.';
    }
    if (activeType.contains('heat')) {
      return 'Heat is climbing. Plan a shade break and keep water visible.';
    }
    if (zoneRisk != null && zoneRisk.compositeRiskScore >= 75) {
      return 'Zone risk is high today. Expect rough patches and plan your route around them.';
    }
    return 'No severe warning right now. The app is still monitoring your shift windows.';
  }

  String _buildSafetyDetail(
    ZoneRisk? zoneRisk,
    Map<String, dynamic> activeTriggers,
    String zoneLabel,
  ) {
    final intensity = zoneRisk?.riskTier ?? 'MEDIUM';
    final nextCheck = _coerceString(activeTriggers['nextCheckAt']);
    final label = zoneLabel.isEmpty ? 'your zone' : zoneLabel;
    return 'Coverage is being checked against $label. Risk tier: $intensity${nextCheck.isNotEmpty ? ' · next check $nextCheck' : ''}.';
  }

  String _extractUpiId(Map<String, dynamic> payoutDashboard) {
    final primary = _coerceString(payoutDashboard['primaryUpi']);
    if (primary.isNotEmpty) return primary;
    final backup = _coerceString(payoutDashboard['backupUpi']);
    if (backup.isNotEmpty) return backup;
    return 'UPI not configured';
  }

  Widget _buildBody(BuildContext context, _DashboardData data) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final pageBackground = isDark
        ? AppColors.nightBackground
        : AppColors.scaffoldBackground;
    final surfaceColor = isDark
        ? AppColors.nightSurface
        : AppColors.cardBackground;
    final elevatedSurface = isDark
        ? AppColors.nightSurfaceElevated
        : AppColors.surfaceLight;
    final borderColor = isDark ? AppColors.nightBorder : AppColors.border;
    final primaryText = isDark ? Colors.white : AppColors.textPrimary;
    final secondaryText = isDark ? Colors.white70 : AppColors.textSecondary;

    final settledClaim = data.latestSettledClaim;
    final receiptAmount =
        settledClaim?.amount ??
        _coerceDouble(
          data.payoutDashboard['lastPayoutAmount'],
          fallback: data.plan.perTriggerPayout.toDouble(),
        );
    final receiptId =
        settledClaim?.id ??
        _coerceString(
          data.payoutDashboard['lastReferenceId'],
          fallback: '#READY',
        );

    return ShowCaseWidget(
      builder: (tourContext) {
        _maybeStartTour(tourContext);
        return Scaffold(
          backgroundColor: pageBackground,
          body: SafeArea(
            bottom: false,
            child: RefreshIndicator(
              color: AppColors.neonGreen,
              backgroundColor: elevatedSurface,
              onRefresh: _refresh,
              child: ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 28),
                children: [
                  _buildHeader(
                    data,
                    elevatedSurface: elevatedSurface,
                    borderColor: borderColor,
                    primaryText: primaryText,
                    secondaryText: secondaryText,
                  ),
                  const SizedBox(height: 16),
                  Showcase(
                    key: _tourStatusKey,
                    title: 'Live Shift Status',
                    description:
                        'This banner tells you if your current zone is safe, near trigger, or already crossed.',
                    child: _buildStatusBanner(
                      data.status,
                      primaryText: primaryText,
                      secondaryText: secondaryText,
                    ),
                  ),
                  const SizedBox(height: 14),
                  _RiskHexagonCard(
                    title: data.status.label,
                    summary: data.status.summary,
                    metricLabel: data.heroMetric?.label ?? 'Signal',
                    metricValue: data.heroMetric?.displayValue ?? '--',
                    metricUnit: data.heroMetric?.unit ?? '',
                    color: data.status.color,
                    onTap: () =>
                        _showMetricSheet(context, data.heroMetric, data.status),
                  ),
                  const SizedBox(height: 14),
                  _buildTriggerPills(
                    context,
                    data.metrics,
                    surfaceColor: surfaceColor,
                    primaryText: primaryText,
                    secondaryText: secondaryText,
                  ),
                  const SizedBox(height: 16),
                  _buildNearMissCard(
                    context,
                    data.nearMiss,
                    surfaceColor: surfaceColor,
                    elevatedSurface: elevatedSurface,
                    primaryText: primaryText,
                    secondaryText: secondaryText,
                  ),
                  const SizedBox(height: 16),
                  Showcase(
                    key: _tourForecastKey,
                    title: '12-Hour Forecaster',
                    description:
                        'Use this timeline to predict rough windows before they become payout events.',
                    child: _buildForecastCard(
                      data.forecast,
                      surfaceColor: surfaceColor,
                      borderColor: borderColor,
                      primaryText: primaryText,
                      secondaryText: secondaryText,
                    ),
                  ),
                  const SizedBox(height: 16),
                  _buildReceiptCard(
                    context,
                    data.status,
                    settledClaim,
                    receiptAmount,
                    receiptId,
                    data.upiId,
                  ),
                  const SizedBox(height: 16),
                  _buildPayoutVaultCard(data.payoutVault),
                  const SizedBox(height: 16),
                  _buildSafetyCard(
                    context,
                    data.safetyBanner,
                    data.safetyDetail,
                    data.zoneRisk,
                  ),
                  const SizedBox(height: 16),
                  _buildZoneRadarCard(context, data.zoneRisk),
                  const SizedBox(height: 16),
                  _buildPremiumCard(context, data.plan, data.premiumBreakdown),
                  const SizedBox(height: 16),
                  _buildLedgerCard(context, data.claims),
                  const SizedBox(height: 16),
                  Showcase(
                    key: _tourActionsKey,
                    title: 'Quick Actions',
                    description:
                        'Use these two actions when you need to report mismatch or share live location instantly.',
                    child: _buildQuickActions(context),
                  ),
                  const SizedBox(height: 22),
                  Text(
                    'Touch first, text second. All critical actions stay in the bottom thumb zone.',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: secondaryText.withValues(alpha: 0.80),
                      height: 1.3,
                    ),
                    textAlign: TextAlign.center,
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildHeader(
    _DashboardData data, {
    required Color elevatedSurface,
    required Color borderColor,
    required Color primaryText,
    required Color secondaryText,
  }) {
    final zone = _coerceString(data.user.zone, fallback: 'Zone not set');
    return Row(
      children: [
        Container(
          width: 52,
          height: 52,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(18),
            gradient: const LinearGradient(
              colors: [AppColors.neonGreen, AppColors.neonCyan],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
          ),
          child: const Icon(
            Icons.electric_bike_rounded,
            color: Colors.black,
            size: 28,
          ),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Good shift, ${_shortName(data.user.name)}',
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w800,
                  color: primaryText,
                  letterSpacing: -0.2,
                ),
              ),
              const SizedBox(height: 4),
              Text(zone, style: TextStyle(fontSize: 12, color: secondaryText)),
            ],
          ),
        ),
        InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: () => TabRouter.switchTo(3),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: elevatedSurface,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: borderColor),
            ),
            child: Text(
              'Wallet',
              style: TextStyle(color: primaryText, fontWeight: FontWeight.w700),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildStatusBanner(
    _RiskStatus status, {
    required Color primaryText,
    required Color secondaryText,
  }) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: status.color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: status.color.withValues(alpha: 0.30)),
      ),
      child: Row(
        children: [
          Container(
            width: 12,
            height: 12,
            decoration: BoxDecoration(
              color: status.color,
              shape: BoxShape.circle,
              boxShadow: [
                BoxShadow(
                  color: status.color.withValues(alpha: 0.6),
                  blurRadius: 16,
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  status.label,
                  style: TextStyle(
                    color: primaryText,
                    fontSize: 15,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  status.summary,
                  style: TextStyle(
                    color: secondaryText,
                    fontSize: 12,
                    height: 1.25,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTriggerPills(
    BuildContext context,
    List<_RiskMetric> metrics, {
    required Color surfaceColor,
    required Color primaryText,
    required Color secondaryText,
  }) {
    return Row(
      children: metrics
          .map(
            (metric) => Expanded(
              child: Padding(
                padding: const EdgeInsets.only(right: 8),
                child: InkWell(
                  borderRadius: BorderRadius.circular(18),
                  onTap: () => _showMetricSheet(context, metric, null),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 12,
                    ),
                    decoration: BoxDecoration(
                      color: surfaceColor,
                      borderRadius: BorderRadius.circular(18),
                      border: Border.all(
                        color: metric.color.withValues(alpha: 0.20),
                      ),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(metric.icon, color: metric.color, size: 18),
                        const SizedBox(height: 8),
                        Text(
                          metric.label,
                          style: TextStyle(
                            color: primaryText,
                            fontSize: 12,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          '${metric.displayValue} / ${metric.thresholdDisplay}',
                          style: TextStyle(color: secondaryText, fontSize: 11),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          )
          .toList(),
    );
  }

  Widget _buildForecastCard(
    List<_ForecastBlock> forecast, {
    required Color surfaceColor,
    required Color borderColor,
    required Color primaryText,
    required Color secondaryText,
  }) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: surfaceColor,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: borderColor),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Shift Forecaster',
            style: TextStyle(
              color: primaryText,
              fontSize: 16,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            '12-hour risk timeline for the next shift window.',
            style: TextStyle(color: secondaryText, fontSize: 12),
          ),
          const SizedBox(height: 14),
          SizedBox(
            height: 110,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: forecast.length,
              separatorBuilder: (_, _) => const SizedBox(width: 8),
              itemBuilder: (context, index) {
                final block = forecast[index];
                return Container(
                  width: 70,
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: block.color.withValues(alpha: 0.16),
                    borderRadius: BorderRadius.circular(18),
                    border: Border.all(
                      color: block.color.withValues(alpha: 0.30),
                    ),
                  ),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        block.label,
                        style: TextStyle(
                          color: primaryText,
                          fontSize: 11,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      Container(
                        height: 36,
                        width: double.infinity,
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(12),
                          gradient: LinearGradient(
                            colors: [
                              block.shimmer.withValues(alpha: 0.22),
                              block.color,
                            ],
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                          ),
                        ),
                      ),
                      Text(
                        block.caption,
                        textAlign: TextAlign.center,
                        style: TextStyle(color: secondaryText, fontSize: 10),
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildNearMissCard(
    BuildContext context,
    _NearMissSignal signal, {
    required Color surfaceColor,
    required Color elevatedSurface,
    required Color primaryText,
    required Color secondaryText,
  }) {
    final ratio = signal.metric.ratio.clamp(0.0, 1.2).toDouble();
    final progress = (ratio / 1.0).clamp(0.0, 1.0).toDouble();
    final remaining = math.max(0, signal.monitoringMinutes);

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: surfaceColor,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: AppColors.neonAmber.withValues(alpha: 0.26)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Near-Miss Tracker',
            style: TextStyle(
              color: primaryText,
              fontSize: 16,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            '${signal.metric.label} is close to threshold. Monitoring window: ${remaining}m.',
            style: TextStyle(color: secondaryText, fontSize: 12),
          ),
          const SizedBox(height: 12),
          LayoutBuilder(
            builder: (context, constraints) {
              final width = constraints.maxWidth;
              final markerX = width - 2;
              final progressWidth = width * progress;
              return Stack(
                clipBehavior: Clip.none,
                children: [
                  Container(
                    height: 14,
                    width: width,
                    decoration: BoxDecoration(
                      color: elevatedSurface,
                      borderRadius: BorderRadius.circular(999),
                    ),
                  ),
                  Container(
                    height: 14,
                    width: progressWidth,
                    decoration: BoxDecoration(
                      gradient: const LinearGradient(
                        colors: [AppColors.neonCyan, AppColors.neonAmber],
                      ),
                      borderRadius: BorderRadius.circular(999),
                    ),
                  ),
                  Positioned(
                    left: markerX,
                    top: -6,
                    bottom: -6,
                    child: Container(
                      width: 2,
                      decoration: BoxDecoration(
                        color: secondaryText.withValues(alpha: 0.76),
                        borderRadius: BorderRadius.circular(999),
                      ),
                    ),
                  ),
                ],
              );
            },
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Text(
                '${signal.metric.displayValue} now',
                style: TextStyle(
                  color: primaryText,
                  fontWeight: FontWeight.w700,
                  fontSize: 12,
                ),
              ),
              const Spacer(),
              Text(
                'Threshold ${signal.metric.thresholdDisplay}',
                style: TextStyle(color: secondaryText, fontSize: 11),
              ),
            ],
          ),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton(
              onPressed: () => _showMetricSheet(context, signal.metric, null),
              child: const Text('Open Threshold Detail'),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildReceiptCard(
    BuildContext context,
    _RiskStatus status,
    _ClaimSnapshot? settledClaim,
    double amount,
    String referenceId,
    String upiId,
  ) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final primaryText = theme.colorScheme.onSurface;
    final secondaryText = theme.colorScheme.onSurface.withValues(
      alpha: isDark ? 0.70 : 0.78,
    );
    final cardBg = isDark ? AppColors.nightSurface : theme.colorScheme.surface;
    final isPaid = settledClaim != null;
    final accent = isPaid ? AppColors.neonGreen : status.color;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: cardBg,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: accent.withValues(alpha: 0.24)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                isPaid
                    ? Icons.verified_rounded
                    : Icons.hourglass_bottom_rounded,
                color: accent,
                size: 20,
              ),
              const SizedBox(width: 8),
              Text(
                'Trigger Receipt',
                style: TextStyle(
                  color: primaryText,
                  fontSize: 16,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            isPaid
                ? '₹${amount.toInt()} sent to $upiId'
                : 'Waiting for the next crossed threshold.',
            style: TextStyle(
              color: primaryText,
              fontSize: 20,
              fontWeight: FontWeight.w900,
              letterSpacing: -0.3,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            isPaid
                ? 'Reference $referenceId · ${_formatDateTime(settledClaim.date)}'
                : 'Exact measurement vs threshold stays visible until the system decides.',
            style: TextStyle(color: secondaryText, fontSize: 12, height: 1.35),
          ),
          if (isPaid) ...[
            const SizedBox(height: 12),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: AppColors.neonGreen.withValues(alpha: 0.10),
                borderRadius: BorderRadius.circular(18),
                border: Border.all(
                  color: AppColors.neonGreen.withValues(alpha: 0.22),
                ),
              ),
              child: Text(
                'Glass-box detail: amount, destination, and timestamp are all visible here.',
                style: TextStyle(
                  color: theme.colorScheme.onSurface.withValues(
                    alpha: isDark ? 0.88 : 0.92,
                  ),
                  fontSize: 12,
                ),
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () =>
                        _showChaChingModal(context, amount, referenceId, upiId),
                    icon: const Icon(Icons.payments_rounded),
                    label: const Text('Cha-Ching View'),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: TextButton.icon(
                    onPressed: () =>
                        _downloadReceipt(context, referenceId, amount),
                    icon: const Icon(Icons.download_rounded),
                    label: const Text('Download receipt'),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildPayoutVaultCard(_PayoutVault vault) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final cardBg = isDark ? AppColors.nightSurface : theme.colorScheme.surface;
    final cardBorder = isDark
        ? AppColors.nightBorder
        : theme.colorScheme.outline.withValues(alpha: 0.28);
    final primaryText = theme.colorScheme.onSurface;
    final secondaryText = theme.colorScheme.onSurface.withValues(
      alpha: isDark ? 0.62 : 0.74,
    );
    final secured = vault.securedAmount;
    final potential = vault.potentialAmount;
    final ratio = vault.securedRatio;

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
          Text(
            'Payout Vault',
            style: TextStyle(
              color: primaryText,
              fontSize: 16,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            'Secured vs potential payout, always visible.',
            style: TextStyle(color: secondaryText, fontSize: 12),
          ),
          const SizedBox(height: 14),
          ClipRRect(
            borderRadius: BorderRadius.circular(999),
            child: SizedBox(
              height: 18,
              child: Row(
                children: [
                  Expanded(
                    flex: math.max(1, (ratio * 100).round()),
                    child: Container(color: AppColors.neonGreen),
                  ),
                  Expanded(
                    flex: math.max(1, ((1 - ratio) * 100).round()),
                    child: Container(
                      color: AppColors.neonAmber.withValues(alpha: 0.75),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: _vaultMetric(
                  context: context,
                  label: 'Secured',
                  value: _currency.format(secured),
                  color: AppColors.neonGreen,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _vaultMetric(
                  context: context,
                  label: 'Potential',
                  value: _currency.format(potential),
                  color: AppColors.neonAmber,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _vaultMetric({
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
    final primaryText = Theme.of(context).colorScheme.onSurface;
    final secondaryText = Theme.of(
      context,
    ).colorScheme.onSurface.withValues(alpha: isDark ? 0.64 : 0.74);
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        children: [
          Container(
            width: 9,
            height: 9,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: TextStyle(color: secondaryText, fontSize: 11),
                ),
                const SizedBox(height: 2),
                Text(
                  value,
                  style: TextStyle(
                    color: primaryText,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSafetyCard(
    BuildContext context,
    String banner,
    String detail,
    ZoneRisk? zoneRisk,
  ) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final primaryText = theme.colorScheme.onSurface;
    final secondaryText = theme.colorScheme.onSurface.withValues(
      alpha: isDark ? 0.68 : 0.76,
    );
    final cardBg = isDark ? AppColors.nightSurface : theme.colorScheme.surface;
    final cardBorder = isDark
        ? AppColors.nightBorder
        : theme.colorScheme.outline.withValues(alpha: 0.28);
    final tier = zoneRisk?.riskTier ?? 'MEDIUM';
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
              const Icon(
                Icons.shield_moon_rounded,
                color: AppColors.neonCyan,
                size: 20,
              ),
              const SizedBox(width: 8),
              Text(
                'Safety Banner',
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
                  color: AppColors.neonCyan.withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text(
                  tier,
                  style: const TextStyle(
                    color: AppColors.neonCyan,
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            banner,
            style: TextStyle(
              color: primaryText,
              fontSize: 15,
              fontWeight: FontWeight.w700,
              height: 1.35,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            detail,
            style: TextStyle(color: secondaryText, fontSize: 12, height: 1.35),
          ),
        ],
      ),
    );
  }

  Widget _buildZoneRadarCard(BuildContext context, ZoneRisk? zoneRisk) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final primaryText = theme.colorScheme.onSurface;
    final secondaryText = theme.colorScheme.onSurface.withValues(
      alpha: isDark ? 0.62 : 0.74,
    );
    final cardBg = isDark ? AppColors.nightSurface : theme.colorScheme.surface;
    final cardBorder = isDark
        ? AppColors.nightBorder
        : theme.colorScheme.outline.withValues(alpha: 0.28);
    final rain = zoneRisk?.floodRiskScore ?? 32;
    final aqi = zoneRisk?.aqiRiskScore ?? 28;
    final traffic = zoneRisk?.trafficCongestionScore ?? 40;
    final composite = zoneRisk?.compositeRiskScore ?? 35;

    final points = <_RadarPoint>[
      _RadarPoint(label: 'Rain', value: rain),
      _RadarPoint(label: 'AQI', value: aqi),
      _RadarPoint(label: 'Traffic', value: traffic),
      _RadarPoint(label: 'Composite', value: composite),
    ];

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
          Text(
            'Zone Risk Radar',
            style: TextStyle(
              color: primaryText,
              fontSize: 16,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            'Live risk fingerprint for your delivery zone.',
            style: TextStyle(color: secondaryText, fontSize: 12),
          ),
          const SizedBox(height: 12),
          GridView.builder(
            itemCount: points.length,
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 2,
              childAspectRatio: 1.9,
              crossAxisSpacing: 10,
              mainAxisSpacing: 10,
            ),
            itemBuilder: (context, index) {
              final point = points[index];
              final tone = _riskTone(point.value);
              return Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: tone.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: tone.withValues(alpha: 0.24)),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      point.label,
                      style: TextStyle(
                        color: primaryText,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const Spacer(),
                    Text(
                      '${point.value.toStringAsFixed(0)} / 100',
                      style: TextStyle(
                        color: primaryText.withValues(alpha: 0.88),
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
        ],
      ),
    );
  }

  Widget _buildPremiumCard(
    BuildContext context,
    InsurancePlan plan,
    List<_AllocationSlice> allocation,
  ) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final primaryText = theme.colorScheme.onSurface;
    final secondaryText = theme.colorScheme.onSurface.withValues(
      alpha: isDark ? 0.62 : 0.74,
    );
    final cardBg = isDark ? AppColors.nightSurface : theme.colorScheme.surface;
    final cardBorder = isDark
        ? AppColors.nightBorder
        : theme.colorScheme.outline.withValues(alpha: 0.28);
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
          Text(
            'Premium Allocation',
            style: TextStyle(
              color: primaryText,
              fontSize: 16,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            '₹${plan.weeklyPremium}/week · Max payout ₹${plan.perTriggerPayout}',
            style: TextStyle(color: secondaryText, fontSize: 12),
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              SizedBox(
                width: 122,
                height: 122,
                child: CustomPaint(
                  painter: _AllocationDonutPainter(allocation),
                  child: Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          '₹35',
                          style: TextStyle(
                            color: primaryText,
                            fontSize: 22,
                            fontWeight: FontWeight.w900,
                          ),
                        ),
                        SizedBox(height: 2),
                        Text(
                          'weekly shield',
                          style: TextStyle(color: secondaryText, fontSize: 10),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  children: allocation.map((slice) {
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 10),
                      child: Row(
                        children: [
                          Container(
                            width: 10,
                            height: 10,
                            decoration: BoxDecoration(
                              color: slice.color,
                              shape: BoxShape.circle,
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              slice.label,
                              style: TextStyle(
                                color: primaryText,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                          Text(
                            '${slice.share}%',
                            style: TextStyle(
                              color: primaryText.withValues(alpha: 0.76),
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ],
                      ),
                    );
                  }).toList(),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildLedgerCard(BuildContext context, List<Claim> claims) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final cardBg = isDark ? AppColors.nightSurface : theme.colorScheme.surface;
    final elevatedBg = isDark
        ? AppColors.nightSurfaceElevated
        : theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.75);
    final cardBorder = isDark
        ? AppColors.nightBorder
        : theme.colorScheme.outline.withValues(alpha: 0.28);
    final primaryText = theme.colorScheme.onSurface;
    final secondaryText = theme.colorScheme.onSurface.withValues(
      alpha: isDark ? 0.64 : 0.74,
    );
    final ordered = claims.toList()
      ..sort((left, right) => right.date.compareTo(left.date));
    final recent = ordered.take(4).toList();

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
                'Claim Ledger',
                style: TextStyle(
                  color: primaryText,
                  fontSize: 16,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const Spacer(),
              TextButton(
                onPressed: () => TabRouter.switchTo(1),
                child: const Text('Open claims'),
              ),
            ],
          ),
          const SizedBox(height: 8),
          if (recent.isEmpty)
            _emptyState(
              context: context,
              icon: Icons.receipt_long_rounded,
              title: 'No ledger yet',
              message: 'Settled payouts and threshold checks will appear here.',
            )
          else
            Column(
              children: recent.map((claim) {
                final statusColor = _statusColor(claim.status);
                return Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: elevatedBg,
                      borderRadius: BorderRadius.circular(18),
                      border: Border.all(
                        color: statusColor.withValues(alpha: 0.18),
                      ),
                    ),
                    child: Row(
                      children: [
                        Container(
                          width: 40,
                          height: 40,
                          decoration: BoxDecoration(
                            color: statusColor.withValues(alpha: 0.14),
                            shape: BoxShape.circle,
                          ),
                          child: Icon(
                            claim.typeIcon,
                            color: statusColor,
                            size: 20,
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                claim.typeName,
                                style: TextStyle(
                                  color: primaryText,
                                  fontWeight: FontWeight.w800,
                                ),
                              ),
                              const SizedBox(height: 3),
                              Text(
                                '${_formatShortDate(claim.date)} · ${claim.description.isEmpty ? claim.statusLabel : claim.description}',
                                style: TextStyle(
                                  color: secondaryText,
                                  fontSize: 12,
                                ),
                              ),
                            ],
                          ),
                        ),
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: [
                            Text(
                              _currency.format(claim.amount),
                              style: TextStyle(
                                color: primaryText,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 4,
                              ),
                              decoration: BoxDecoration(
                                color: statusColor.withValues(alpha: 0.14),
                                borderRadius: BorderRadius.circular(999),
                              ),
                              child: Text(
                                claim.statusLabel,
                                style: TextStyle(
                                  color: statusColor,
                                  fontSize: 10,
                                  fontWeight: FontWeight.w800,
                                ),
                              ),
                            ),
                            if (claim.status == ClaimStatus.settled) ...[
                              const SizedBox(height: 4),
                              InkWell(
                                onTap: () => _downloadReceipt(
                                  context,
                                  claim.id,
                                  claim.amount,
                                ),
                                borderRadius: BorderRadius.circular(10),
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 6,
                                    vertical: 2,
                                  ),
                                  child: Text(
                                    'Receipt',
                                    style: TextStyle(
                                      color: primaryText.withValues(
                                        alpha: 0.84,
                                      ),
                                      fontSize: 11,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          ],
                        ),
                      ],
                    ),
                  ),
                );
              }).toList(),
            ),
        ],
      ),
    );
  }

  Widget _buildQuickActions(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Row(
      children: [
        Expanded(
          child: _QuickActionButton(
            icon: Icons.report_gmailerrorred_rounded,
            label: 'Report discrepancy',
            color: isDark ? AppColors.neonAmber : AppColors.warning,
            onTap: () => _showDiscrepancySheet(context),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: _QuickActionButton(
            icon: Icons.my_location_rounded,
            label: 'Share live location',
            color: isDark ? AppColors.neonGreen : AppColors.success,
            onTap: () => _showVerificationSheet(context),
          ),
        ),
      ],
    );
  }

  Widget _emptyState({
    required BuildContext context,
    required IconData icon,
    required String title,
    required String message,
  }) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final bg = isDark
        ? AppColors.nightSurfaceElevated
        : theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.75);
    final primaryText = theme.colorScheme.onSurface;
    final secondaryText = theme.colorScheme.onSurface.withValues(
      alpha: isDark ? 0.62 : 0.74,
    );
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(18),
      ),
      child: Column(
        children: [
          Icon(icon, color: secondaryText, size: 28),
          const SizedBox(height: 8),
          Text(
            title,
            style: TextStyle(color: primaryText, fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 4),
          Text(
            message,
            textAlign: TextAlign.center,
            style: TextStyle(color: secondaryText, fontSize: 12),
          ),
        ],
      ),
    );
  }

  void _showMetricSheet(
    BuildContext context,
    _RiskMetric? metric,
    _RiskStatus? status,
  ) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final sheetBg = isDark
        ? AppColors.nightSurface
        : Theme.of(context).colorScheme.surface;
    final primaryText = Theme.of(context).colorScheme.onSurface;
    final secondaryText = Theme.of(
      context,
    ).colorScheme.onSurface.withValues(alpha: isDark ? 0.72 : 0.84);
    final title = metric?.label ?? status?.label ?? 'Risk detail';
    final body = metric?.detail ?? status?.summary ?? 'No detail available.';
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: sheetBg,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      builder: (context) {
        return Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                  width: 44,
                  height: 4,
                  decoration: BoxDecoration(
                    color: secondaryText.withValues(alpha: 0.34),
                    borderRadius: BorderRadius.circular(999),
                  ),
                ),
              ),
              const SizedBox(height: 18),
              Text(
                title,
                style: TextStyle(
                  color: primaryText,
                  fontSize: 20,
                  fontWeight: FontWeight.w900,
                ),
              ),
              const SizedBox(height: 8),
              Text(body, style: TextStyle(color: secondaryText, height: 1.35)),
              if (metric != null) ...[
                const SizedBox(height: 16),
                _readingRow('Current', metric.displayValue),
                _readingRow('Threshold', metric.thresholdDisplay),
                _readingRow('Gap', metric.gapDisplay),
              ],
              const SizedBox(height: 18),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('Close'),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  void _showDiscrepancySheet(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final sheetBg = isDark ? AppColors.nightSurface : theme.colorScheme.surface;
    final primaryText = theme.colorScheme.onSurface;
    final secondaryText = theme.colorScheme.onSurface.withValues(
      alpha: isDark ? 0.68 : 0.78,
    );
    final chipBg = isDark
        ? AppColors.nightSurfaceElevated
        : theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.75);
    String? selectedReason;
    final options = <String>[
      'Rain heavier',
      'Traffic stopped',
      'Heat extreme',
      'AQI spike',
    ];
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: sheetBg,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      builder: (sheetContext) {
        return StatefulBuilder(
          builder: (context, setSheetState) {
            return Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Center(
                    child: Container(
                      width: 44,
                      height: 4,
                      decoration: BoxDecoration(
                        color: secondaryText.withValues(alpha: 0.28),
                        borderRadius: BorderRadius.circular(999),
                      ),
                    ),
                  ),
                  const SizedBox(height: 18),
                  Text(
                    'Report a discrepancy',
                    style: TextStyle(
                      color: primaryText,
                      fontSize: 20,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Pick one reason. No typing needed. We will log the report and follow up within 24 hours.',
                    style: TextStyle(color: secondaryText, height: 1.35),
                  ),
                  const SizedBox(height: 16),
                  Wrap(
                    spacing: 10,
                    runSpacing: 10,
                    children: options.map((label) {
                      final isSelected = selectedReason == label;
                      return ChoiceChip(
                        label: Text(label),
                        selected: isSelected,
                        onSelected: (_) =>
                            setSheetState(() => selectedReason = label),
                        selectedColor: AppColors.neonGreen.withValues(
                          alpha: 0.18,
                        ),
                        backgroundColor: chipBg,
                        labelStyle: TextStyle(
                          color: isSelected ? primaryText : secondaryText,
                          fontWeight: FontWeight.w700,
                        ),
                      );
                    }).toList(),
                  ),
                  const SizedBox(height: 16),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton(
                      onPressed: selectedReason == null
                          ? null
                          : () {
                              Navigator.of(sheetContext).pop();
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                  content: Text(
                                    'Report logged: $selectedReason. Cross-checking within 24 hours.',
                                  ),
                                ),
                              );
                            },
                      child: const Text('Submit report'),
                    ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  void _downloadReceipt(BuildContext context, String reference, double amount) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          'Receipt queued: $reference · ${_currency.format(amount)}',
        ),
      ),
    );
  }

  Future<void> _showChaChingModal(
    BuildContext context,
    double amount,
    String reference,
    String upiId,
  ) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final dialogBg = isDark
        ? AppColors.nightBackground
        : theme.colorScheme.surface;
    final primaryText = theme.colorScheme.onSurface;
    final secondaryText = theme.colorScheme.onSurface.withValues(
      alpha: isDark ? 0.68 : 0.78,
    );
    return showDialog<void>(
      context: context,
      barrierDismissible: true,
      builder: (dialogContext) {
        return Dialog.fullscreen(
          backgroundColor: dialogBg,
          child: SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(22, 18, 22, 28),
              child: Column(
                children: [
                  Align(
                    alignment: Alignment.centerRight,
                    child: IconButton(
                      onPressed: () => Navigator.of(dialogContext).pop(),
                      icon: const Icon(
                        Icons.close_rounded,
                        color: AppColors.neonGreen,
                      ),
                    ),
                  ),
                  const Spacer(),
                  Container(
                    width: 118,
                    height: 118,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: AppColors.neonGreen.withValues(alpha: 0.18),
                      border: Border.all(
                        color: AppColors.neonGreen.withValues(alpha: 0.4),
                      ),
                    ),
                    child: const Icon(
                      Icons.check_rounded,
                      size: 72,
                      color: AppColors.neonGreen,
                    ),
                  ),
                  const SizedBox(height: 24),
                  const Text(
                    'CHA-CHING!',
                    style: TextStyle(
                      color: AppColors.neonGreen,
                      fontSize: 34,
                      fontWeight: FontWeight.w900,
                      letterSpacing: 1.2,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    _currency.format(amount),
                    style: TextStyle(
                      color: primaryText,
                      fontSize: 44,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    'Sent to $upiId',
                    style: TextStyle(color: secondaryText, fontSize: 14),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    'Ref $reference',
                    style: TextStyle(
                      color: secondaryText.withValues(alpha: 0.82),
                      fontSize: 12,
                      fontFamily: 'monospace',
                    ),
                  ),
                  const Spacer(),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton.icon(
                      onPressed: () {
                        Navigator.of(dialogContext).pop();
                        _downloadReceipt(context, reference, amount);
                      },
                      icon: const Icon(Icons.download_rounded),
                      label: const Text('Download Receipt'),
                    ),
                  ),
                  const SizedBox(height: 10),
                  SizedBox(
                    width: double.infinity,
                    child: OutlinedButton(
                      onPressed: () => Navigator.of(dialogContext).pop(),
                      child: const Text('Back to Dashboard'),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Color _riskTone(double score) {
    if (score >= 80) return AppColors.neonRed;
    if (score >= 60) return AppColors.neonAmber;
    if (score >= 40) return AppColors.neonCyan;
    return AppColors.neonGreen;
  }

  void _showVerificationSheet(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final sheetBg = isDark ? AppColors.nightSurface : theme.colorScheme.surface;
    final primaryText = theme.colorScheme.onSurface;
    final secondaryText = theme.colorScheme.onSurface.withValues(
      alpha: isDark ? 0.68 : 0.78,
    );
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: sheetBg,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      builder: (sheetContext) {
        return Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                  width: 44,
                  height: 4,
                  decoration: BoxDecoration(
                    color: secondaryText.withValues(alpha: 0.28),
                    borderRadius: BorderRadius.circular(999),
                  ),
                ),
              ),
              const SizedBox(height: 18),
              Text(
                'Security verification',
                style: TextStyle(
                  color: primaryText,
                  fontSize: 20,
                  fontWeight: FontWeight.w900,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'This protects your payout if location data looks unusual.',
                style: TextStyle(color: secondaryText, height: 1.35),
              ),
              const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: isDark
                      ? AppColors.nightSurfaceElevated
                      : theme.colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(18),
                  border: Border.all(
                    color: AppColors.neonGreen.withValues(alpha: 0.22),
                  ),
                ),
                child: const Column(
                  children: [
                    _StepperRow(label: 'Trigger met', done: true),
                    SizedBox(height: 10),
                    _StepperRow(label: 'Verification processing', done: false),
                    SizedBox(height: 10),
                    _StepperRow(label: 'Payout initiated', done: false),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: () {
                    Navigator.of(sheetContext).pop();
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text(
                          'Live location request started for 5 minutes.',
                        ),
                      ),
                    );
                  },
                  child: const Text('Share live location for 5 minutes'),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _readingRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          Text(
            label,
            style: TextStyle(color: Colors.white.withValues(alpha: 0.68)),
          ),
          const Spacer(),
          Text(
            value,
            style: const TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.w800,
            ),
          ),
        ],
      ),
    );
  }

  _RiskMetricState _metricState(
    String key,
    String activeType,
    double current,
    double threshold,
  ) {
    if (activeType.contains(key)) {
      return current >= threshold
          ? _RiskMetricState.critical
          : _RiskMetricState.alert;
    }
    final ratio = threshold <= 0 ? 0.0 : current / threshold;
    if (ratio >= 1.0) return _RiskMetricState.critical;
    if (ratio >= 0.8) return _RiskMetricState.alert;
    if (ratio >= 0.65) return _RiskMetricState.watch;
    return _RiskMetricState.safe;
  }

  double _metricCurrent(
    Map<String, dynamic> source,
    List<String> keys, {
    required double fallback,
  }) {
    for (final key in keys) {
      final value = source[key];
      if (value is num) return value.toDouble();
      if (value is String) {
        final parsed = double.tryParse(value.replaceAll(',', '').trim());
        if (parsed != null) return parsed;
      }
    }
    return fallback;
  }

  String _metricLabel(double value, String unit) {
    if (unit == 'AQI' || unit == 'score') {
      return value.toStringAsFixed(0);
    }
    return value.truncateToDouble() == value
        ? value.toStringAsFixed(0)
        : value.toStringAsFixed(1);
  }

  String _formatShortDate(DateTime value) =>
      DateFormat('d MMM').format(value.toLocal());

  String _formatDateTime(DateTime value) =>
      DateFormat('d MMM, h:mm a').format(value.toLocal());

  Color _statusColor(ClaimStatus status) {
    return switch (status) {
      ClaimStatus.pending => AppColors.neonAmber,
      ClaimStatus.inReview => AppColors.neonCyan,
      ClaimStatus.escalated => AppColors.neonPurple,
      ClaimStatus.settled => AppColors.neonGreen,
      ClaimStatus.rejected => AppColors.neonRed,
    };
  }

  String _zoneLabel(User user, Map<String, dynamic> policy, String zoneKey) {
    final zone = _coerceString(
      user.zone,
      fallback: _coerceString(policy['zone']),
    );
    if (zone.isNotEmpty) return zone;
    if (zoneKey.isNotEmpty) return zoneKey;
    return 'Zone not set';
  }

  String _shortName(String value) {
    final trimmed = value.trim();
    if (trimmed.isEmpty) return 'Rider';
    final first = trimmed.split(RegExp(r'\s+')).first;
    return first.length > 12 ? first.substring(0, 12) : first;
  }

  String _coerceString(Object? value, {String fallback = ''}) {
    final parsed = value?.toString().trim() ?? '';
    return parsed.isEmpty ? fallback : parsed;
  }

  int _coerceInt(Object? value, {required int fallback}) {
    if (value is num) return value.toInt();
    if (value is String) {
      final parsed = int.tryParse(value.replaceAll(',', '').trim());
      if (parsed != null) return parsed;
    }
    return fallback;
  }

  double _coerceDouble(Object? value, {required double fallback}) {
    if (value is num) return value.toDouble();
    if (value is String) {
      final parsed = double.tryParse(value.replaceAll(',', '').trim());
      if (parsed != null) return parsed;
    }
    return fallback;
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<_DashboardData>(
      future: _dashboardFuture,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Scaffold(
            backgroundColor: AppColors.nightBackground,
            body: Center(
              child: CircularProgressIndicator(color: AppColors.neonGreen),
            ),
          );
        }

        if (snapshot.hasError || snapshot.data == null) {
          return Scaffold(
            backgroundColor: AppColors.nightBackground,
            body: Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  'Failed to load the rider dashboard. Pull to retry after checking the session.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.white.withValues(alpha: 0.72)),
                ),
              ),
            ),
          );
        }

        return _buildBody(context, snapshot.data!);
      },
    );
  }
}

class _DashboardData {
  const _DashboardData({
    required this.user,
    required this.plan,
    required this.policy,
    required this.payoutDashboard,
    required this.activeTriggers,
    required this.claims,
    required this.zoneRisk,
    required this.metrics,
    required this.forecast,
    required this.status,
    required this.heroMetric,
    required this.latestClaim,
    required this.latestSettledClaim,
    required this.upiId,
    required this.safetyBanner,
    required this.safetyDetail,
    required this.premiumBreakdown,
    required this.nearMiss,
    required this.payoutVault,
  });

  final User user;
  final InsurancePlan plan;
  final Map<String, dynamic> policy;
  final Map<String, dynamic> payoutDashboard;
  final Map<String, dynamic> activeTriggers;
  final List<Claim> claims;
  final ZoneRisk? zoneRisk;
  final List<_RiskMetric> metrics;
  final List<_ForecastBlock> forecast;
  final _RiskStatus status;
  final _RiskMetric? heroMetric;
  final _ClaimSnapshot? latestClaim;
  final _ClaimSnapshot? latestSettledClaim;
  final String upiId;
  final String safetyBanner;
  final String safetyDetail;
  final List<_AllocationSlice> premiumBreakdown;
  final _NearMissSignal nearMiss;
  final _PayoutVault payoutVault;
}

class _NearMissSignal {
  const _NearMissSignal({
    required this.metric,
    required this.monitoringMinutes,
  });

  final _RiskMetric metric;
  final int monitoringMinutes;
}

class _PayoutVault {
  const _PayoutVault({
    required this.securedAmount,
    required this.potentialAmount,
    required this.securedRatio,
  });

  final double securedAmount;
  final double potentialAmount;
  final double securedRatio;
}

class _RadarPoint {
  const _RadarPoint({required this.label, required this.value});

  final String label;
  final double value;
}

class _ClaimSnapshot {
  const _ClaimSnapshot({
    required this.id,
    required this.amount,
    required this.date,
    required this.typeLabel,
  });

  factory _ClaimSnapshot.fromClaim(Claim claim) {
    return _ClaimSnapshot(
      id: claim.id,
      amount: claim.amount,
      date: claim.date,
      typeLabel: claim.typeName,
    );
  }

  final String id;
  final double amount;
  final DateTime date;
  final String typeLabel;
}

class _RiskMetric {
  const _RiskMetric({
    required this.key,
    required this.label,
    required this.icon,
    required this.current,
    required this.threshold,
    required this.unit,
    required this.detail,
    required this.state,
  });

  final String key;
  final String label;
  final IconData icon;
  final double current;
  final double threshold;
  final String unit;
  final String detail;
  final _RiskMetricState state;

  double get ratio {
    if (threshold <= 0) return 0;
    return (current / threshold).clamp(0, 1.5).toDouble();
  }

  String get displayValue => '${_formatNumber(current)} $unit';
  String get thresholdDisplay => '${_formatNumber(threshold)} $unit';
  String get gapDisplay {
    final gap = (threshold - current).abs();
    return current >= threshold
        ? 'Crossed by ${_formatNumber(gap)} $unit'
        : 'Needs ${_formatNumber(gap)} $unit';
  }

  Color get color {
    return switch (state) {
      _RiskMetricState.safe => AppColors.neonGreen,
      _RiskMetricState.watch => AppColors.neonAmber,
      _RiskMetricState.alert => AppColors.neonRed,
      _RiskMetricState.critical => AppColors.neonPurple,
    };
  }

  static String _formatNumber(double value) {
    return value.truncateToDouble() == value
        ? value.toStringAsFixed(0)
        : value.toStringAsFixed(1);
  }
}

enum _RiskMetricState { safe, watch, alert, critical }

enum _RiskLevel { safe, watch, alert, critical }

extension _RiskLevelLabel on _RiskLevel {
  String get label {
    return switch (this) {
      _RiskLevel.safe => 'SAFE',
      _RiskLevel.watch => 'WATCH',
      _RiskLevel.alert => 'ALERT',
      _RiskLevel.critical => 'CRITICAL',
    };
  }
}

class _RiskStatus {
  const _RiskStatus({
    required this.level,
    required this.label,
    required this.summary,
  });

  final _RiskLevel level;
  final String label;
  final String summary;

  Color get color {
    return switch (level) {
      _RiskLevel.safe => AppColors.neonGreen,
      _RiskLevel.watch => AppColors.neonAmber,
      _RiskLevel.alert => AppColors.neonRed,
      _RiskLevel.critical => AppColors.neonPurple,
    };
  }
}

class _ForecastBlock {
  const _ForecastBlock({
    required this.label,
    required this.color,
    required this.caption,
    required this.shimmer,
  });

  final String label;
  final Color color;
  final String caption;
  final Color shimmer;
}

class _AllocationSlice {
  const _AllocationSlice({
    required this.label,
    required this.share,
    required this.color,
  });

  final String label;
  final int share;
  final Color color;
}

class _QuickActionButton extends StatelessWidget {
  const _QuickActionButton({
    required this.icon,
    required this.label,
    required this.color,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bgColor = isDark
        ? AppColors.nightSurface
        : Theme.of(context).colorScheme.surface;
    final borderColor = isDark
        ? color.withValues(alpha: 0.22)
        : color.withValues(alpha: 0.34);
    final textColor = Theme.of(context).colorScheme.onSurface;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(20),
        child: Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: bgColor,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: borderColor),
          ),
          child: Column(
            children: [
              Icon(icon, color: color, size: 24),
              const SizedBox(height: 8),
              Text(
                label,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: textColor,
                  fontWeight: FontWeight.w800,
                  fontSize: 12,
                  height: 1.2,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _StepperRow extends StatelessWidget {
  const _StepperRow({required this.label, required this.done});

  final String label;
  final bool done;

  @override
  Widget build(BuildContext context) {
    final color = done
        ? AppColors.neonGreen
        : Colors.white.withValues(alpha: 0.45);
    return Row(
      children: [
        Container(
          width: 16,
          height: 16,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          child: done
              ? const Icon(Icons.check_rounded, color: Colors.black, size: 12)
              : null,
        ),
        const SizedBox(width: 10),
        Text(
          label,
          style: TextStyle(color: color, fontWeight: FontWeight.w700),
        ),
      ],
    );
  }
}

class _RiskHexagonCard extends StatelessWidget {
  const _RiskHexagonCard({
    required this.title,
    required this.summary,
    required this.metricLabel,
    required this.metricValue,
    required this.metricUnit,
    required this.color,
    required this.onTap,
  });

  final String title;
  final String summary;
  final String metricLabel;
  final String metricValue;
  final String metricUnit;
  final Color color;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final cardBg = isDark ? AppColors.nightSurface : theme.colorScheme.surface;
    final cardBorder = isDark
        ? color.withValues(alpha: 0.22)
        : color.withValues(alpha: 0.18);
    final titleColor = theme.colorScheme.onSurface.withValues(
      alpha: isDark ? 0.75 : 0.78,
    );
    final primaryText = theme.colorScheme.onSurface;
    final secondaryText = theme.colorScheme.onSurface.withValues(
      alpha: isDark ? 0.70 : 0.76,
    );
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(32),
        child: Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: cardBg,
            borderRadius: BorderRadius.circular(32),
            border: Border.all(color: cardBorder),
          ),
          child: Column(
            children: [
              ClipPath(
                clipper: _HexagonClipper(),
                child: Container(
                  height: 220,
                  width: double.infinity,
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      colors: [
                        color.withValues(alpha: 0.20),
                        isDark
                            ? AppColors.nightSurfaceElevated
                            : theme.colorScheme.surfaceContainerHighest,
                      ],
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                    ),
                  ),
                  child: Stack(
                    children: [
                      Positioned.fill(
                        child: CustomPaint(painter: _GlowPainter(color)),
                      ),
                      Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              title,
                              style: TextStyle(
                                color: titleColor,
                                fontSize: 12,
                                fontWeight: FontWeight.w800,
                                letterSpacing: 1.1,
                              ),
                            ),
                            const SizedBox(height: 10),
                            Text(
                              metricValue,
                              style: TextStyle(
                                color: primaryText,
                                fontSize: 52,
                                fontWeight: FontWeight.w900,
                                letterSpacing: -1.2,
                              ),
                            ),
                            if (metricUnit.isNotEmpty)
                              Text(
                                metricUnit,
                                style: TextStyle(
                                  color: secondaryText,
                                  fontSize: 14,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            const SizedBox(height: 8),
                            Text(
                              metricLabel,
                              style: TextStyle(
                                color: color,
                                fontSize: 14,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Text(
                summary,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: secondaryText,
                  fontSize: 12,
                  height: 1.35,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _HexagonClipper extends CustomClipper<Path> {
  @override
  Path getClip(Size size) {
    final path = Path();
    final width = size.width;
    final height = size.height;
    path.moveTo(width * 0.25, 0);
    path.lineTo(width * 0.75, 0);
    path.lineTo(width, height * 0.5);
    path.lineTo(width * 0.75, height);
    path.lineTo(width * 0.25, height);
    path.lineTo(0, height * 0.5);
    path.close();
    return path;
  }

  @override
  bool shouldReclip(covariant CustomClipper<Path> oldClipper) => false;
}

class _GlowPainter extends CustomPainter {
  const _GlowPainter(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..shader =
          RadialGradient(
            colors: [color.withValues(alpha: 0.55), Colors.transparent],
          ).createShader(
            Rect.fromCircle(
              center: Offset(size.width * 0.5, size.height * 0.5),
              radius: size.shortestSide * 0.55,
            ),
          );
    canvas.drawCircle(
      Offset(size.width * 0.5, size.height * 0.5),
      size.shortestSide * 0.42,
      paint,
    );
  }

  @override
  bool shouldRepaint(covariant _GlowPainter oldDelegate) =>
      oldDelegate.color != color;
}

class _AllocationDonutPainter extends CustomPainter {
  _AllocationDonutPainter(this.slices);

  final List<_AllocationSlice> slices;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final stroke = math.max(14.0, size.shortestSide * 0.14);
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.round;
    double start = -math.pi / 2;
    const sweepBase = 2 * math.pi;
    for (final slice in slices) {
      paint.color = slice.color;
      final sweep = sweepBase * (slice.share / 100);
      canvas.drawArc(rect.deflate(stroke / 2), start, sweep, false, paint);
      start += sweep;
    }
  }

  @override
  bool shouldRepaint(covariant _AllocationDonutPainter oldDelegate) =>
      oldDelegate.slices != slices;
}
