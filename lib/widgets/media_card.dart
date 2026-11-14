import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:shimmer/shimmer.dart';
import '../models/media_item.dart';
import '../screens/detail_screen.dart';

class MediaCard extends StatelessWidget {
  final MediaItem item;
  final double width;
  final double height;

  const MediaCard({
    super.key,
    required this.item,
    this.width = 110,
    this.height = 160,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () {
        Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => DetailScreen(item: item)),
        );
      },
      child: ClipRRect(
        borderRadius: BorderRadius.circular(6),
        child: CachedNetworkImage(
          imageUrl: item.posterUrl,
          width: width,
          height: height,
          fit: BoxFit.cover,
          placeholder: (context, url) => Shimmer.fromColors(
            baseColor: Colors.grey[900]!,
            highlightColor: Colors.grey[800]!,
            child: Container(width: width, height: height, color: Colors.black),
          ),
          errorWidget: (context, url, error) => Container(
            width: width,
            height: height,
            color: const Color(0xFF222222),
            child: const Icon(Icons.movie, color: Colors.white54),
          ),
        ),
      ),
    );
  }
}
