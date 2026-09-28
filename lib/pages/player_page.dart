import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:path_provider/path_provider.dart';
import 'package:screen_brightness/screen_brightness.dart';

import '../models/video_item.dart';
import '../services/preferences_service.dart';

enum _VerticalGestureMode { volume, playlist, brightness }
enum _OrientationMode { auto, landscape, portrait }
enum _ViewMode { fit, crop, stretch, fitWidth, fitHeight }

class PlayerPage extends StatefulWidget {
  const PlayerPage({
    super.key,
    required this.playlist,
    required this.initialIndex,
  });

  final List<VideoItem> playlist;
  final int initialIndex;

  @override
  State<PlayerPage> createState() => _PlayerPageState();
}

class _PlayerPageState extends State<PlayerPage> with WidgetsBindingObserver {
  final _prefs = PreferencesService();
  late final Player _player;
  late final VideoController _controller;

  StreamSubscription<Duration>? _positionSub;
  StreamSubscription<bool>? _completedSub;
  StreamSubscription<int?>? _widthSub;
  StreamSubscription<int?>? _heightSub;
  Timer? _hideTimer;
  Timer? _lockHintTimer;
  Timer? _messageTimer;

  late int _currentIndex;
  bool _switching = false;
  bool _locked = false;
  bool _lockHintVisible = false;
  bool _controlsVisible = true;
  bool _repeat = false;
  bool _resumed = false;
  bool _openingError = false;

  double _zoom = 1;
  double _startZoom = 1;
  double _subtitleSize = 22;
  double _subtitleDelay = 0;
  double _playbackRate = 1;
  _ViewMode _viewMode = _ViewMode.fit;
  _OrientationMode _orientationMode = _OrientationMode.auto;

  Duration? _dragPreview;
  Duration? _sliderPreview;
  Duration _dragStartPosition = Duration.zero;
  double _horizontalDragPixels = 0;
  Duration _lastSavedPosition = Duration.zero;
  Duration _duration = Duration.zero;

  _VerticalGestureMode? _verticalGestureMode;
  double _verticalStartY = 0;
  double _verticalBaseBrightness = 0.5;
  double _verticalBaseVolume = 100;
  double _verticalPlaylistDelta = 0;
  String? _gestureLabel;
  double? _gestureValue;
  String? _temporaryMessage;

  int? _videoWidth;
  int? _videoHeight;

  VideoItem get _currentItem => widget.playlist[_currentIndex];

  BoxFit get _fit {
    switch (_viewMode) {
      case _ViewMode.fit:
        return BoxFit.contain;
      case _ViewMode.crop:
        return BoxFit.cover;
      case _ViewMode.stretch:
        return BoxFit.fill;
      case _ViewMode.fitWidth:
        return BoxFit.fitWidth;
      case _ViewMode.fitHeight:
        return BoxFit.fitHeight;
    }
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _currentIndex = widget.initialIndex.clamp(0, widget.playlist.length - 1).toInt();
    _player = Player();
    _controller = VideoController(
      _player,
      configuration: const VideoControllerConfiguration(
        enableHardwareAcceleration: true,
      ),
    );
    _enterViewerMode();
    _listenToPlayer();
    _openIndex(_currentIndex, firstOpen: true);
  }

  Future<void> _enterViewerMode() async {
    await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
  }

  Future<void> _leaveViewerMode() async {
    await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    await SystemChrome.setPreferredOrientations(DeviceOrientation.values);
  }

