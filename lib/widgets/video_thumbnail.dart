import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:photo_manager/photo_manager.dart';

class VideoThumbnail extends StatelessWidget {
  const VideoThumbnail({
    super.key,
    required this.asset,
    this.width = 148,
    this.height = 92,
    this.radius = 16,
  });

  final AssetEntity asset;
  final double width;
  final double height;
  final double radius;

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<Uint8List?>(
      future: asset.thumbnailDataWithSize(
        const ThumbnailSize(480, 300),
        quality: 82,
      ),
      builder: (context, snapshot) {
        final data = snapshot.data;
        return ClipRRect(
          borderRadius: BorderRadius.circular(radius),
          child: SizedBox(
            width: width,
            height: height,
            child: data == null
                ? ColoredBox(
                    color: Theme.of(context).colorScheme.surfaceContainerHighest,
                    child: const Icon(Icons.movie_outlined, size: 36),
                  )
                : Image.memory(data, fit: BoxFit.cover),
          ),
        );
      },
    );
  }
}
