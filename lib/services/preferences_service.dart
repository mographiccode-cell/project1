import 'package:shared_preferences/shared_preferences.dart';

class PreferencesService {
  static const _favoritesKey = 'favorites_v2';
  static const _recentKey = 'recent_v2';
  static const _historyEnabledKey = 'history_enabled';
  static const _sortKey = 'sort_mode_v2';
  static const _gridKey = 'grid_mode_v2';
  static const _progressPrefix = 'progress_v2_';
  static const _knownVideosKey = 'known_video_ids_v3';
  static const _newVideosKey = 'new_video_ids_v3';

  Future<SharedPreferences> get _prefs => SharedPreferences.getInstance();

  Future<Set<String>> favorites() async {
    return ((await _prefs).getStringList(_favoritesKey) ?? const []).toSet();
  }

  Future<void> toggleFavorite(String id) async {
    final prefs = await _prefs;
    final values = (prefs.getStringList(_favoritesKey) ?? const []).toSet();
    if (!values.add(id)) values.remove(id);
    await prefs.setStringList(_favoritesKey, values.toList());
  }

  Future<bool> historyEnabled() async {
    return (await _prefs).getBool(_historyEnabledKey) ?? true;
  }

  Future<void> setHistoryEnabled(bool value) async {
    await (await _prefs).setBool(_historyEnabledKey, value);
  }

  Future<List<String>> recent() async {
    return (await _prefs).getStringList(_recentKey) ?? const [];
  }

  Future<void> markRecent(String id) async {
    if (!await historyEnabled()) return;
    final prefs = await _prefs;
    final list = (prefs.getStringList(_recentKey) ?? <String>[]).toList();
    list.remove(id);
    list.insert(0, id);
    if (list.length > 120) list.removeRange(120, list.length);
    await prefs.setStringList(_recentKey, list);
  }

  Future<void> saveProgress(
    String id,
    Duration position,
    Duration duration,
  ) async {
    if (!await historyEnabled()) return;
    final prefs = await _prefs;
    final key = '$_progressPrefix$id';
    if (duration <= Duration.zero || position < const Duration(seconds: 5)) {
      await prefs.remove(key);
      return;
    }
    final remaining = duration - position;
    if (remaining <= const Duration(seconds: 15) ||
        position.inMilliseconds >= duration.inMilliseconds * 0.96) {
      await prefs.remove(key);
      return;
    }
    await prefs.setInt(key, position.inMilliseconds);
  }

  Future<void> clearProgress(String id) async {
    await (await _prefs).remove('$_progressPrefix$id');
  }

  Future<Duration> progress(String id) async {
    final value = (await _prefs).getInt('$_progressPrefix$id') ?? 0;
    return Duration(milliseconds: value);
  }

  Future<Map<String, Duration>> allProgress() async {
    final prefs = await _prefs;
    final result = <String, Duration>{};
    for (final key in prefs.getKeys()) {
      if (!key.startsWith(_progressPrefix)) continue;
      final value = prefs.getInt(key) ?? 0;
      if (value > 0) {
        result[key.substring(_progressPrefix.length)] =
            Duration(milliseconds: value);
      }
    }
    return result;
  }

  Future<int> sortMode() async => (await _prefs).getInt(_sortKey) ?? 0;
  Future<void> setSortMode(int value) async =>
      (await _prefs).setInt(_sortKey, value);

  Future<bool> gridMode() async => (await _prefs).getBool(_gridKey) ?? false;
  Future<void> setGridMode(bool value) async =>
      (await _prefs).setBool(_gridKey, value);

  Future<Set<String>> newVideos() async {
    return ((await _prefs).getStringList(_newVideosKey) ?? const []).toSet();
  }

  /// Updates the known inventory and returns videos that are still marked NEW.
  /// On the first v3 scan, only recently-created candidates are labeled NEW;
  /// afterwards every newly discovered MediaStore ID is labeled NEW.
  Future<Set<String>> updateVideoInventory({
    required Set<String> currentIds,
    Set<String> firstRunRecentCandidates = const <String>{},
  }) async {
    final prefs = await _prefs;
    final known = (prefs.getStringList(_knownVideosKey) ?? const <String>[])
        .toSet();
    final unread = (prefs.getStringList(_newVideosKey) ?? const <String>[])
        .toSet();

    if (known.isEmpty) {
      unread.addAll(firstRunRecentCandidates.intersection(currentIds));
    } else {
      unread.addAll(currentIds.difference(known));
    }

    unread.removeWhere((id) => !currentIds.contains(id));
    await prefs.setStringList(_knownVideosKey, currentIds.toList());
    await prefs.setStringList(_newVideosKey, unread.toList());
    return unread;
  }

  Future<void> markVideoSeen(String id) async {
    final prefs = await _prefs;
    final unread = (prefs.getStringList(_newVideosKey) ?? const <String>[])
        .toSet();
    if (unread.remove(id)) {
      await prefs.setStringList(_newVideosKey, unread.toList());
    }
  }

  Future<void> removeVideoState(String id) async {
    final prefs = await _prefs;
    final favorites = (prefs.getStringList(_favoritesKey) ?? const <String>[])
        .toSet()
      ..remove(id);
    final recent = (prefs.getStringList(_recentKey) ?? const <String>[])
        .where((e) => e != id)
        .toList();
    final unread = (prefs.getStringList(_newVideosKey) ?? const <String>[])
        .toSet()
      ..remove(id);
    final known = (prefs.getStringList(_knownVideosKey) ?? const <String>[])
        .toSet()
      ..remove(id);
    await prefs.setStringList(_favoritesKey, favorites.toList());
    await prefs.setStringList(_recentKey, recent);
    await prefs.setStringList(_newVideosKey, unread.toList());
    await prefs.setStringList(_knownVideosKey, known.toList());
    await prefs.remove('$_progressPrefix$id');
  }

  Future<void> clearHistory() async {
    final prefs = await _prefs;
    await prefs.remove(_recentKey);
    final keys = prefs
        .getKeys()
        .where((e) => e.startsWith(_progressPrefix))
        .toList();
    for (final key in keys) {
      await prefs.remove(key);
    }
  }
}
