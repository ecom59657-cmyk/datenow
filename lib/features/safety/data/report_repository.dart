import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart' as sb;

import '../../../core/services/supabase_service.dart';
import '../../../core/utils/logger.dart';
import '../domain/report_reason.dart';

/// File a single report. Returns when the row is persisted (or for the
/// mock, when the in-memory append completes). Throws on auth / RLS
/// failure so the caller can surface a snackbar.
abstract class ReportRepository {
  Future<void> submit({
    required String reporterUserId,
    required String reportedUserId,
    required ReportReason reason,
    String? details,
  });

  /// Atomic block helper backed by the `block_user(p_user_id)` RPC.
  /// Also force-ends any live call between the two so the blocker isn't
  /// stuck on the line with the blocked peer.
  Future<void> blockUser({required String reportedUserId});
}

class SupabaseReportRepository implements ReportRepository {
  SupabaseReportRepository(this._client);

  final sb.SupabaseClient _client;
  static const _log = AppLogger('Report');

  @override
  Future<void> submit({
    required String reporterUserId,
    required String reportedUserId,
    required ReportReason reason,
    String? details,
  }) async {
    _log.info(
      'submit report — reporter=$reporterUserId target=$reportedUserId '
      'reason=${reason.wire}',
    );
    final trimmedDetails =
        (details == null || details.trim().isEmpty) ? null : details.trim();
    await _client.from('reports').insert({
      'reporter_id': reporterUserId,
      'reported_user_id': reportedUserId,
      'reason': reason.wire,
      if (trimmedDetails != null) 'details': trimmedDetails,
    });
  }

  @override
  Future<void> blockUser({required String reportedUserId}) async {
    _log.info('block user — target=$reportedUserId');
    await _client.rpc<dynamic>(
      'block_user',
      params: {'p_user_id': reportedUserId},
    );
  }
}

/// In-memory mock so the report sheet is exercisable when Supabase isn't
/// configured (dev mode, widget tests).
class MockReportRepository implements ReportRepository {
  static const _log = AppLogger('MockReport');

  final List<Map<String, Object?>> submitted = [];
  final Set<String> blocked = <String>{};

  @override
  Future<void> submit({
    required String reporterUserId,
    required String reportedUserId,
    required ReportReason reason,
    String? details,
  }) async {
    _log.info(
      'mock submit — reporter=$reporterUserId target=$reportedUserId '
      'reason=${reason.wire}',
    );
    submitted.add({
      'reporter_id': reporterUserId,
      'reported_user_id': reportedUserId,
      'reason': reason.wire,
      'details': details,
    });
  }

  @override
  Future<void> blockUser({required String reportedUserId}) async {
    _log.info('mock block — target=$reportedUserId');
    blocked.add(reportedUserId);
  }
}

final reportRepositoryProvider = Provider<ReportRepository>((ref) {
  if (ref.watch(supabaseAvailableProvider)) {
    return SupabaseReportRepository(ref.watch(supabaseClientProvider));
  }
  return MockReportRepository();
});
