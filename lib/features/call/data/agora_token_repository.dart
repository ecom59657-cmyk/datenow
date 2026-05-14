import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/services/supabase_service.dart';
import '../../../core/utils/logger.dart';
import '../domain/agora_token.dart';

/// Talks to the `agora-token` Edge Function to fetch a server-signed
/// channel token. Surfaces clear errors so the call screen can fall back
/// to mock when something's off (function not deployed, secrets missing,
/// caller not in channel, etc).
class AgoraTokenRepository {
  AgoraTokenRepository(this._client);

  final SupabaseClient _client;
  static const _log = AppLogger('AgoraToken');

  /// Maps a Supabase user id (UUID string) to a stable positive int32 so
  /// the same user always joins with the same Agora UID. The Edge Function
  /// validates that the channel name contains the caller's user id, so an
  /// attacker cannot request a token for a channel they don't belong to.
  static int uidFromUserId(String userId) {
    return userId.hashCode & 0x7FFFFFFF;
  }

  /// Builds a deterministic Agora channel name from two user ids. Strips
  /// the dashes (Agora only allows alphanumerics + a handful of symbols)
  /// and truncates to fit the 64-character ceiling.
  static String channelNameFor(String userIdA, String userIdB) {
    final ordered = [userIdA, userIdB]..sort();
    final joined = ordered.join().replaceAll('-', '');
    final body = joined.length > 60 ? joined.substring(0, 60) : joined;
    return 'dn-$body';
  }

  Future<AgoraToken> fetchToken({
    required String channelName,
    required int uid,
  }) async {
    _log.info('fetching token for channel=$channelName uid=$uid');
    final res = await _client.functions.invoke(
      'agora-token',
      body: {
        'channelName': channelName,
        'uid': uid,
      },
    );

    if (res.status != 200 || res.data is! Map) {
      _log.error('token fetch failed — status=${res.status} data=${res.data}');
      throw Exception('agora-token returned status ${res.status}');
    }

    final data = (res.data as Map).cast<String, dynamic>();
    return AgoraToken(
      token: data['token'] as String,
      appId: data['appId'] as String,
      channelName: data['channelName'] as String,
      uid: data['uid'] as int,
      expiresAt: DateTime.fromMillisecondsSinceEpoch(
        (data['expiresAt'] as int) * 1000,
        isUtc: true,
      ),
    );
  }
}

final agoraTokenRepositoryProvider = Provider<AgoraTokenRepository>(
  (ref) => AgoraTokenRepository(ref.watch(supabaseClientProvider)),
);
