import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import '../../routes/app_routes.dart';

class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({super.key});

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  int _currentPage = 0;

  static const List<_OnboardingSlide> _slides = [
    _OnboardingSlide(
      titleLine1: 'Get Paid',
      titleLine2: 'Instantly',
      titleLine3: 'Automatically',
      description:
          'When floods or traffic block your zone, SaatDin detects it and sends money straight to your UPI - no forms, no calls.',
      imagePath: 'assets/images/onboarding-screens/onboarding_screen.png',
      feature1: 'Real-time weather & traffic detection',
      feature2: 'Direct credit to your UPI account',
      feature3: 'Zero paperwork, ever',
    ),
    _OnboardingSlide(
      titleLine1: 'Only Your',
      titleLine2: 'Area',
      titleLine3: 'Matters',
      description:
          'Fair payouts. No confusion. We track disruptions based on your exact work area. If your zone is affected, you get paid. If it\'s not, it doesn\'t trigger — simple and fair.',
      imagePath: 'assets/images/onboarding-screens/onboarding_screen2.png',
      feature1: 'Track disruptions by location',
      feature2: 'Fair zone-based payouts',
      feature3: 'No false triggers',
    ),
    _OnboardingSlide(
      titleLine1: 'Small Weekly',
      titleLine2: 'Cost',
      titleLine3: 'Solid Backup',
      description:
          'Starts from ₹29/week, auto-debited from UPI. If your work stops due to real disruptions, you still get money for that day — no chasing, no stress.',
      imagePath: 'assets/images/onboarding-screens/onboarding_screen3.png',
      feature1: 'Starting at just ₹29/week from UPI',
      feature2: 'Automatic disbursement',
      feature3: 'Zero stress payouts',
    ),
  ];

  void _finishOnboarding(BuildContext context) {
    Navigator.pushReplacementNamed(context, AppRoutes.bootstrap);
  }

  void _onNextPressed(BuildContext context) {
    if (_currentPage < _slides.length - 1) {
      setState(() {
        _currentPage += 1;
      });
      return;
    }
    _finishOnboarding(context);
  }

  void _onPrevPressed() {
    if (_currentPage > 0) {
      setState(() {
        _currentPage -= 1;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final slide = _slides[_currentPage];

    return Scaffold(
      backgroundColor: Colors.white,
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final h = constraints.maxHeight;
            final w = constraints.maxWidth;
            final heightScale = h / 860;
            final widthScale = w / 390;
            final scale = (heightScale < widthScale ? heightScale : widthScale)
                .clamp(0.72, 1.0);
            final headingScale = (w / 360).clamp(0.74, 1.0);

            return SingleChildScrollView(
              child: ConstrainedBox(
                constraints: BoxConstraints(minHeight: constraints.maxHeight),
                child: IntrinsicHeight(
                  child: Padding(
                    padding: EdgeInsets.fromLTRB(22, 28 * scale, 22, 22 * scale),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                  // Top header with page dots and skip button
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      // Page dots
                      Row(
                        children: [
                          for (int i = 0; i < _slides.length; i++) ...[
                            Container(
                              width: (_currentPage == i ? 20 : 6) * scale,
                              height: 5 * scale,
                              decoration: BoxDecoration(
                                color: _currentPage == i
                                    ? const Color(0xFF14B890)
                                    : const Color(0xFFD0D5DD),
                                borderRadius: BorderRadius.circular(3),
                              ),
                            ),
                            if (i != _slides.length - 1)
                              SizedBox(width: 6 * scale),
                          ],
                        ],
                      ),
                      if (_currentPage < _slides.length - 1)
                        GestureDetector(
                          onTap: () => _finishOnboarding(context),
                          child: Container(
                            padding: EdgeInsets.symmetric(
                              horizontal: 14 * scale,
                              vertical: 7 * scale,
                            ),
                            decoration: BoxDecoration(
                              color: Colors.white,
                              borderRadius: BorderRadius.circular(12 * scale),
                              border:
                                  Border.all(color: const Color(0xFFE9ECEF)),
                            ),
                            child: Text(
                              'Skip',
                              style: GoogleFonts.inter(
                                fontSize: 13 * scale,
                                fontWeight: FontWeight.w700,
                                color: const Color(0xFF4F5660),
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),

                  SizedBox(height: 50 * scale),

                  // Heading
                  Align(
                    alignment: Alignment.center,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        SizedBox(
                          width: double.infinity,
                          child: FittedBox(
                            fit: BoxFit.scaleDown,
                            child: Text(
                              slide.titleLine1,
                              textAlign: TextAlign.center,
                              style: GoogleFonts.inter(
                                fontSize: 42 * headingScale,
                                fontWeight: FontWeight.w500,
                                height: 1.0,
                                letterSpacing: -1.2,
                                color: const Color(0xFF171717),
                              ),
                            ),
                          ),
                        ),
                        SizedBox(
                          width: double.infinity,
                          child: FittedBox(
                            fit: BoxFit.scaleDown,
                            child: Text(
                              slide.titleLine2,
                              textAlign: TextAlign.center,
                              style: GoogleFonts.pacifico(
                                fontSize: 52 * headingScale,
                                fontWeight: FontWeight.w400,
                                height: 1.05,
                                color: const Color(0xFF14B890),
                              ),
                            ),
                          ),
                        ),
                        SizedBox(height: 10 * scale),
                        SizedBox(
                          width: double.infinity,
                          child: FittedBox(
                            fit: BoxFit.scaleDown,
                            child: Text(
                              slide.titleLine3,
                              textAlign: TextAlign.center,
                              style: GoogleFonts.inter(
                                fontSize: 42 * headingScale,
                                fontWeight: FontWeight.w500,
                                height: 1.0,
                                letterSpacing: -1.2,
                                color: const Color(0xFF171717),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),

                  SizedBox(height: 16 * scale),

                  // Illustration area
                  Container(
                    width: double.infinity,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(20 * scale),
                    ),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(18 * scale),
                      child: SizedBox(
                        height: 300 * scale,
                        width: double.infinity,
                        child: Image.asset(
                          slide.imagePath,
                          fit: BoxFit.cover,
                          errorBuilder: (context, error, stackTrace) {
                            return Container(
                              alignment: Alignment.center,
                              color: Colors.white,
                              child: Text(
                                'Image not found',
                                style: GoogleFonts.inter(
                                  fontSize: 14 * scale,
                                  color: const Color(0xFF5C6169),
                                ),
                              ),
                            );
                          },
                        ),
                      ),
                    ),
                  ),

                  SizedBox(height: 16 * scale),

                  // Description
                  Text(
                    slide.description,
                    style: GoogleFonts.inter(
                      fontSize: 13 * scale,
                      fontWeight: FontWeight.w400,
                      height: 1.55,
                      color: const Color(0xFF5C6169),
                    ),
                  ),

                  SizedBox(height: 20 * scale),

                  // Feature rows
                  _FeatureRow(
                    icon: Icons.access_time_rounded,
                    label: slide.feature1,
                    scale: scale,
                  ),
                  SizedBox(height: 13 * scale),
                  _FeatureRow(
                    icon: Icons.credit_card_rounded,
                    label: slide.feature2,
                    scale: scale,
                  ),
                  SizedBox(height: 13 * scale),
                  _FeatureRow(
                    icon: Icons.star_border_rounded,
                    label: slide.feature3,
                    scale: scale,
                  ),

                  const Spacer(),

                  if (_currentPage == _slides.length - 1)
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        GestureDetector(
                          onTap: () => _finishOnboarding(context),
                          child: Container(
                            width: double.infinity,
                            constraints: BoxConstraints(maxWidth: 320 * scale),
                            padding: EdgeInsets.symmetric(
                              vertical: 16 * scale,
                            ),
                            decoration: BoxDecoration(
                              color: const Color(0xFF14B890),
                              borderRadius: BorderRadius.circular(18 * scale),
                              boxShadow: [
                                BoxShadow(
                                  color: const Color(0xFF14B890)
                                      .withOpacity(0.28),
                                  blurRadius: 18 * scale,
                                  offset: Offset(0, 8 * scale),
                                ),
                              ],
                            ),
                            alignment: Alignment.center,
                            child: Text(
                              'Get Started',
                              style: GoogleFonts.inter(
                                fontSize: 16 * scale,
                                fontWeight: FontWeight.w700,
                                color: Colors.white,
                              ),
                            ),
                          ),
                        ),
                      ],
                    )
                  else
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        // Left arrow button
                        GestureDetector(
                          onTap: _onPrevPressed,
                          child: Container(
                            width: 54 * scale,
                            height: 54 * scale,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: _currentPage > 0
                                  ? const Color(0xFF14B890)
                                  : const Color(0xFFD0D5DD),
                              boxShadow: _currentPage > 0
                                  ? [
                                      BoxShadow(
                                        color: const Color(0xFF14B890)
                                            .withOpacity(0.35),
                                        blurRadius: 18 * scale,
                                        offset: Offset(0, 6 * scale),
                                      ),
                                    ]
                                  : [],
                            ),
                            child: const Icon(
                              Icons.chevron_left_rounded,
                              color: Colors.white,
                              size: 22,
                            ),
                          ),
                        ),
                        // Right arrow button
                        GestureDetector(
                          onTap: () => _onNextPressed(context),
                          child: Container(
                            width: 54 * scale,
                            height: 54 * scale,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: const Color(0xFF14B890),
                              boxShadow: [
                                BoxShadow(
                                  color: const Color(0xFF14B890)
                                      .withOpacity(0.35),
                                  blurRadius: 18 * scale,
                                  offset: Offset(0, 6 * scale),
                                ),
                              ],
                            ),
                            child: const Icon(
                              Icons.chevron_right_rounded,
                              color: Colors.white,
                              size: 22,
                            ),
                          ),
                        ),
                      ],
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

class _OnboardingSlide {
  final String titleLine1;
  final String titleLine2;
  final String titleLine3;
  final String description;
  final String imagePath;
  final String feature1;
  final String feature2;
  final String feature3;

  const _OnboardingSlide({
    required this.titleLine1,
    required this.titleLine2,
    required this.titleLine3,
    required this.description,
    required this.imagePath,
    required this.feature1,
    required this.feature2,
    required this.feature3,
  });
}

class _FeatureRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final double scale;

  const _FeatureRow({
    required this.icon,
    required this.label,
    required this.scale,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Container(
          width: 32 * scale,
          height: 32 * scale,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(color: const Color(0xFF14B890), width: 1.5),
          ),
          child: Icon(icon, color: const Color(0xFF14B890), size: 16 * scale),
        ),
        SizedBox(width: 12 * scale),
        Expanded(
          child: Text(
            label,
            style: GoogleFonts.inter(
              fontSize: 13 * scale,
              fontWeight: FontWeight.w700,
              color: const Color(0xFF171717),
            ),
          ),
        ),
      ],
    );
  }
}