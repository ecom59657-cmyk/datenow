import 'dart:typed_data';

import 'package:flutter/painting.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../profile_setup/data/profile_repository.dart';
import '../../../../profile_setup/presentation/providers/profile_provider.dart';

/// Session-scoped cache of downloaded photo bytes, keyed by the storage
/// path / identifier. Storage paths are immutable (we never rewrite them),
/// so once a photo is fetched its bytes are kept in memory for the rest of
/// the session. This is a NON-autoDispose family provider on purpose: the
/// cached value survives navigating away and back, which is exactly what
/// removes the repeated `storage.download()` calls that inflated Supabase
/// cached egress.
///
/// Render sites (`discover` cards, inbox avatars, matched profile, home
/// avatar) should `ref.watch(photoBytesProvider(path))` instead of building
/// a fresh `FutureBuilder(getPhotoBytes(...))` on every rebuild.
final photoBytesProvider = FutureProvider.family<Uint8List?, String>(
  (ref, path) => ref.read(profileRepositoryProvider).getPhotoBytes(path),
);

/// Resolves the byte payload for each URL in the current profile's
/// `photoUrls` list, preserving order. The result is auto-refreshed every
/// time the profile changes — handy after add / replace / delete actions.
final profilePhotoBytesProvider = FutureProvider<List<Uint8List?>>(
  (ref) async {
    final profile = ref.watch(currentProfileProvider).asData?.value;
    if (profile == null) return const <Uint8List?>[];
    final repo = ref.watch(profileRepositoryProvider);
    return Future.wait(profile.photoUrls.map(repo.getPhotoBytes));
  },
);

/// Resolves the [ImageProvider] for the current user's primary photo (the
/// first entry of `photoUrls`). Returns `null` when no photo is set.
///
/// Both backends store opaque identifiers — the mock uses `mock://...`,
/// Supabase uses storage paths like `<userId>/<file>.jpg`. Neither is a
/// public URL, so we always go through `getPhotoBytes` and wrap the
/// resulting bytes in a [MemoryImage].
final primaryProfilePhotoProvider = FutureProvider<ImageProvider?>(
  (ref) async {
    final profile = ref.watch(currentProfileProvider).asData?.value;
    final url = profile?.primaryPhotoUrl;
    if (url == null) return null;
    // Route through the session cache so the own-avatar bytes are fetched
    // once and reused across rebuilds / navigation instead of re-downloaded.
    final bytes = await ref.watch(photoBytesProvider(url).future);
    return bytes == null ? null : MemoryImage(bytes);
  },
);
