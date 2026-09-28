import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:photo_manager/photo_manager.dart';

import '../models/video_item.dart';
import '../services/media_library_service.dart';
import '../services/preferences_service.dart';
import '../widgets/video_thumbnail.dart';
import 'player_page.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

enum LibraryTab { all, newVideos, folders, continueWatching, favorites }
enum SortMode { newest, oldest, name, duration }
enum VideoAction { rename, trash }

class _HomePageState extends State<HomePage> with WidgetsBindingObserver {
  final _library = MediaLibraryService();
  final _prefs = PreferencesService();

  bool _loading = true;
  bool _gridMode = false;
  List<VideoItem> _videos = const [];
  Set<String> _favorites = <String>{};
  Set<String> _newVideoIds = <String>{};
  Map<String, Duration> _progress = <String, Duration>{};
  List<String> _recent = const [];
  String _query = '';
  LibraryTab _tab = LibraryTab.all;
  SortMode _sort = SortMode.newest;
  Timer? _changeDebounce;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    PhotoManager.addChangeCallback(_onMediaChanged);
    PhotoManager.startChangeNotify();
    _reload();
  }

  @override
  void dispose() {
    _changeDebounce?.cancel();
    PhotoManager.removeChangeCallback(_onMediaChanged);
    PhotoManager.stopChangeNotify();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _reload(showLoading: false);
    }
  }

  void _onMediaChanged(MethodCall _) {
    _changeDebounce?.cancel();
    _changeDebounce = Timer(
      const Duration(milliseconds: 650),
      () => _reload(showLoading: false),
    );
  }

  Future<void> _reload({bool showLoading = true}) async {
    if (showLoading && mounted) setState(() => _loading = true);
    final videos = await _library.loadVideos();
    final favorites = await _prefs.favorites();
    final progress = await _prefs.allProgress();
    final recent = await _prefs.recent();
    final sortIndex = await _prefs.sortMode();
    final grid = await _prefs.gridMode();

    final cutoff = DateTime.now().subtract(const Duration(days: 3));
    final recentCandidates = videos
        .where((e) => (e.createdAt ?? DateTime(1970)).isAfter(cutoff))
        .map((e) => e.id)
        .toSet();
    final newIds = await _prefs.updateVideoInventory(
      currentIds: videos.map((e) => e.id).toSet(),
      firstRunRecentCandidates: recentCandidates,
    );

    if (!mounted) return;
    setState(() {
      _videos = videos;
      _favorites = favorites;
      _progress = progress;
      _recent = recent;
      _newVideoIds = newIds;
      _sort = SortMode.values[
        sortIndex.clamp(0, SortMode.values.length - 1),
      ];
      _gridMode = grid;
      _loading = false;
    });
  }

  Future<void> _refreshSessionState() async {
    final favorites = await _prefs.favorites();
    final progress = await _prefs.allProgress();
    final recent = await _prefs.recent();
    final newIds = await _prefs.newVideos();
    if (!mounted) return;
    setState(() {
      _favorites = favorites;
      _progress = progress;
      _recent = recent;
      _newVideoIds = newIds;
    });
  }

  List<VideoItem> _applyCommonFilters(Iterable<VideoItem> source) {
    var result = source;
    final q = _query.trim().toLowerCase();
    if (q.isNotEmpty) {
      result = result.where((item) {
        return item.title.toLowerCase().contains(q) ||
            item.folder.toLowerCase().contains(q) ||
            (item.relativePath ?? '').toLowerCase().contains(q);
      });
    }

    final list = result.toList();
    switch (_sort) {
      case SortMode.newest:
        list.sort(
          (a, b) => (b.createdAt ?? DateTime(1970))
              .compareTo(a.createdAt ?? DateTime(1970)),
        );
        break;
      case SortMode.oldest:
        list.sort(
          (a, b) => (a.createdAt ?? DateTime(1970))
              .compareTo(b.createdAt ?? DateTime(1970)),
        );
        break;
      case SortMode.name:
        list.sort(
          (a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()),
        );
        break;
      case SortMode.duration:
        list.sort((a, b) => b.duration.compareTo(a.duration));
        break;
    }
    return list;
  }

  List<VideoItem> get _sortedAll => _applyCommonFilters(_videos);

  List<VideoItem> get _visibleVideos {
    Iterable<VideoItem> result = _videos;
    switch (_tab) {
      case LibraryTab.all:
      case LibraryTab.folders:
        break;
      case LibraryTab.newVideos:
        result = result.where((e) => _newVideoIds.contains(e.id));
        break;
      case LibraryTab.continueWatching:
        result = result.where(
          (e) => (_progress[e.id] ?? Duration.zero) >=
              const Duration(seconds: 5),
        );
        final order = <String, int>{};
        for (var i = 0; i < _recent.length; i++) {
          order[_recent[i]] = i;
        }
        final list = _applyCommonFilters(result);
        list.sort(
          (a, b) =>
              (order[a.id] ?? 99999).compareTo(order[b.id] ?? 99999),
        );
        return list;
      case LibraryTab.favorites:
        result = result.where((e) => _favorites.contains(e.id));
        break;
    }
    return _applyCommonFilters(result);
  }

  Map<String, List<VideoItem>> get _folderGroups {
    final groups = <String, List<VideoItem>>{};
    for (final item in _applyCommonFilters(_videos)) {
      groups.putIfAbsent(item.folder, () => <VideoItem>[]).add(item);
    }
    final entries = groups.entries.toList()
      ..sort((a, b) => a.key.toLowerCase().compareTo(b.key.toLowerCase()));
    return Map<String, List<VideoItem>>.fromEntries(entries);
  }

  Future<void> _openItem(
    VideoItem item, {
    List<VideoItem>? queue,
  }) async {
    final playlist = queue == null || queue.isEmpty ? _sortedAll : queue;
    var initialIndex = playlist.indexWhere((e) => e.id == item.id);
    if (initialIndex < 0) initialIndex = 0;

    await _prefs.markVideoSeen(item.id);
    if (mounted) {
      setState(() => _newVideoIds.remove(item.id));
    }

    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => Directionality(
          textDirection: TextDirection.rtl,
          child: PlayerPage(
            playlist: playlist,
            initialIndex: initialIndex,
          ),
        ),
      ),
    );
    await _reload(showLoading: false);
  }

  Future<void> _toggleFavorite(VideoItem item) async {
    await _prefs.toggleFavorite(item.id);
    await _refreshSessionState();
  }

  Future<void> _renameItem(VideoItem item) async {
    final currentName = item.title;
    final dot = currentName.lastIndexOf('.');
    final baseName = dot > 0 ? currentName.substring(0, dot) : currentName;
    final controller = TextEditingController(text: baseName);

    final value = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('تغيير اسم الفيديو'),
        content: TextField(
          controller: controller,
          autofocus: true,
          textInputAction: TextInputAction.done,
          decoration: const InputDecoration(
            labelText: 'الاسم الجديد',
            border: OutlineInputBorder(),
          ),
          onSubmitted: (text) => Navigator.pop(context, text),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('إلغاء'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text),
            child: const Text('حفظ'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (value == null || value.trim().isEmpty) return;

    try {
      final ok = await _library.renameVideo(item, value);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(ok ? 'تم تغيير اسم الفيديو.' : 'تعذر تغيير الاسم.'),
        ),
      );
      if (ok) await _reload(showLoading: false);
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('تعذر تغيير الاسم. وافق على طلب النظام إن ظهر.'),
        ),
      );
    }
  }

  Future<void> _trashItem(VideoItem item) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('نقل إلى سلة المهملات؟'),
        content: Text(
          'سيتم نقل «${item.title}» إلى سلة مهملات النظام، وليس حذفه نهائيًا.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('إلغاء'),
          ),
          FilledButton.tonalIcon(
            onPressed: () => Navigator.pop(context, true),
            icon: const Icon(Icons.delete_outline_rounded),
            label: const Text('نقل للسلة'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    try {
      final ids = await _library.moveToTrash(item);
      if (ids.isEmpty) return;
      await _prefs.removeVideoState(item.id);
      await _reload(showLoading: false);
      if (!mounted) return;
      final messenger = ScaffoldMessenger.of(context);
      messenger.hideCurrentSnackBar();
      messenger.showSnackBar(
        SnackBar(
          content: const Text('تم نقل الفيديو إلى سلة المهملات.'),
          action: SnackBarAction(
            label: 'تراجع',
            onPressed: () async {
              try {
                await _library.restoreFromTrash(item);
                await _reload(showLoading: false);
              } catch (_) {}
            },
          ),
        ),
      );
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'تعذر النقل إلى السلة. وافق على نافذة النظام إن ظهرت.',
          ),
        ),
      );
    }
  }

  Future<void> _handleVideoAction(VideoItem item, VideoAction action) async {
    switch (action) {
      case VideoAction.rename:
        await _renameItem(item);
        break;
      case VideoAction.trash:
        await _trashItem(item);
        break;
    }
  }

  Future<void> _chooseSort() async {
    final selected = await showModalBottomSheet<SortMode>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const ListTile(
              title: Text(
                'ترتيب الفيديوهات',
                style: TextStyle(fontWeight: FontWeight.w800),
              ),
            ),
            _sortTile(
              context,
              SortMode.newest,
              'الأحدث أولًا',
              Icons.schedule_rounded,
            ),
            _sortTile(
              context,
              SortMode.oldest,
              'الأقدم أولًا',
              Icons.history_rounded,
            ),
            _sortTile(
              context,
              SortMode.name,
              'حسب الاسم',
              Icons.sort_by_alpha_rounded,
            ),
            _sortTile(
              context,
              SortMode.duration,
              'الأطول أولًا',
              Icons.timelapse_rounded,
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (selected == null) return;
    await _prefs.setSortMode(selected.index);
    if (mounted) setState(() => _sort = selected);
  }

  Widget _sortTile(
    BuildContext context,
    SortMode value,
    String label,
    IconData icon,
  ) {
    return ListTile(
      leading: Icon(icon),
      title: Text(label),
      trailing: _sort == value ? const Icon(Icons.check_rounded) : null,
      onTap: () => Navigator.pop(context, value),
    );
  }

  Future<void> _toggleGrid() async {
    final next = !_gridMode;
    await _prefs.setGridMode(next);
    if (mounted) setState(() => _gridMode = next);
  }

  String get _tabTitle {
    switch (_tab) {
      case LibraryTab.all:
        return 'كل الفيديوهات';
      case LibraryTab.newVideos:
        return 'الفيديوهات الجديدة';
      case LibraryTab.folders:
        return 'المجلدات';
      case LibraryTab.continueWatching:
        return 'متابعة المشاهدة';
      case LibraryTab.favorites:
        return 'المفضلة';
    }
  }

  @override
  Widget build(BuildContext context) {
    final videos = _visibleVideos;
    return Scaffold(
      appBar: AppBar(
        title: const Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('أمان بلاير', style: TextStyle(fontWeight: FontWeight.w900)),
            Text('مكتبتك المحلية', style: TextStyle(fontSize: 11)),
          ],
        ),
        actions: [
          IconButton(
            tooltip: _gridMode ? 'عرض قائمة' : 'عرض شبكي',
            onPressed: _toggleGrid,
            icon: Icon(
              _gridMode ? Icons.view_list_rounded : Icons.grid_view_rounded,
            ),
          ),
          IconButton(
            tooltip: 'الفرز',
            onPressed: _chooseSort,
            icon: const Icon(Icons.sort_rounded),
          ),
          IconButton(
            tooltip: 'إعادة فحص الفيديوهات',
            onPressed: _reload,
            icon: const Icon(Icons.refresh_rounded),
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 8, 14, 6),
              child: SearchBar(
                hintText: 'ابحث باسم الفيديو أو المجلد',
                leading: const Icon(Icons.search_rounded),
                trailing: _query.isEmpty
                    ? null
                    : [
                        IconButton(
                          onPressed: () => setState(() => _query = ''),
                          icon: const Icon(Icons.close_rounded),
                        ),
                      ],
                onChanged: (value) => setState(() => _query = value),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          _tabTitle,
                          style: const TextStyle(
                            fontWeight: FontWeight.w800,
                            fontSize: 18,
                          ),
                        ),
                        Text(
                          _tab == LibraryTab.folders
                              ? '${_folderGroups.length} مجلد'
                              : '${videos.length} فيديو',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ],
                    ),
                  ),
                  if (_tab == LibraryTab.continueWatching &&
                      _progress.isNotEmpty)
                    TextButton.icon(
                      onPressed: () async {
                        await _prefs.clearHistory();
                        await _refreshSessionState();
                      },
                      icon: const Icon(Icons.delete_sweep_outlined),
                      label: const Text('مسح السجل'),
                    ),
                ],
              ),
            ),
            Expanded(
              child: _loading
                  ? const Center(child: CircularProgressIndicator())
                  : _tab == LibraryTab.folders
                  ? _buildFolders()
                  : _buildVideos(videos),
            ),
          ],
        ),
      ),
      bottomNavigationBar: SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            NavigationBar(
              selectedIndex: _tab.index,
              onDestinationSelected: (index) =>
                  setState(() => _tab = LibraryTab.values[index]),
              destinations: [
                const NavigationDestination(
                  icon: Icon(Icons.video_library_outlined),
                  selectedIcon: Icon(Icons.video_library_rounded),
                  label: 'الكل',
                ),
                NavigationDestination(
                  icon: Badge(
                    isLabelVisible: _newVideoIds.isNotEmpty,
                    label: Text('${_newVideoIds.length}'),
                    child: const Icon(Icons.fiber_new_outlined),
                  ),
                  selectedIcon: Badge(
                    isLabelVisible: _newVideoIds.isNotEmpty,
                    label: Text('${_newVideoIds.length}'),
                    child: const Icon(Icons.fiber_new_rounded),
                  ),
                  label: 'جديد',
                ),
                const NavigationDestination(
                  icon: Icon(Icons.folder_outlined),
                  selectedIcon: Icon(Icons.folder_rounded),
                  label: 'المجلدات',
                ),
                const NavigationDestination(
                  icon: Icon(Icons.play_circle_outline_rounded),
                  selectedIcon: Icon(Icons.play_circle_rounded),
                  label: 'استئناف',
                ),
                const NavigationDestination(
                  icon: Icon(Icons.favorite_border_rounded),
                  selectedIcon: Icon(Icons.favorite_rounded),
                  label: 'المفضلة',
                ),
              ],
            ),
            const Padding(
              padding: EdgeInsets.only(bottom: 6),
              child: Text(
                'تصميم وبرمجة : م.محمود دغَبس  مبايل:774813824',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 9),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildVideos(List<VideoItem> videos) {
    if (videos.isEmpty) {
      return _EmptyLibrary(
        isContinue: _tab == LibraryTab.continueWatching,
        isFavorite: _tab == LibraryTab.favorites,
        isNew: _tab == LibraryTab.newVideos,
        onSettings: _library.openSettings,
        onRefresh: _reload,
      );
    }

    if (_gridMode) {
      return RefreshIndicator(
        onRefresh: _reload,
        child: GridView.builder(
          padding: const EdgeInsets.fromLTRB(12, 4, 12, 20),
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 2,
            childAspectRatio: 0.92,
            crossAxisSpacing: 8,
            mainAxisSpacing: 8,
          ),
          itemCount: videos.length,
          itemBuilder: (context, index) {
            final item = videos[index];
            return _VideoGridCard(
              item: item,
              favorite: _favorites.contains(item.id),
              isNew: _newVideoIds.contains(item.id),
              progress: _progress[item.id] ?? Duration.zero,
              onOpen: () => _openItem(item, queue: videos),
              onFavorite: () => _toggleFavorite(item),
              onAction: (action) => _handleVideoAction(item, action),
            );
          },
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: _reload,
      child: ListView.separated(
        padding: const EdgeInsets.fromLTRB(10, 4, 10, 20),
        itemCount: videos.length,
        separatorBuilder: (_, __) => const SizedBox(height: 4),
        itemBuilder: (context, index) {
          final item = videos[index];
          return _VideoRow(
            item: item,
            favorite: _favorites.contains(item.id),
            isNew: _newVideoIds.contains(item.id),
            progress: _progress[item.id] ?? Duration.zero,
            onOpen: () => _openItem(item, queue: videos),
            onFavorite: () => _toggleFavorite(item),
            onAction: (action) => _handleVideoAction(item, action),
          );
        },
      ),
    );
  }

  Widget _buildFolders() {
    final groups = _folderGroups;
    if (groups.isEmpty) {
      return _EmptyLibrary(
        onSettings: _library.openSettings,
        onRefresh: _reload,
      );
    }
    return RefreshIndicator(
      onRefresh: _reload,
      child: ListView.separated(
        padding: const EdgeInsets.fromLTRB(12, 4, 12, 20),
        itemCount: groups.length,
        separatorBuilder: (_, __) => const SizedBox(height: 6),
        itemBuilder: (context, index) {
          final entry = groups.entries.elementAt(index);
          final items = entry.value;
          final newCount = items.where((e) => _newVideoIds.contains(e.id)).length;
          return Card(
            clipBehavior: Clip.antiAlias,
            child: ListTile(
              contentPadding: const EdgeInsets.all(10),
              leading: items.isEmpty
                  ? const SizedBox(
                      width: 90,
                      child: Icon(Icons.folder_rounded),
                    )
                  : VideoThumbnail(
                      asset: items.first.asset,
                      width: 96,
                      height: 64,
                      radius: 12,
                    ),
              title: Text(
                entry.key,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontWeight: FontWeight.w800),
              ),
              subtitle: Text(
                newCount > 0
                    ? '${items.length} فيديو • $newCount جديد'
                    : '${items.length} فيديو',
              ),
              trailing: const Icon(Icons.chevron_left_rounded),
              onTap: () async {
                await Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => Directionality(
                      textDirection: TextDirection.rtl,
                      child: _FolderPage(
                        folder: entry.key,
                        items: items,
                        progress: _progress,
                        favorites: _favorites,
                        newVideoIds: _newVideoIds,
                        onOpen: (item) => _openItem(item, queue: items),
                        onFavorite: _toggleFavorite,
                        onAction: _handleVideoAction,
                      ),
                    ),
                  ),
                );
                await _reload(showLoading: false);
              },
            ),
          );
        },
      ),
    );
  }
}

