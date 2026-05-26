// =============================================================================
// DateNow — LocationService (Phase 1.1 of the matching refactor)
//
// Single entry point for everything geolocation-related on the client.
// Wraps the geolocator package + the Supabase `update_my_location` RPC
// behind a small Singleton API that's safe to call from anywhere:
//
//   * currentPermissionStatus()       — read-only snapshot, no prompt
//   * requestPermission()             — fires the iOS / Android prompt
//   * captureAndPush({force = false}) — fetches position + pushes to DB
//   * refreshIfStale({maxAge})        — captureAndPush only if the last
//                                        push is older than [maxAge]
//
// The service does NOT track the user in the background. Every fetch is
// a one-shot foreground call. All operations are best-effort and never
// throw out — the caller gets a [LocationResult] that says exactly what
// happened.
//
// Logging is deliberately verbose: every step prints to the AppLogger
// "Location" channel so the next time a test fails ("I granted location
// but the DB has no row") it's diagnosable from the device console.
// =============================================================================

import 'package:geolocator/geolocator.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../utils/logger.dart';

/// Outcome of a [LocationService] operation. Carries enough detail
/// for the caller to surface a precise UX message without forcing the
/// service to throw.
sealed class LocationResult {
  const LocationResult();
}

/// The user's coordinates were successfully captured AND pushed to the
/// `profiles.location` column via the `update_my_location` RPC.
class LocationCaptured extends LocationResult {
  const LocationCaptured({
    required this.latitude,
    required this.longitude,
    required this.accuracyMeters,
    required this.updatedAt,
  });

  final double latitude;
  final double longitude;
  final double accuracyMeters;
  final DateTime updatedAt;

  @override
  String toString() =>
      'LocationCaptured(lat=$latitude, lng=$longitude, '
      'accuracy=${accuracyMeters.toStringAsFixed(0)}m, '
      'updatedAt=$updatedAt)';
}

/// The user denied (or never granted) permission. The caller should
/// show a "Pourquoi on a besoin de ta localisation" sheet.
class LocationDenied extends LocationResult {
  const LocationDenied({required this.permissionStatus});

  final LocationPermission permissionStatus;

  bool get permanently =>
      permissionStatus == LocationPermission.deniedForever;
}

/// The device-level location services are disabled (airplane mode,
/// Settings → Location → Off). The user can't grant permission from
/// inside the app — they have to go to Settings.
class LocationServicesOff extends LocationResult {
  const LocationServicesOff();
}

/// Some other failure (timeout, RPC error, no auth, …). Carries a
/// human-readable reason for logging / debug UI.
class LocationFailed extends LocationResult {
  const LocationFailed(this.reason);
  final String reason;
}

class LocationService {
  LocationService._();

  static final LocationService instance = LocationService._();

  static const _log = AppLogger('Location');

  /// Read-only snapshot of the current permission. Never triggers a
  /// system prompt.
  Future<LocationPermission> currentPermissionStatus() async {
    try {
      final p = await Geolocator.checkPermission();
      _log.info('currentPermissionStatus = ${p.name}');
      return p;
    } catch (e) {
      _log.warn('checkPermission failed: $e');
      return LocationPermission.denied;
    }
  }

  /// Fires the iOS / Android permission prompt if it hasn't been
  /// surfaced yet. Returns the resolved status.
  ///
  /// iOS shows the system dialog only once per app install — on a
  /// subsequent call when the user denied, we get `deniedForever` and
  /// the caller has to direct them to Settings.
  Future<LocationPermission> requestPermission() async {
    final current = await currentPermissionStatus();
    if (current == LocationPermission.always ||
        current == LocationPermission.whileInUse) {
      _log.info('requestPermission: already granted (${current.name})');
      return current;
    }
    if (current == LocationPermission.deniedForever) {
      _log.warn(
        'requestPermission: deniedForever — cannot re-prompt, user '
        'must open Settings → Privacy → Location → DateNow',
      );
      return current;
    }
    try {
      final result = await Geolocator.requestPermission();
      _log.info('requestPermission → ${result.name}');
      return result;
    } catch (e) {
      _log.warn('requestPermission failed: $e');
      return LocationPermission.denied;
    }
  }

