import 'dart:io';

import 'package:photo_manager/photo_manager.dart';

import '../models/video_item.dart';

class MediaLibraryService {
  Future<PermissionState> requestPermission() {
    return PhotoManager.requestPermissionExtend();
  }

  Future<List<VideoItem>> loadVideos({int limit = 5000}) async {
    final permission = await requestPermission();
    if (!permission.isAuth && !permission.hasAccess) return const [];

    final paths = await PhotoManager.getAssetPathList(
      hasAll: false,
      onlyAll: false,
      type: RequestType.video,
      filterOption: FilterOptionGroup(
        orders: const [
          OrderOption(type: OrderOptionType.createDate, asc: false),
        ],
      ),
    );

    final unique = <String, VideoItem>{};

    for (final path in paths) {
      if (unique.length >= limit) break;
      final count = await path.assetCountAsync;
      if (count == 0) continue;
      final relativePath = await path.relativePathAsync;
      var page = 0;
      while (page * 250 < count && unique.length < limit) {
        final assets = await path.getAssetListPaged(page: page, size: 250);
        if (assets.isEmpty) break;
        for (final asset in assets) {
          final title = (asset.title ?? '').trim().isEmpty
              ? 'فيديو بدون اسم'
              : asset.title!.trim();
          unique.putIfAbsent(
            asset.id,
            () => VideoItem(
              asset: asset,
              title: title,
              folder:
                  path.name.trim().isEmpty ? 'مجلد غير معروف' : path.name.trim(),
              relativePath: relativePath,
            ),
          );
          if (unique.length >= limit) break;
        }
        page++;
      }
    }

    if (unique.isEmpty) {
      final all = await PhotoManager.getAssetPathList(
        onlyAll: true,
        type: RequestType.video,
      );
      if (all.isNotEmpty) {
        final path = all.first;
        final count = await path.assetCountAsync;
        var page = 0;
        while (page * 250 < count && unique.length < limit) {
          final assets = await path.getAssetListPaged(page: page, size: 250);
          if (assets.isEmpty) break;
          for (final asset in assets) {
            final title = (asset.title ?? '').trim().isEmpty
                ? 'فيديو بدون اسم'
                : asset.title!.trim();
            unique[asset.id] = VideoItem(
              asset: asset,
              title: title,
              folder: 'كل الفيديوهات',
            );
            if (unique.length >= limit) break;
          }
          page++;
        }
      }
    }

    final result = unique.values.toList();
    result.sort((a, b) {
      final ad = a.createdAt ?? DateTime.fromMillisecondsSinceEpoch(0);
      final bd = b.createdAt ?? DateTime.fromMillisecondsSinceEpoch(0);
      return bd.compareTo(ad);
    });
    return result;
  }

  Future<File?> resolveFile(VideoItem item) async {
    return await item.asset.originFile ?? await item.asset.file;
  }

  Future<bool> renameVideo(VideoItem item, String requestedName) async {
    final raw = requestedName.trim();
    if (raw.isEmpty) return false;

    final current = item.title.trim();
    final lastDot = current.lastIndexOf('.');
    final extension = lastDot > 0 && lastDot < current.length - 1
        ? current.substring(lastDot)
        : '';
    final hasExtension = raw.lastIndexOf('.') > 0;
    final newTitle = hasExtension || extension.isEmpty ? raw : '$raw$extension';

    return PhotoManager.editor.android.renameAsset(
      entity: item.asset,
      newTitle: newTitle,
    );
  }

  Future<List<String>> moveToTrash(VideoItem item) {
    return PhotoManager.editor.android.moveToTrash(<AssetEntity>[item.asset]);
  }

  Future<List<String>> restoreFromTrash(VideoItem item) {
    return PhotoManager.editor.android.restoreFromTrash(<AssetEntity>[item.asset]);
  }

  Future<void> openSettings() => PhotoManager.openSetting();
}