class _FolderPage extends StatelessWidget {
  const _FolderPage({
    required this.folder,
    required this.items,
    required this.progress,
    required this.favorites,
    required this.newVideoIds,
    required this.onOpen,
    required this.onFavorite,
    required this.onAction,
  });

  final String folder;
  final List<VideoItem> items;
  final Map<String, Duration> progress;
  final Set<String> favorites;
  final Set<String> newVideoIds;
  final Future<void> Function(VideoItem) onOpen;
  final Future<void> Function(VideoItem) onFavorite;
  final Future<void> Function(VideoItem, VideoAction) onAction;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(folder)),
      body: ListView.separated(
        padding: const EdgeInsets.all(10),
        itemCount: items.length,
        separatorBuilder: (_, __) => const SizedBox(height: 4),
        itemBuilder: (context, index) {
          final item = items[index];
          return _VideoRow(
            item: item,
            favorite: favorites.contains(item.id),
            isNew: newVideoIds.contains(item.id),
            progress: progress[item.id] ?? Duration.zero,
            onOpen: () => onOpen(item),
            onFavorite: () => onFavorite(item),
            onAction: (action) async {
              await onAction(item, action);
              if (context.mounted) Navigator.pop(context);
            },
          );
        },
      ),
    );
  }
}

class _EmptyLibrary extends StatelessWidget {
  const _EmptyLibrary({
    required this.onSettings,
    required this.onRefresh,
    this.isContinue = false,
    this.isFavorite = false,
    this.isNew = false,
  });