  void _listenToPlayer() {
    _positionSub = _player.stream.position.listen((position) {
      final duration = _player.state.duration;
      if (duration > Duration.zero) _duration = duration;
      if ((position - _lastSavedPosition).abs() >=
          const Duration(seconds: 15)) {
        _lastSavedPosition = position;
        _prefs.saveProgress(_currentItem.id, position, duration);
      }
    });

    _completedSub = _player.stream.completed.listen((completed) async {
      if (!completed) return;
      if (_repeat) return;
      await _prefs.clearProgress(_currentItem.id);
      if (_currentIndex < widget.playlist.length - 1) {
        await Future<void>.delayed(const Duration(milliseconds: 220));
        await _openIndex(_currentIndex + 1, showMessage: true);
      }
    });

    _widthSub = _player.stream.width.listen((value) {
      _videoWidth = value;
      _applyAutoOrientation();
    });
    _heightSub = _player.stream.height.listen((value) {
      _videoHeight = value;
      _applyAutoOrientation();
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive) {
      _saveCurrentProgress();
    }
  }

  Future<File?> _resolveFile(VideoItem item) async {
    return await item.asset.originFile ?? await item.asset.file;
  }

  Future<void> _openIndex(
    int index, {
    bool firstOpen = false,
    bool showMessage = false,
  }) async {
    if (_switching || index < 0 || index >= widget.playlist.length) return;
    _switching = true;

    if (!firstOpen) {
      await _saveCurrentProgress();
    }

    final item = widget.playlist[index];
    final file = await _resolveFile(item);
    if (file == null || !await file.exists()) {
      _switching = false;
      if (mounted) {
        setState(() => _openingError = true);
        _showMessage('تعذر الوصول إلى هذا الفيديو');
      }
      return;
    }

    final initialPosition = await _prefs.progress(item.id);
    await _prefs.markRecent(item.id);
    await _prefs.markVideoSeen(item.id);

    if (mounted) {
      setState(() {
        _currentIndex = index;
        _openingError = false;
        _resumed = false;
        _dragPreview = null;
        _sliderPreview = null;
        _duration = Duration.zero;
        _lastSavedPosition = Duration.zero;
        _zoom = 1;
      });
    } else {
      _currentIndex = index;
    }

    try {
      await _player.open(
        Media(Uri.file(file.path).toString()),
        play: false,
      );
      _duration = _player.state.duration;
      if (_playbackRate != 1) {
        await _player.setRate(_playbackRate);
      }
      if (initialPosition >= const Duration(seconds: 5)) {
        final duration = _player.state.duration;
        if (duration <= Duration.zero || initialPosition < duration) {
          await _fastSeek(initialPosition);
          _lastSavedPosition = initialPosition;
          _resumed = true;
          Timer(const Duration(seconds: 2), () {
            if (mounted && _currentItem.id == item.id) {
              setState(() => _resumed = false);
            }
          });
        }
      }
      await _player.play();
      _applyAutoOrientation();
      if (showMessage) {
        _showMessage(
          '${index + 1}/${widget.playlist.length}  ${item.title}',
        );
      }
      if (mounted) setState(() {});
      _scheduleControlsHide();
    } catch (_) {
      if (mounted) {
        setState(() => _openingError = true);
        _showMessage('تعذر تشغيل هذا الفيديو');
      }
    } finally {
      _switching = false;
    }
  }

  Future<void> _saveCurrentProgress() async {
    if (widget.playlist.isEmpty) return;
    await _prefs.saveProgress(
      _currentItem.id,
      _player.state.position,
      _player.state.duration,
    );
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    _lockHintTimer?.cancel();
    _messageTimer?.cancel();
    _positionSub?.cancel();
    _completedSub?.cancel();
    _widthSub?.cancel();
    _heightSub?.cancel();
    _saveCurrentProgress();
    ScreenBrightness.instance.resetApplicationScreenBrightness();
    _leaveViewerMode();
    _player.dispose();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  void _scheduleControlsHide() {
    _hideTimer?.cancel();
    if (_locked || !_controlsVisible) return;
    _hideTimer = Timer(const Duration(seconds: 4), () {
      if (mounted && !_locked) setState(() => _controlsVisible = false);
    });
  }

  void _showControls() {
    if (_locked) return;
    if (mounted) setState(() => _controlsVisible = true);
    _scheduleControlsHide();
  }

  void _showLockHint() {
    _lockHintTimer?.cancel();
    if (mounted) setState(() => _lockHintVisible = true);
    _lockHintTimer = Timer(const Duration(seconds: 2), () {
      if (mounted) setState(() => _lockHintVisible = false);
    });
  }

  void _lockControls() {
    _hideTimer?.cancel();
    setState(() {
      _locked = true;
      _controlsVisible = false;
    });
    _showLockHint();
  }

  void _unlockControls() {
    _lockHintTimer?.cancel();
    setState(() {
      _locked = false;
      _lockHintVisible = false;
      _controlsVisible = true;
    });
    _scheduleControlsHide();
  }

  void _showMessage(String message) {
    _messageTimer?.cancel();
    if (mounted) setState(() => _temporaryMessage = message);
    _messageTimer = Timer(const Duration(milliseconds: 1500), () {
      if (mounted) setState(() => _temporaryMessage = null);
    });
  }

  String _fmt(Duration value) {
    final h = value.inHours;
    final m = value.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = value.inSeconds.remainder(60).toString().padLeft(2, '0');
    return h > 0 ? '$h:$m:$s' : '$m:$s';
  }

  Future<void> _fastSeek(Duration target) async {
    final duration = _player.state.duration;
    var safeTarget = target;
    if (safeTarget < Duration.zero) safeTarget = Duration.zero;
    if (duration > Duration.zero && safeTarget > duration) {
      safeTarget = duration;
    }

    final platform = _player.platform;
    if (platform is NativePlayer) {
      final seconds = safeTarget.inMilliseconds / 1000.0;
      try {
        await platform.command(<String>[
          'seek',
          seconds.toStringAsFixed(3),
          'absolute+keyframes',
        ]);
        return;
      } catch (_) {}
    }
    await _player.seek(safeTarget);
  }

  Future<void> _seekBy(Duration delta) async {
    var target = _player.state.position + delta;
    if (target < Duration.zero) target = Duration.zero;
    if (_player.state.duration > Duration.zero &&
        target > _player.state.duration) {
      target = _player.state.duration;
    }
    await _fastSeek(target);
    _showControls();
  }

  Future<void> _saveScreenshot() async {
    final Uint8List? bytes = await _player.screenshot(
      format: 'image/jpeg',
      includeLibassSubtitles: true,
    );
    if (bytes == null || !mounted) return;
    final dir = await getTemporaryDirectory();
    final file = File(
      '${dir.path}${Platform.pathSeparator}aman_${DateTime.now().millisecondsSinceEpoch}.jpg',
    );
    await file.writeAsBytes(bytes, flush: true);
    if (!mounted) return;
    _showMessage('تم التقاط صورة من الفيديو');
  }

  Future<void> _pickExternalSubtitle() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: const <String>[
        'srt',
        'ass',
        'ssa',
        'vtt',
        'sub',
        'smi',
      ],
      allowMultiple: false,
    );
    final path = result?.files.single.path;
    if (path == null || path.isEmpty) return;
    final name = path.split(Platform.pathSeparator).last;
    await _player.setSubtitleTrack(
      SubtitleTrack.uri(
        Uri.file(path).toString(),
        title: name,
      ),
    );
    if (mounted) _showMessage('تم تحميل الترجمة: $name');
  }

