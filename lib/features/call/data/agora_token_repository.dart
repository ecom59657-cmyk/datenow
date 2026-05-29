import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/debug/debug_observer.dart';
import '../../../core/services/supabase_service.dart';
import '../../../core/utils/logger.dart';

/// A signed Agora RTC token plus the parameters it was minted for.
class AgoraToken {
  const AgoraToken({
    required this.token,
    required this.appId,
    required this.channelName,
    required this.uid,
    required this.expiresAt,
  });

  final String token;
  final String appId;
  final String channelName;
  final int uid;
  final DateTime expiresAt;

  factory AgoraToken.fromJson(Map<String, dynamic> json) {
    return AgoraToken(
      token: json['token'] as String,
      appId: json['appId'] as String,
      channelName: json['channelName'] as String,
      uid: json['uid'] as int,
      expiresAt: DateTime.fromMillisecondsSinceEpoch(
        (json['expiresAt'] as int) * 1000,
        isUtc: true,
      ),
    );
  }
}

/// Fetches short-lived Agora RTC tokens from the `generate-agora-token`
/// Edge Function. The App Certificate stays server-side — the client only
/// ever receives a token bound to a specific (channel, uid).
class AgoraTokenRepository {
  AgoraTokenRepository(this._client);

  final SupabaseClient _client;
  static const _log = AppLogger('AGORA');

  /// Maps a Supabase user id to a stable positive int32 Agora uid. Each
  /// device computes its own — the two peers only need distinct values,
  /// not cross-device agreement, so a local hash is enough.
  static int uidForUser(String userId) => userId.hashCode & 0x7FFFFFFF;

  Future<AgoraToken> fetchToken({
    required String callId,
    required String channelName,
    required int uid,
  }) async {
    _log.info(
      'Requesting token — call=$callId channel=$channelName uid=$uid',
    );
    final res = await _client.functions.invoke(
      'generate-agora-token',
      body: {
        'call_id': callId,
        'channel_name': channelName,
        'uid': uid,
      },
    );
    if (res.status != 200 || res.data is! Map) {
      _log.error(
        'generate-agora-token failed — status=${res.status} data=${res.data}',
      );
      throw Exception('generate-agora-token returned ${res.status}');
    }
    final token = AgoraToken.fromJson(
      (res.data as Map).cast<String, dynamic>(),
    );
    // Never log the token itself — length + expiry only.
    _log.info(
      'Token received — len=${token.token.length} uid=${token.uid} '
      'expiresAt=${token.expiresAt.toIso8601String()}',
    );
    DebugLog.agora('token generated uid=${token.uid}'); // debug-observer
    return token;
  }
}

final agoraTokenRepositoryProvider = Provider<AgoraTokenRepository?>((ref) {
  if (!ref.watch(supabaseAvailableProvider)) return null;
  return AgoraTokenRepository(ref.watch(supabaseClientProvider));
});

/// Non-sensitive token diagnostics for the Debug screen — the token
/// string itself is intentionally absent.
class AgoraTokenDebugInfo {
  const AgoraTokenDebugInfo({
    required this.generated,
    required this.uid,
    required this.expiresAt,
  });

  final bool generated;
  final int? uid;
  final DateTime? expiresAt;

  static const none = AgoraTokenDebugInfo(
    generated: false,
    uid: null,
    expiresAt: null,
  );
}

final agoraTokenDebugProvider =
    StateProvider<AgoraTokenDebugInfo>((ref) => AgoraTokenDebugInfo.none);

/// Live Agora connection diagnostics for the Debug screen — joined state,
/// remote participant count, reconnection flag and how many times the
/// engine has dropped into a reconnecting state this call.
class AgoraConnectionDebug {
  const AgoraConnectionDebug({
    required this.joined,
    required this.remoteCount,
    required this.reconnecting,
    required this.reconnectAttempts,
  });

  final bool joined;
  final int remoteCount;
  final bool reconnecting;
  final int reconnectAttempts;

  static const none = AgoraConnectionDebug(
    joined: false,
    remoteCount: 0,
    reconnecting: false,
    reconnectAttempts: 0,
  );

  AgoraConnectionDebug copyWith({
    bool? joined,
    int? remoteCount,
    bool? reconnecting,
    int? reconnectAttempts,
  }) {
    return AgoraConnectionDebug(
      joined: joined ?? this.joined,
      remoteCount: remoteCount ?? this.remoteCount,
      reconnecting: reconnecting ?? this.reconnecting,
      reconnectAttempts: reconnectAttempts ?? this.reconnectAttempts,
    );
  }
}

final agoraConnectionDebugProvider =
    StateProvider<AgoraConnectionDebug>((ref) => AgoraConnectionDebug.none);
