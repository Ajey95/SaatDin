import 'dart:async';
import 'dart:math' as math;

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/widgets.dart';
import 'package:geolocator/geolocator.dart';
import 'package:sensors_plus/sensors_plus.dart';

import 'api_service.dart';
import 'mobile_signal_bridge.dart';

class SignalCaptureService with WidgetsBindingObserver {
  SignalCaptureService._();

  static final SignalCaptureService instance = SignalCaptureService._();

  final ApiService _apiService = ApiService();
  final Connectivity _connectivity = Connectivity();
  final List<_MotionSample> _samples = <_MotionSample>[];

  Timer? _timer;
  StreamSubscription<AccelerometerEvent>? _accelerometerSubscription;
  Position? _lastPosition;
  DateTime? _lastUploadAt;
  bool _started = false;
  bool _uploadInProgress = false;

  Future<void> start() async {
    if (_started) return;
    _started = true;
    WidgetsBinding.instance.addObserver(this);
    _accelerometerSubscription ??= accelerometerEventStream().listen((event) {
      final magnitude = math.sqrt(
        (event.x * event.x) + (event.y * event.y) + (event.z * event.z),
      );
      _samples.add(_MotionSample(timestamp: DateTime.now(), magnitude: magnitude));
      final cutoff = DateTime.now().subtract(const Duration(minutes: 10));
      _samples.removeWhere((sample) => sample.timestamp.isBefore(cutoff));
    });
    await _captureAndUpload();
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(minutes: 10), (_) {
      unawaited(_captureAndUpload());
    });
  }

  Future<void> stop() async {
    WidgetsBinding.instance.removeObserver(this);
    _timer?.cancel();
    _timer = null;
    await _accelerometerSubscription?.cancel();
    _accelerometerSubscription = null;
    _started = false;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!_started) return;
    if (state == AppLifecycleState.resumed) {
      _timer?.cancel();
      _timer = Timer.periodic(const Duration(minutes: 10), (_) {
        unawaited(_captureAndUpload());
      });
      unawaited(_captureAndUpload());
    } else if (state == AppLifecycleState.paused || state == AppLifecycleState.inactive) {
      _timer?.cancel();
      _timer = null;
    }
  }

  Future<void> _captureAndUpload() async {
    if (_uploadInProgress || !_apiService.isAuthenticated) return;
    _uploadInProgress = true;
    try {
      final permission = await _ensurePermissions();
      if (!permission) return;

      final position = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(accuracy: LocationAccuracy.medium),
      );
      final rawTowerMetadata = await MobileSignalBridge.instance.getTowerMetadata();
      final connectivityResult = await _connectivity.checkConnectivity();
      final motionMetadata = _buildMotionMetadata(position);
      final enrichedTower = _buildTowerMetadata(
        rawTowerMetadata,
        _networkTypes(connectivityResult),
      );

      await _apiService.uploadLocationSignal(
        latitude: position.latitude,
        longitude: position.longitude,
        accuracyMeters: position.accuracy,
        capturedAt: position.timestamp,
        towerMetadata: enrichedTower,
        motionMetadata: motionMetadata,
      );
      _lastPosition = position;
      _lastUploadAt = DateTime.now();
    } catch (_) {
      // Keep the app resilient; signal capture is best-effort.
    } finally {
      _uploadInProgress = false;
    }
  }

  Future<bool> _ensurePermissions() async {
    var serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) {
      serviceEnabled = await Geolocator.openLocationSettings();
      if (!serviceEnabled) return false;
    }

    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }
    return permission == LocationPermission.whileInUse || permission == LocationPermission.always;
  }

  Map<String, dynamic> _buildMotionMetadata(Position position) {
    final now = DateTime.now();
    final cutoff = now.subtract(const Duration(minutes: 2));
    final recentSamples = _samples.where((sample) => sample.timestamp.isAfter(cutoff)).toList();
    final sampleCount = recentSamples.isEmpty ? 1 : recentSamples.length;
    final movingSamples = recentSamples.where((sample) => sample.magnitude > 11.4).length;
    final stationarySamples = sampleCount - movingSamples;
    final elapsedSinceLastUpload = _lastUploadAt == null
        ? 120.0
        : now.difference(_lastUploadAt!).inSeconds.clamp(1, 600).toDouble();
    final distanceMeters = _lastPosition == null
        ? 0.0
        : Geolocator.distanceBetween(
            _lastPosition!.latitude,
            _lastPosition!.longitude,
            position.latitude,
            position.longitude,
          );
    final avgSpeed = distanceMeters / elapsedSinceLastUpload;
    final maxSpeed = position.speed > avgSpeed ? position.speed : avgSpeed;

    return {
      'windowSeconds': elapsedSinceLastUpload.round(),
      'sampleCount': sampleCount,
      'movingSeconds': movingSamples.toDouble(),
      'stationarySeconds': stationarySamples.toDouble(),
      'distanceMeters': distanceMeters,
      'avgSpeedMps': avgSpeed,
      'maxSpeedMps': maxSpeed,
      'headingChangeRate': 0.0,
    };
  }

  List<String> _networkTypes(Object connectivity) {
    if (connectivity is Iterable) {
      return connectivity
          .whereType<ConnectivityResult>()
          .map((item) => item.name)
          .toList();
    }
    if (connectivity is ConnectivityResult) {
      return <String>[connectivity.name];
    }
    return const <String>[];
  }

  Map<String, dynamic>? _buildTowerMetadata(
    Map<String, dynamic>? raw,
    List<String> networkTypes,
  ) {
    final metadata = <String, dynamic>{
      if (raw?['transport'] != null) 'transport': raw!['transport'],
      if (raw?['carrier'] != null) 'carrier': raw!['carrier'],
      if (raw?['networkOperator'] != null) 'networkOperator': raw!['networkOperator'],
      if (raw?['simOperator'] != null) 'simOperator': raw!['simOperator'],
      if (raw?['capturedAtMs'] != null) 'capturedAtMs': raw!['capturedAtMs'],
      if (networkTypes.isNotEmpty) 'networkTypes': networkTypes,
    };

    final rawCells = raw?['cells'];
    if (rawCells is List) {
      final cells = rawCells
          .whereType<Map>()
          .map((cell) => Map<String, dynamic>.from(cell))
          .map(_normalizeCell)
          .whereType<Map<String, dynamic>>()
          .toList();
      if (cells.isNotEmpty) {
        metadata['servingCell'] = cells.first;
        if (cells.length > 1) {
          metadata['neighborCells'] = cells.skip(1).toList();
        }
      }
    }

    return metadata.isEmpty ? null : metadata;
  }

  Map<String, dynamic>? _normalizeCell(Map<String, dynamic> rawCell) {
    final cellId = _firstNonEmptyString(<Object?>[
      rawCell['nci'],
      rawCell['ci'],
      rawCell['cid'],
      rawCell['basestationId'],
    ]);
    if (cellId == null) return null;

    final normalized = <String, dynamic>{'cellId': cellId};

    final radioType = _firstNonEmptyString(<Object?>[rawCell['technology']]);
    final mcc = _firstNonEmptyString(<Object?>[rawCell['mcc']]);
    final mnc = _firstNonEmptyString(<Object?>[rawCell['mnc']]);
    final tac = _firstNonEmptyString(<Object?>[
      rawCell['tac'],
      rawCell['lac'],
      rawCell['systemId'],
    ]);

    if (radioType != null) normalized['radioType'] = radioType;
    if (mcc != null) normalized['mcc'] = mcc;
    if (mnc != null) normalized['mnc'] = mnc;
    if (tac != null) normalized['tac'] = tac;
    if (rawCell['dbm'] is num) normalized['signalDbm'] = rawCell['dbm'];
    if (rawCell['signalLevel'] is num) normalized['signalLevel'] = rawCell['signalLevel'];

    return normalized;
  }

  String? _firstNonEmptyString(List<Object?> values) {
    for (final value in values) {
      if (value == null) continue;
      final text = value.toString().trim();
      if (text.isNotEmpty) return text;
    }
    return null;
  }
}

class _MotionSample {
  const _MotionSample({required this.timestamp, required this.magnitude});

  final DateTime timestamp;
  final double magnitude;
}