  Future<void> _showSpeedSheet() async {
    final rate = await showModalBottomSheet<double>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(18, 4, 18, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'سرعة التشغيل',
                style: TextStyle(fontWeight: FontWeight.w900, fontSize: 18),
              ),
              const SizedBox(height: 14),
              Wrap(
                spacing: 9,
                runSpacing: 9,
                children: [
                  0.25,
                  0.5,
                  0.75,
                  1.0,
                  1.25,
                  1.5,
                  1.75,
                  2.0,
                  2.5,
                  3.0,
                ].map((value) {
                  return ChoiceChip(
                    label: Text('${value}x'),
                    selected: (_playbackRate - value).abs() < 0.01,
                    onSelected: (_) => Navigator.pop(context, value),
                  );
                }).toList(),
              ),
            ],
          ),
        ),
      ),
    );
    if (rate != null) {
      _playbackRate = rate;
      await _player.setRate(rate);
      if (mounted) setState(() {});
      _showControls();
    }
  }

  Future<void> _showTracksSheet() async {
    final audio = _player.state.tracks.audio;
    final subtitles = _player.state.tracks.subtitle;
    if (!mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          padding: const EdgeInsets.only(bottom: 20),
          children: [
            const ListTile(
              title: Text(
                'الصوت والترجمة',
                style: TextStyle(fontWeight: FontWeight.w900, fontSize: 18),
              ),
            ),
            const ListTile(
              title: Text(
                'المسارات الصوتية',
                style: TextStyle(fontWeight: FontWeight.w800),
              ),
            ),
            if (audio.isEmpty)
              const ListTile(
                leading: Icon(Icons.graphic_eq_rounded),
                title: Text('لا توجد مسارات صوتية إضافية'),
              ),
            ...audio.map(
              (track) => ListTile(
                leading: const Icon(Icons.graphic_eq_rounded),
                title: Text(track.title ?? track.language ?? 'مسار صوتي'),
                subtitle: Text(track.codec ?? ''),
                onTap: () async {
                  await _player.setAudioTrack(track);
                  if (context.mounted) Navigator.pop(context);
                },
              ),
            ),
            const Divider(),
            const ListTile(
              title: Text(
                'الترجمة',
                style: TextStyle(fontWeight: FontWeight.w800),
              ),
            ),
            ListTile(
              leading: const Icon(Icons.add_box_outlined),
              title: const Text('فتح ملف ترجمة خارجي'),
              subtitle: const Text('SRT / ASS / SSA / VTT / SUB / SMI'),
              onTap: () async {
                Navigator.pop(context);
                await _pickExternalSubtitle();
              },
            ),
            ListTile(
              leading: const Icon(Icons.subtitles_off_outlined),
              title: const Text('إيقاف الترجمة'),
              onTap: () async {
                await _player.setSubtitleTrack(SubtitleTrack.no());
                if (context.mounted) Navigator.pop(context);
              },
            ),
            if (subtitles.isEmpty)
              const ListTile(
                leading: Icon(Icons.subtitles_outlined),
                title: Text('لا توجد ترجمة مدمجة في هذا الفيديو'),
              ),
            ...subtitles.map(
              (track) => ListTile(
                leading: const Icon(Icons.subtitles_outlined),
                title: Text(track.title ?? track.language ?? 'ترجمة'),
                subtitle: Text(track.codec ?? ''),
                onTap: () async {
                  await _player.setSubtitleTrack(track);
                  if (context.mounted) Navigator.pop(context);
                },
              ),
            ),
          ],
        ),
      ),
    );
    _showControls();
  }

  Future<void> _setSubtitleDelay(double value) async {
    _subtitleDelay = value;
    final platform = _player.platform;
    if (platform is NativePlayer) {
      try {
        await platform.setProperty('sub-delay', value.toStringAsFixed(2));
      } catch (_) {}
    }
    if (mounted) setState(() {});
  }

  Future<void> _showSubtitleStyleSheet() async {
    double draftSize = _subtitleSize;
    double draftDelay = _subtitleDelay;
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (context) => StatefulBuilder(
        builder: (context, setSheetState) => SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(18, 6, 18, 24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'إعدادات الترجمة',
                  style: TextStyle(fontWeight: FontWeight.w900, fontSize: 18),
                ),
                const SizedBox(height: 16),
                Text('حجم الترجمة: ${draftSize.toInt()}'),
                Slider(
                  min: 16,
                  max: 40,
                  divisions: 12,
                  value: draftSize,
                  onChanged: (value) {
                    setSheetState(() => draftSize = value);
                    setState(() => _subtitleSize = value);
                  },
                ),
                const SizedBox(height: 8),
                Text(
                  'مزامنة الترجمة: ${draftDelay >= 0 ? '+' : ''}${draftDelay.toStringAsFixed(1)} ثانية',
                ),
                Slider(
                  min: -5,
                  max: 5,
                  divisions: 40,
                  value: draftDelay,
                  onChanged: (value) {
                    setSheetState(() => draftDelay = value);
                    _setSubtitleDelay(value);
                  },
                ),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: () async {
                          Navigator.pop(context);
                          await _pickExternalSubtitle();
                        },
                        icon: const Icon(Icons.file_open_outlined),
                        label: const Text('ملف ترجمة خارجي'),
                      ),
                    ),
                    const SizedBox(width: 8),
                    TextButton(
                      onPressed: () async {
                        draftDelay = 0;
                        await _setSubtitleDelay(0);
                        if (context.mounted) {
                          setSheetState(() {});
                        }
                      },
                      child: const Text('إعادة الضبط'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
    _showControls();
  }

  Future<void> _toggleRepeat() async {
    _repeat = !_repeat;
    await _player.setPlaylistMode(
      _repeat ? PlaylistMode.single : PlaylistMode.none,
    );
    if (mounted) setState(() {});
    _showControls();
  }

  Future<void> _showViewModeSheet() async {
    final mode = await showModalBottomSheet<_ViewMode>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const ListTile(
              title: Text(
                'طريقة عرض الفيديو',
                style: TextStyle(fontWeight: FontWeight.w900, fontSize: 18),
              ),
            ),
            _viewModeTile(context, _ViewMode.fit, 'ملاءمة داخل الشاشة', Icons.fit_screen_rounded),
            _viewModeTile(context, _ViewMode.crop, 'ملء الشاشة مع قص الحواف', Icons.crop_free_rounded),
            _viewModeTile(context, _ViewMode.stretch, 'تمديد كامل', Icons.open_in_full_rounded),
            _viewModeTile(context, _ViewMode.fitWidth, 'ملاءمة العرض', Icons.swap_horiz_rounded),
            _viewModeTile(context, _ViewMode.fitHeight, 'ملاءمة الارتفاع', Icons.swap_vert_rounded),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (mode != null && mounted) {
      setState(() {
        _viewMode = mode;
        _zoom = 1;
      });
    }
    _showControls();
  }

  Widget _viewModeTile(
    BuildContext context,
    _ViewMode value,
    String label,
    IconData icon,
  ) {
    return ListTile(
      leading: Icon(icon),
      title: Text(label),
      trailing: _viewMode == value ? const Icon(Icons.check_rounded) : null,
      onTap: () => Navigator.pop(context, value),
    );
  }

  Future<void> _showOrientationSheet() async {
    final mode = await showModalBottomSheet<_OrientationMode>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const ListTile(
              title: Text(
                'اتجاه الشاشة',
                style: TextStyle(fontWeight: FontWeight.w900, fontSize: 18),
              ),
            ),
            _orientationTile(
              context,
              _OrientationMode.auto,
              'تلقائي حسب الفيديو',
              Icons.screen_rotation_rounded,
            ),
            _orientationTile(
              context,
              _OrientationMode.landscape,
              'أفقي',
              Icons.stay_current_landscape_rounded,
            ),
            _orientationTile(
              context,
              _OrientationMode.portrait,
              'عمودي',
              Icons.stay_current_portrait_rounded,
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (mode == null) return;
    _orientationMode = mode;
    await _applyOrientationMode();
    if (mounted) setState(() {});
    _showControls();
  }

  Widget _orientationTile(
    BuildContext context,
    _OrientationMode value,
    String label,
    IconData icon,
  ) {
    return ListTile(
      leading: Icon(icon),
      title: Text(label),
      trailing:
          _orientationMode == value ? const Icon(Icons.check_rounded) : null,
      onTap: () => Navigator.pop(context, value),
    );
  }

  Future<void> _applyOrientationMode() async {
    switch (_orientationMode) {
      case _OrientationMode.landscape:
        await SystemChrome.setPreferredOrientations(const <DeviceOrientation>[
          DeviceOrientation.landscapeLeft,
          DeviceOrientation.landscapeRight,
        ]);
        break;
      case _OrientationMode.portrait:
        await SystemChrome.setPreferredOrientations(const <DeviceOrientation>[
          DeviceOrientation.portraitUp,
          DeviceOrientation.portraitDown,
        ]);
        break;
      case _OrientationMode.auto:
        await _applyAutoOrientation();
        break;
    }
  }

  Future<void> _applyAutoOrientation() async {
    if (_orientationMode != _OrientationMode.auto) return;
    final width = _videoWidth;
    final height = _videoHeight;
    if (width == null || height == null || width <= 0 || height <= 0) return;
    if (width > height) {
      await SystemChrome.setPreferredOrientations(const <DeviceOrientation>[
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
      ]);
    } else {
      await SystemChrome.setPreferredOrientations(const <DeviceOrientation>[
        DeviceOrientation.portraitUp,
        DeviceOrientation.portraitDown,
      ]);
    }
  }

  Future<void> _goNext() async {
    if (_currentIndex >= widget.playlist.length - 1) {
      _showMessage('هذا آخر فيديو');
      return;
    }
    await _openIndex(_currentIndex + 1, showMessage: true);
  }

  Future<void> _goPrevious() async {
    if (_currentIndex <= 0) {
      _showMessage('هذا أول فيديو');
      return;
    }
    await _openIndex(_currentIndex - 1, showMessage: true);
  }

  void _startHorizontalSeek() {
    if (_locked) return;
    _horizontalDragPixels = 0;
    _dragStartPosition = _player.state.position;
    _dragPreview = _dragStartPosition;
    _hideTimer?.cancel();
  }

  void _updateHorizontalSeek(double deltaPixels, double width) {
    if (_locked || _dragPreview == null || width <= 0) return;
    final duration = _player.state.duration;
    if (duration <= Duration.zero) return;
    _horizontalDragPixels += deltaPixels;

    final durationSeconds = duration.inSeconds.toDouble();
    final seekWindowSeconds =
        (durationSeconds * 0.18).clamp(60.0, 600.0).toDouble();
    final deltaSeconds = _horizontalDragPixels / width * seekWindowSeconds;
    var next = _dragStartPosition +
        Duration(milliseconds: (deltaSeconds * 1000).round());
    if (next < Duration.zero) next = Duration.zero;
    if (next > duration) next = duration;
    setState(() => _dragPreview = next);
  }

  Future<void> _finishHorizontalSeek() async {
    if (_locked || _dragPreview == null) return;
    final target = _dragPreview!;
    setState(() => _dragPreview = null);
    await _fastSeek(target);
    _showControls();
  }

  Future<void> _beginVerticalGesture(
    DragStartDetails details,
    BoxConstraints constraints,
  ) async {
    if (_locked) return;
    _verticalStartY = details.localPosition.dy;
    _verticalPlaylistDelta = 0;
    final xRatio = constraints.maxWidth <= 0
        ? 0.5
        : details.localPosition.dx / constraints.maxWidth;

    if (xRatio < 0.30) {
      _verticalGestureMode = _VerticalGestureMode.volume;
      _verticalBaseVolume = _player.state.volume;
      _gestureLabel = 'الصوت';
      _gestureValue = _verticalBaseVolume / 100;
    } else if (xRatio > 0.70) {
      _verticalGestureMode = _VerticalGestureMode.brightness;
      _verticalBaseBrightness =
          await ScreenBrightness.instance.application;
      _gestureLabel = 'السطوع';
      _gestureValue = _verticalBaseBrightness;
    } else {
      _verticalGestureMode = _VerticalGestureMode.playlist;
      _gestureLabel = null;
      _gestureValue = null;
    }
    if (mounted) setState(() {});
  }

  Future<void> _updateVerticalGesture(
    DragUpdateDetails details,
    BoxConstraints constraints,
  ) async {
    if (_locked || _verticalGestureMode == null) return;
    final height = constraints.maxHeight <= 0 ? 1.0 : constraints.maxHeight;
    final deltaFromStart = _verticalStartY - details.localPosition.dy;
    final normalized = deltaFromStart / height;

    switch (_verticalGestureMode!) {
      case _VerticalGestureMode.volume:
        final next = (_verticalBaseVolume + normalized * 120)
            .clamp(0.0, 100.0)
            .toDouble();
        await _player.setVolume(next);
        if (mounted) {
          setState(() {
            _gestureLabel = 'الصوت';
            _gestureValue = next / 100;
          });
        }
        break;
      case _VerticalGestureMode.brightness:
        final next = (_verticalBaseBrightness + normalized * 1.15)
            .clamp(0.02, 1.0)
            .toDouble();
        await ScreenBrightness.instance.setApplicationScreenBrightness(next);
        if (mounted) {
          setState(() {
            _gestureLabel = 'السطوع';
            _gestureValue = next;
          });
        }
        break;
      case _VerticalGestureMode.playlist:
        _verticalPlaylistDelta = details.localPosition.dy - _verticalStartY;
        if (mounted) {
          setState(() {
            if (_verticalPlaylistDelta > 55) {
              _gestureLabel = _currentIndex < widget.playlist.length - 1
                  ? '↓ الفيديو التالي'
                  : 'آخر فيديو';
            } else if (_verticalPlaylistDelta < -55) {
              _gestureLabel = _currentIndex > 0
                  ? '↑ الفيديو السابق'
                  : 'أول فيديو';
            } else {
              _gestureLabel = 'اسحب لأسفل للتالي';
            }
            _gestureValue = null;
          });
        }
        break;
    }
  }

  Future<void> _finishVerticalGesture() async {
    if (_locked || _verticalGestureMode == null) return;
    final mode = _verticalGestureMode;
    final delta = _verticalPlaylistDelta;
    if (mounted) {
      setState(() {
        _verticalGestureMode = null;
        _gestureLabel = null;
        _gestureValue = null;
      });
    }
    if (mode == _VerticalGestureMode.playlist) {
      if (delta > 85) {
        await _goNext();
      } else if (delta < -85) {
        await _goPrevious();
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      onPopInvokedWithResult: (_, __) {
        _saveCurrentProgress();
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        body: SafeArea(
          child: LayoutBuilder(
            builder: (context, constraints) {
              return GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () {
                  if (_locked) {
                    _showLockHint();
                    return;
                  }
                  setState(() => _controlsVisible = !_controlsVisible);
                  _scheduleControlsHide();
                },
                onDoubleTapDown: (details) {
                  if (_locked) return;
                  final left =
                      details.localPosition.dx < constraints.maxWidth / 2;
                  _seekBy(Duration(seconds: left ? -10 : 10));
                },
                onScaleStart: (_) {
                  if (_locked) return;
                  _startZoom = _zoom;
                },
                onScaleUpdate: (details) {
                  if (_locked || details.pointerCount < 2) return;
                  setState(
                    () => _zoom =
                        (_startZoom * details.scale).clamp(0.8, 3.0).toDouble(),
                  );
                },
                onHorizontalDragStart: (_) => _startHorizontalSeek(),
                onHorizontalDragUpdate: (details) => _updateHorizontalSeek(
                  details.primaryDelta ?? 0,
                  constraints.maxWidth,
                ),
                onHorizontalDragEnd: (_) => _finishHorizontalSeek(),
                onVerticalDragStart: (details) =>
                    _beginVerticalGesture(details, constraints),
                onVerticalDragUpdate: (details) =>
                    _updateVerticalGesture(details, constraints),
                onVerticalDragEnd: (_) => _finishVerticalGesture(),
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    Center(
                      child: Transform.scale(
                        scale: _zoom,
                        child: Video(
                          controller: _controller,
                          fit: _fit,
                          controls: NoVideoControls,
                          subtitleViewConfiguration: SubtitleViewConfiguration(
                            style: TextStyle(
                              fontSize: _subtitleSize,
                              height: 1.35,
                              color: Colors.white,
                              fontWeight: FontWeight.w700,
                              backgroundColor:
                                  Colors.black.withValues(alpha: 0.28),
                              shadows: const [
                                Shadow(color: Colors.black, blurRadius: 5),
                              ],
                            ),
                            textAlign: TextAlign.center,
                            padding: const EdgeInsets.fromLTRB(24, 24, 24, 48),
                          ),
                        ),
                      ),
                    ),
                    if (_openingError)
                      Center(
                        child: Container(
                          padding: const EdgeInsets.all(18),
                          margin: const EdgeInsets.all(28),
                          decoration: BoxDecoration(
                            color: Colors.black.withValues(alpha: 0.82),
                            borderRadius: BorderRadius.circular(18),
                          ),
                          child: const Text(
                            'تعذر فتح هذا الفيديو. اسحب لأسفل للانتقال إلى الفيديو التالي.',
                            textAlign: TextAlign.center,
                            style: TextStyle(color: Colors.white),
                          ),
                        ),
                      ),
                    if (_resumed)
                      Positioned(
                        top: 58,
                        left: 18,
                        right: 18,
                        child: IgnorePointer(
                          child: Center(
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 14,
                                vertical: 8,
                              ),
                              decoration: BoxDecoration(
                                color: Colors.black.withValues(alpha: 0.68),
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: Text(
                                'تم الاستئناف من ${_fmt(_lastSavedPosition)}',
                                style: const TextStyle(color: Colors.white),
                              ),
                            ),
                          ),
                        ),
                      ),
                    if (_dragPreview != null || _sliderPreview != null)
                      Center(
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            color: Colors.black.withValues(alpha: 0.78),
                            borderRadius: BorderRadius.circular(15),
                          ),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 18,
                              vertical: 12,
                            ),
                            child: Text(
                              _fmt(_dragPreview ?? _sliderPreview!),
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 23,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                        ),
                      ),
                    if (_gestureLabel != null)
                      Positioned(
                        top: 86,
                        left: 24,
                        right: 24,
                        child: IgnorePointer(
                          child: Center(
                            child: Container(
                              constraints: const BoxConstraints(maxWidth: 250),
                              padding: const EdgeInsets.symmetric(
                                horizontal: 14,
                                vertical: 10,
                              ),
                              decoration: BoxDecoration(
                                color: Colors.black.withValues(alpha: 0.72),
                                borderRadius: BorderRadius.circular(14),
                              ),
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Text(
                                    _gestureLabel!,
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontWeight: FontWeight.w800,
                                    ),
                                  ),
                                  if (_gestureValue != null) ...[
                                    const SizedBox(height: 6),
                                    LinearProgressIndicator(
                                      value: _gestureValue!.clamp(0.0, 1.0).toDouble(),
                                      minHeight: 5,
                                    ),
                                  ],
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                    if (_temporaryMessage != null)
                      Positioned(
                        bottom: 88,
                        left: 24,
                        right: 24,
                        child: IgnorePointer(
                          child: Center(
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 14,
                                vertical: 9,
                              ),
                              decoration: BoxDecoration(
                                color: Colors.black.withValues(alpha: 0.72),
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: Text(
                                _temporaryMessage!,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                textAlign: TextAlign.center,
                                style: const TextStyle(color: Colors.white),
                              ),
                            ),
                          ),
                        ),
                      ),
                    if (!_locked && _controlsVisible) _buildControls(context),
                    if (_locked && _lockHintVisible)
                      Positioned(
                        right: 8,
                        top: 70,
                        child: Material(
                          color: Colors.black.withValues(alpha: 0.55),
                          borderRadius: BorderRadius.circular(18),
                          child: InkWell(
                            borderRadius: BorderRadius.circular(18),
                            onTap: _unlockControls,
                            child: const Padding(
                              padding: EdgeInsets.symmetric(
                                horizontal: 12,
                                vertical: 8,
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(
                                    Icons.lock_open_rounded,
                                    color: Colors.white,
                                    size: 19,
                                  ),
                                  SizedBox(width: 6),
                                  Text(
                                    'فتح',
                                    style: TextStyle(
                                      color: Colors.white,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _buildControls(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        IgnorePointer(
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Colors.black.withValues(alpha: 0.76),
                  Colors.transparent,
                  Colors.black.withValues(alpha: 0.84),
                ],
                stops: const [0, 0.48, 1],
              ),
            ),
          ),
        ),
        Align(
          alignment: Alignment.topCenter,
          child: Row(
            children: [
              IconButton(
                color: Colors.white,
                icon: const Icon(Icons.arrow_back_rounded),
                onPressed: () => Navigator.pop(context),
              ),
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _currentItem.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    Text(
                      '${_currentIndex + 1}/${widget.playlist.length}',
                      style: const TextStyle(
                        color: Colors.white60,
                        fontSize: 10,
                      ),
                    ),
                  ],
                ),
              ),
              IconButton(
                tooltip: 'اتجاه الشاشة',
                color: Colors.white,
                onPressed: _showOrientationSheet,
                icon: const Icon(Icons.screen_rotation_rounded),
              ),
              IconButton(
                tooltip: 'تكرار الفيديو',
                color: _repeat
                    ? Theme.of(context).colorScheme.primary
                    : Colors.white,
                onPressed: _toggleRepeat,
                icon: const Icon(Icons.repeat_one_rounded),
              ),
              PopupMenuButton<String>(
                color: Theme.of(context).colorScheme.surface,
                iconColor: Colors.white,
                onSelected: (value) {
                  if (value == 'tracks') _showTracksSheet();
                  if (value == 'speed') _showSpeedSheet();
                  if (value == 'subtitle_style') _showSubtitleStyleSheet();
                  if (value == 'view') _showViewModeSheet();
                  if (value == 'orientation') _showOrientationSheet();
                  if (value == 'screenshot') _saveScreenshot();
                },
                itemBuilder: (_) => const [
                  PopupMenuItem(
                    value: 'speed',
                    child: Text('سرعة التشغيل'),
                  ),
                  PopupMenuItem(
                    value: 'view',
                    child: Text('طريقة عرض الفيديو'),
                  ),
                  PopupMenuItem(
                    value: 'orientation',
                    child: Text('اتجاه الشاشة'),
                  ),
                  PopupMenuItem(
                    value: 'tracks',
                    child: Text('الصوت والترجمة'),
                  ),
                  PopupMenuItem(
                    value: 'subtitle_style',
                    child: Text('إعدادات الترجمة'),
                  ),
                  PopupMenuItem(
                    value: 'screenshot',
                    child: Text('التقاط صورة'),
                  ),
                ],
              ),
            ],
          ),
        ),
        Center(
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              IconButton(
                color: Colors.white,
                iconSize: 34,
                onPressed: () => _seekBy(const Duration(seconds: -10)),
                icon: const Icon(Icons.replay_10_rounded),
              ),
              const SizedBox(width: 18),
              StreamBuilder<bool>(
                stream: _player.stream.playing,
                initialData: _player.state.playing,
                builder: (context, snapshot) {
                  final playing = snapshot.data ?? false;
                  return IconButton.filled(
                    iconSize: 44,
                    onPressed: () {
                      _player.playOrPause();
                      _showControls();
                    },
                    icon: Icon(
                      playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
                    ),
                  );
                },
              ),
              const SizedBox(width: 18),
              IconButton(
                color: Colors.white,
                iconSize: 34,
                onPressed: () => _seekBy(const Duration(seconds: 10)),
                icon: const Icon(Icons.forward_10_rounded),
              ),
            ],
          ),
        ),
        Align(
          alignment: Alignment.bottomCenter,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 8, 14, 8),
            child: StreamBuilder<Duration>(
              stream: _player.stream.position,
              initialData: _player.state.position,
              builder: (context, posSnapshot) {
                return StreamBuilder<Duration>(
                  stream: _player.stream.duration,
                  initialData: _player.state.duration,
                  builder: (context, durSnapshot) {
                    final position = posSnapshot.data ?? Duration.zero;
                    final duration = durSnapshot.data ?? _duration;
                    final maxMs = duration.inMilliseconds > 0
                        ? duration.inMilliseconds.toDouble()
                        : 1.0;
                    final displayPosition = _sliderPreview ?? position;
                    final value = displayPosition.inMilliseconds
                        .clamp(0, maxMs.toInt())
                        .toDouble();
                    return Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Slider(
                          value: value,
                          max: maxMs,
                          onChangeStart: (v) {
                            _hideTimer?.cancel();
                            setState(
                              () => _sliderPreview =
                                  Duration(milliseconds: v.round()),
                            );
                          },
                          onChanged: (v) {
                            setState(
                              () => _sliderPreview =
                                  Duration(milliseconds: v.round()),
                            );
                          },
                          onChangeEnd: (v) async {
                            final target = Duration(milliseconds: v.round());
                            setState(() => _sliderPreview = null);
                            await _fastSeek(target);
                            _showControls();
                          },
                        ),
                        Row(
                          children: [
                            Text(
                              _fmt(displayPosition),
                              style: const TextStyle(color: Colors.white),
                            ),
                            const Text(
                              ' / ',
                              style: TextStyle(color: Colors.white70),
                            ),
                            Text(
                              _fmt(duration),
                              style: const TextStyle(color: Colors.white70),
                            ),
                            const Spacer(),
                            TextButton(
                              onPressed: _showSpeedSheet,
                              child: Text(
                                '${_playbackRate.toStringAsFixed(_playbackRate == _playbackRate.roundToDouble() ? 0 : 2)}x',
                                style: const TextStyle(color: Colors.white),
                              ),
                            ),
                            IconButton(
                              tooltip: 'طريقة عرض الفيديو',
                              color: Colors.white,
                              onPressed: _showViewModeSheet,
                              icon: const Icon(Icons.aspect_ratio_rounded),
                            ),
                            IconButton(
                              tooltip: 'قفل الشاشة',
                              color: Colors.white,
                              onPressed: _lockControls,
                              icon: const Icon(Icons.lock_open_rounded),
                            ),
                          ],
                        ),
                        const Text(
                          'أفقي: تقديم/ترجيع • يسار: صوت • الوسط: التالي/السابق • يمين: سطوع • إصبعان: تكبير',
                          textAlign: TextAlign.center,
                          style: TextStyle(color: Colors.white54, fontSize: 10),
                        ),
                      ],
                    );
                  },
                );
              },
            ),
          ),
        ),
      ],
    );
  }
}
