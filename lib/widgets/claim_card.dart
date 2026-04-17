import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../../theme/app_colors.dart';
import '../../models/claim_model.dart';

class ClaimCard extends StatelessWidget {
  final Claim claim;
  final VoidCallback? onTap;

  const ClaimCard({super.key, required this.claim, this.onTap});

  @override
  Widget build(BuildContext context) {
    final dateFormat = DateFormat('dd MMM');
    final accent = claim.statusColor;

    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: AppColors.nightSurface,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: accent.withValues(alpha: 0.18), width: 1),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Claim type icon
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: claim.typeColor.withValues(alpha: 0.16),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(claim.typeIcon, color: claim.typeColor, size: 20),
                ),
                const SizedBox(width: 12),
                // Claim info
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        claim.description,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                          color: Colors.white,
                          height: 1.25,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        'CLAIM ${claim.id} · ${dateFormat.format(claim.date).toUpperCase()}',
                        style: const TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w500,
                          color: Colors.white70,
                          letterSpacing: 0.5,
                        ),
                      ),
                    ],
                  ),
                ),
                // Amount
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(
                      '₹${NumberFormat('#,##0').format(claim.amount)}',
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                        color: Colors.white,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 3,
                      ),
                      decoration: BoxDecoration(
                        color: accent.withValues(alpha: 0.16),
                        borderRadius: BorderRadius.circular(999),
                        border: Border.all(
                          color: accent.withValues(alpha: 0.22),
                        ),
                      ),
                      child: Text(
                        claim.statusLabel.toUpperCase(),
                        style: TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.w700,
                          color: accent,
                          letterSpacing: 0.5,
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
            if (claim.bankInfo case final bankInfo?) ...[
              const SizedBox(height: 12),
              Row(
                children: [
                  const Icon(
                    Icons.calendar_today,
                    size: 12,
                    color: Colors.white54,
                  ),
                  const SizedBox(width: 4),
                  Text(
                    dateFormat.format(claim.date),
                    style: const TextStyle(fontSize: 12, color: Colors.white70),
                  ),
                  const SizedBox(width: 16),
                  const Icon(
                    Icons.account_balance,
                    size: 12,
                    color: Colors.white54,
                  ),
                  const SizedBox(width: 4),
                  Text(
                    bankInfo,
                    style: const TextStyle(fontSize: 12, color: Colors.white70),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}