  final Future<void> Function() onSettings;
  final Future<void> Function() onRefresh;
  final bool isContinue;
  final bool isFavorite;
  final bool isNew;

  @override
  Widget build(BuildContext context) {
    final title = isContinue
        ? 'لا يوجد فيديو متوقف في المنتصف'
        : isFavorite
        ? 'لا توجد فيديوهات مفضلة'
        : isNew
        ? 'لا توجد فيديوهات جديدة'
        : 'لم نجد فيديوهات في الجهاز';
    final message = isContinue
        ? 'ابدأ مشاهدة أي فيديو وسيتذكر أمان بلاير مكان توقفك تلقائيًا.'
        : isFavorite
        ? 'اضغط القلب بجانب أي فيديو لإضافته هنا.'
        : isNew
        ? 'أي فيديو جديد يضاف إلى الجهاز سيظهر هنا تلقائيًا.'
        : 'تأكد من منح التطبيق إذن الوصول للفيديوهات، ثم أعد الفحص.';
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.video_library_outlined, size: 64),
            const SizedBox(height: 16),
            Text(
              title,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 8),
            Text(message, textAlign: TextAlign.center),
            if (!isContinue && !isFavorite && !isNew) ...[
              const SizedBox(height: 18),
              Wrap(
                spacing: 8,
                children: [
                  FilledButton.icon(
                    onPressed: onRefresh,
                    icon: const Icon(Icons.refresh_rounded),
                    label: const Text('إعادة الفحص'),
                  ),
                  OutlinedButton.icon(
                    onPressed: onSettings,
                    icon: const Icon(Icons.settings_outlined),
                    label: const Text('إعدادات الإذن'),
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

String _durationText(Duration d) {
  final h = d.inHours;
  final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
  final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
  return h > 0 ? '$h:$m:$s' : '$m:$s';
}

double _progressFraction(VideoItem item, Duration progress) {
  if (item.duration <= Duration.zero || progress <= Duration.zero) return 0;
  return (progress.inMilliseconds / item.duration.inMilliseconds)
      .clamp(0.0, 1.0)
      .toDouble();
}

class _VideoRow extends StatelessWidget {
  const _VideoRow({
    required this.item,
    required this.favorite,
    required this.isNew,
    required this.progress,
    required this.onOpen,
    required this.onFavorite,
    required this.onAction,
  });

  final VideoItem item;
  final bool favorite;
  final bool isNew;
  final Duration progress;
  final VoidCallback onOpen;
  final VoidCallback onFavorite;
  final ValueChanged<VideoAction> onAction;

  @override
  Widget build(BuildContext context) {
    final fraction = _progressFraction(item, progress);
    return Card(
      child: InkWell(
        borderRadius: BorderRadius.circular(18),
        onTap: onOpen,
        child: Padding(
          padding: const EdgeInsets.all(9),
          child: Row(
            children: [
              Stack(
                alignment: Alignment.bottomCenter,
                children: [
                  VideoThumbnail(asset: item.asset, width: 138, height: 86),
                  Positioned(
                    right: 6,
                    bottom: 7,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 7,
                        vertical: 3,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.74),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(
                        _durationText(item.duration),
                        style: const TextStyle(color: Colors.white, fontSize: 10),
                      ),
                    ),
                  ),
                  if (isNew)
                    Positioned(
                      left: 6,
                      top: 6,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 7,
                          vertical: 3,
                        ),
                        decoration: BoxDecoration(
                          color: Theme.of(context).colorScheme.primary,
                          borderRadius: BorderRadius.circular(9),
                        ),
                        child: Text(
                          'جديد',
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.onPrimary,
                            fontSize: 9,
                            fontWeight: FontWeight.w900,
                          ),
                        ),
                      ),
                    ),
                  if (fraction > 0)
                    Positioned(
                      left: 6,
                      right: 6,
                      bottom: 2,
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(4),
                        child: LinearProgressIndicator(
                          value: fraction,
                          minHeight: 3.5,
                        ),
                      ),
                    ),
                ],
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      item.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.w800),
                    ),
                    const SizedBox(height: 6),
                    Row(
                      children: [
                        const Icon(Icons.folder_outlined, size: 14),
                        const SizedBox(width: 4),
                        Expanded(
                          child: Text(
                            item.folder,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ),
                      ],
                    ),
                    if (fraction > 0) ...[
                      const SizedBox(height: 5),
                      Text(
                        'استئناف من ${_durationText(progress)}',
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.primary,
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              IconButton(
                tooltip: favorite ? 'إزالة من المفضلة' : 'إضافة إلى المفضلة',
                onPressed: onFavorite,
                icon: Icon(
                  favorite
                      ? Icons.favorite_rounded
                      : Icons.favorite_border_rounded,
                ),
              ),
              PopupMenuButton<VideoAction>(
                tooltip: 'إدارة الفيديو',
                onSelected: onAction,
                itemBuilder: (_) => const [
                  PopupMenuItem(
                    value: VideoAction.rename,
                    child: ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(Icons.drive_file_rename_outline_rounded),
                      title: Text('تغيير الاسم'),
                    ),
                  ),
                  PopupMenuItem(
                    value: VideoAction.trash,
                    child: ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(Icons.delete_outline_rounded),
                      title: Text('نقل إلى سلة المهملات'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _VideoGridCard extends StatelessWidget {
  const _VideoGridCard({
    required this.item,
    required this.favorite,
    required this.isNew,
    required this.progress,
    required this.onOpen,
    required this.onFavorite,
    required this.onAction,
  });

  final VideoItem item;
  final bool favorite;
  final bool isNew;
  final Duration progress;
  final VoidCallback onOpen;
  final VoidCallback onFavorite;
  final ValueChanged<VideoAction> onAction;

  @override
  Widget build(BuildContext context) {
    final fraction = _progressFraction(item, progress);
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onOpen,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Stack(
                fit: StackFit.expand,
                children: [
                  VideoThumbnail(
                    asset: item.asset,
                    width: double.infinity,
                    height: double.infinity,
                    radius: 0,
                  ),
                  Positioned(
                    right: 7,
                    bottom: 7,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 7,
                        vertical: 3,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.74),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(
                        _durationText(item.duration),
                        style: const TextStyle(color: Colors.white, fontSize: 10),
                      ),
                    ),
                  ),
                  if (isNew)
                    Positioned(
                      left: 7,
                      top: 7,
                      child: Badge(label: const Text('جديد')),
                    ),
                  if (fraction > 0)
                    Positioned(
                      left: 0,
                      right: 0,
                      bottom: 0,
                      child: LinearProgressIndicator(
                        value: fraction,
                        minHeight: 4,
                      ),
                    ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 8, 2, 6),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          item.title,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontWeight: FontWeight.w800,
                            fontSize: 12,
                          ),
                        ),
                        Text(
                          item.folder,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    onPressed: onFavorite,
                    iconSize: 20,
                    icon: Icon(
                      favorite
                          ? Icons.favorite_rounded
                          : Icons.favorite_border_rounded,
                    ),
                  ),
                  PopupMenuButton<VideoAction>(
                    padding: EdgeInsets.zero,
                    onSelected: onAction,
                    itemBuilder: (_) => const [
                      PopupMenuItem(
                        value: VideoAction.rename,
                        child: Text('تغيير الاسم'),
                      ),
                      PopupMenuItem(
                        value: VideoAction.trash,
                        child: Text('نقل إلى السلة'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
