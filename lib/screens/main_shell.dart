import 'dart:async';

import 'package:flutter/material.dart';
import '../../theme/app_colors.dart';
import '../../services/signal_capture_service.dart';
import '../../services/tab_router.dart';
import 'home/home_screen.dart';
import 'claims/claims_screen.dart';
import 'coverage/coverage_screen.dart';
import 'payouts/payouts_screen.dart';
import 'profile/profile_screen.dart';

class MainShell extends StatefulWidget {
  const MainShell({super.key});

  @override
  State<MainShell> createState() => _MainShellState();
}

class _MainShellState extends State<MainShell> {
  int _currentIndex = 0;
  late final List<Widget?> _loadedScreens;

  static const int _homeTabIndex = 0;
  static const int _claimsTabIndex = 1;
  static const int _coverageTabIndex = 2;
  static const int _payoutsTabIndex = 3;
  static const int _profileTabIndex = 4;

  @override
  void initState() {
    super.initState();
    TabRouter.resetToHome();
    _currentIndex = TabRouter.tabIndex.value;
    _loadedScreens = List<Widget?>.filled(_screenCount, null, growable: false);
    _ensureScreenLoaded(_currentIndex);
    TabRouter.tabIndex.addListener(_handleExternalTabChange);
    unawaited(SignalCaptureService.instance.start());
  }

  @override
  void dispose() {
    TabRouter.tabIndex.removeListener(_handleExternalTabChange);
    unawaited(SignalCaptureService.instance.stop());
    super.dispose();
  }

  void _handleExternalTabChange() {
    if (!mounted) return;
    final nextIndex = TabRouter.tabIndex.value;
    if (nextIndex == _currentIndex) return;
    if (nextIndex < 0 || nextIndex >= _screenCount) return;
    setState(() {
      _ensureScreenLoaded(nextIndex);
      _currentIndex = nextIndex;
    });
  }

  static const int _screenCount = 5;

  void _ensureScreenLoaded(int index) {
    if (_loadedScreens[index] != null) return;
    _loadedScreens[index] = _buildScreen(index);
  }

  Widget _buildScreen(int index) {
    switch (index) {
      case _homeTabIndex:
        return const HomeScreen();
      case _claimsTabIndex:
        return const ClaimsScreen();
      case _coverageTabIndex:
        return const CoverageScreen();
      case _payoutsTabIndex:
        return const PayoutsScreen();
      case _profileTabIndex:
      default:
        return const ProfileScreen();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(
        index: _currentIndex,
        children: List<Widget>.generate(
          _screenCount,
          (index) => _loadedScreens[index] ?? const SizedBox.shrink(),
          growable: false,
        ),
      ),
      bottomNavigationBar: Container(
        decoration: BoxDecoration(
          color: AppColors.background,
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.06),
              blurRadius: 20,
              offset: const Offset(0, -4),
            ),
          ],
        ),
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                _buildNavItem(
                  index: 0,
                  icon: Icons.home_outlined,
                  activeIcon: Icons.home_rounded,
                  label: 'HOME',
                ),
                _buildNavItem(
                  index: 1,
                  icon: Icons.description_outlined,
                  activeIcon: Icons.description_rounded,
                  label: 'CLAIMS',
                ),
                _buildNavItem(
                  index: 2,
                  icon: Icons.verified_user_outlined,
                  activeIcon: Icons.verified_user_rounded,
                  label: 'COVERAGE',
                ),
                _buildNavItem(
                  index: 3,
                  icon: Icons.payments_outlined,
                  activeIcon: Icons.payments_rounded,
                  label: 'PAYOUTS',
                ),
                _buildNavItem(
                  index: 4,
                  icon: Icons.account_circle_outlined,
                  activeIcon: Icons.account_circle,
                  label: 'PROFILE',
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildNavItem({
    required int index,
    required IconData icon,
    required IconData activeIcon,
    required String label,
  }) {
    final isActive = _currentIndex == index;

    return GestureDetector(
      onTap: () {
        setState(() {
          _ensureScreenLoaded(index);
          _currentIndex = index;
          TabRouter.switchTo(index);
        });
      },
      behavior: HitTestBehavior.opaque,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              isActive ? activeIcon : icon,
              color: isActive ? AppColors.primary : AppColors.navInactive,
              size: 28,
            ),
            const SizedBox(height: 2),
            Text(
              label,
              style: TextStyle(
                fontSize: 9,
                fontWeight: FontWeight.w700,
                color: isActive ? AppColors.primary : AppColors.navInactive,
                letterSpacing: 0.6,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
