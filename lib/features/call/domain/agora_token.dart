/// Server-signed token returned by the `agora-token` Edge Function.
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

  bool get isExpired => DateTime.now().isAfter(expiresAt);
}
