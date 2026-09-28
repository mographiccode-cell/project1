import 'package:photo_manager/photo_manager.dart';

class VideoItem {
  const VideoItem({
    required this.asset,
    required this.title,
    required this.folder,
    this.relativePath,
  });

  final AssetEntity asset;
  final String title;
  final String folder;
  final String? relativePath;

  String get id => asset.id;
  Duration get duration => Duration(seconds: asset.duration);
  DateTime? get createdAt => asset.createDateSecond == null
      ? null
      : DateTime.fromMillisecondsSinceEpoch(asset.createDateSecond! * 1000);
}
