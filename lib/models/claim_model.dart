import 'package:flutter/material.dart';

enum ClaimStatus { pending, inReview, escalated, settled, rejected }

enum ClaimType { rainLock, aqiGuard, trafficBlock, zoneLock, heatBlock }

class Claim {
  final String id;
  final ClaimType type;
  final ClaimStatus status;
  final double amount;
  final DateTime date;
  final String description;
  final String? bankInfo;

  const Claim({
    required this.id,
    required this.type,
    required this.status,
    required this.amount,
    required this.date,
    required this.description,
    this.bankInfo,
  });

  String get typeName {
    switch (type) {
      case ClaimType.rainLock:
        return 'Weather Damage (Rain)';
      case ClaimType.aqiGuard:
        return 'Air Quality Alert';
      case ClaimType.trafficBlock:
        return 'Traffic Congestion';
      case ClaimType.zoneLock:
        return 'Zone Lockdown';
      case ClaimType.heatBlock:
        return 'Extreme Heat';
    }
  }

  String get typeShortName {
    switch (type) {
      case ClaimType.rainLock:
        return 'RainLock';
      case ClaimType.aqiGuard:
        return 'AQI Guard';
      case ClaimType.trafficBlock:
        return 'TrafficBlock';
      case ClaimType.zoneLock:
        return 'ZoneLock';
      case ClaimType.heatBlock:
        return 'HeatBlock';
    }
  }

  IconData get typeIcon {
    switch (type) {
      case ClaimType.rainLock:
        return Icons.water_drop;
      case ClaimType.aqiGuard:
        return Icons.air;
      case ClaimType.trafficBlock:
        return Icons.traffic;
      case ClaimType.zoneLock:
        return Icons.lock;
      case ClaimType.heatBlock:
        return Icons.thermostat;
    }
  }

  Color get typeColor {
    switch (type) {
      case ClaimType.rainLock:
        return const Color(0xFF3B82F6);
      case ClaimType.aqiGuard:
        return const Color(0xFF8B5CF6);
      case ClaimType.trafficBlock:
        return const Color(0xFFF59E0B);
      case ClaimType.zoneLock:
        return const Color(0xFFEF4444);
      case ClaimType.heatBlock:
        return const Color(0xFFEF4444);
    }
  }

  String get statusLabel {
    switch (status) {
      case ClaimStatus.pending:
        return 'Pending';
      case ClaimStatus.inReview:
        return 'In Review';
      case ClaimStatus.escalated:
        return 'Escalated';
      case ClaimStatus.settled:
        return 'Settled';
      case ClaimStatus.rejected:
        return 'Rejected';
    }
  }

  Color get statusColor {
    switch (status) {
      case ClaimStatus.pending:
        return const Color(0xFFF59E0B);
      case ClaimStatus.inReview:
        return const Color(0xFF3B82F6);
      case ClaimStatus.escalated:
        return const Color(0xFF7C3AED);
      case ClaimStatus.settled:
        return const Color(0xFF13B8AA);
      case ClaimStatus.rejected:
        return const Color(0xFFEF4444);
    }
  }
}