  /// Captures a one-shot position from the device and pushes it to the
  /// `profiles` row via the `update_my_location` RPC. Returns a typed
  /// [LocationResult] — the caller decides what UX to surface.
  ///
  /// [force]: when false (default), no-op if the current permission
  /// status is denied / unavailable. When true, attempts the permission
  /// request first.
  Future<LocationResult> captureAndPush({bool force = true}) async {
    _log.info('captureAndPush(force=$force) — starting');

    // 1) Device-level location services must be on.
    final servicesOn = await Geolocator.isLocationServiceEnabled();
    if (!servicesOn) {
      _log.warn('Device location services are OFF — aborting');
      return const LocationServicesOff();
    }

    // 2) App-level permission.
    var perm = await currentPermissionStatus();
    if (perm == LocationPermission.denied && force) {
      perm = await requestPermission();
    }
    if (perm != LocationPermission.always &&
        perm != LocationPermission.whileInUse) {
      _log.warn('captureAndPush: permission $perm — aborting');
      return LocationDenied(permissionStatus: perm);
    }

    // 3) Read the position with a sensible timeout. Reduced accuracy
    // is enough for matching — we don't need GPS-grade precision and
    // it's faster + drains less battery.
    Position pos;
    try {
      pos = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.medium,
          timeLimit: Duration(seconds: 12),
        ),
      );
    } catch (e) {
      _log.warn('getCurrentPosition failed: $e');
      return LocationFailed('getCurrentPosition failed: $e');
    }
    _log.info(
      'position read — lat=${pos.latitude.toStringAsFixed(5)} '
      'lng=${pos.longitude.toStringAsFixed(5)} '
      'accuracy=${pos.accuracy.toStringAsFixed(0)}m',
    );

    // 4) Push to Supabase via the RPC. The RPC re-validates the inputs
    // server-side (range checks, auth.uid()) and writes
    // `location_updated_at = now()` so the client doesn't need to know
    // the server time.
    final client = Supabase.instance.client;
    if (client.auth.currentUser == null) {
      _log.warn('captureAndPush: no signed-in user — coords not pushed');
      return const LocationFailed('not signed in');
    }
    try {
      final response = await client.rpc(
        'update_my_location',
        params: {
          'p_lat': pos.latitude,
          'p_lng': pos.longitude,
          'p_accuracy_m': pos.accuracy.round(),
        },
      );
      // The RPC returns the updated profile row. We don't need it
      // beyond confirmation that it landed.
      DateTime? updatedAt;
      if (response is Map &&
          response['location_updated_at'] is String) {
        updatedAt = DateTime.tryParse(
          response['location_updated_at'] as String,
        );
      } else if (response is List && response.isNotEmpty) {
        final first = response.first;
        if (first is Map && first['location_updated_at'] is String) {
          updatedAt = DateTime.tryParse(
            first['location_updated_at'] as String,
          );
        }
      }
      _log.info(
        'update_my_location OK — '
        'response keys=${response is Map ? (response).keys.toList() : 'list/other'}',
      );
      return LocationCaptured(
        latitude: pos.latitude,
        longitude: pos.longitude,
        accuracyMeters: pos.accuracy,
        updatedAt: updatedAt ?? DateTime.now().toUtc(),
      );
    } on PostgrestException catch (e) {
      _log.warn(
        'update_my_location RPC error: code=${e.code} '
        'message=${e.message} details=${e.details}',
      );
      return LocationFailed(
        'rpc error: ${e.code ?? "?"} ${e.message}',
      );
    } catch (e) {
      _log.warn('update_my_location threw: $e');
      return LocationFailed('rpc threw: $e');
    }
  }

  /// Captures + pushes a fresh location only if the last successful
  /// push is older than [maxAge]. Reads `profiles.location_updated_at`
  /// once to decide. Cheap when fresh, free when no signed-in user.
  Future<LocationResult?> refreshIfStale({
    Duration maxAge = const Duration(hours: 24),
  }) async {
    final client = Supabase.instance.client;
    final userId = client.auth.currentUser?.id;
    if (userId == null) {
      _log.info('refreshIfStale: no signed-in user — skip');
      return null;
    }
    try {
      final row = await client
          .from('profiles')
          .select('location_updated_at')
          .eq('id', userId)
          .maybeSingle();
      final raw = row?['location_updated_at'] as String?;
      final lastUpdate = raw == null ? null : DateTime.tryParse(raw);
      if (lastUpdate != null &&
          DateTime.now().toUtc().difference(lastUpdate) < maxAge) {
        _log.info(
          'refreshIfStale: last update ${DateTime.now().toUtc().difference(lastUpdate).inMinutes}min ago — skip',
        );
        return null;
      }
      _log.info(
        'refreshIfStale: stale (last=$lastUpdate, maxAge=$maxAge) — refreshing',
      );
      return await captureAndPush();
    } catch (e) {
      _log.warn('refreshIfStale failed: $e');
      return null;
    }
  }
}
