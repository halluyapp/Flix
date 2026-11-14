import 'package:flutter/material.dart';
import '../models/media_item.dart';
import '../screens/detail_screen.dart';
import 'package:cached_network_image/cached_network_image.dart';

class Top10Rail extends StatelessWidget {
  final String title;
  final List<MediaItem> items;

  const Top10Rail({
    super.key,
    required this.title,
    required this.items,
  });

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) return const SizedBox.shrink();
    final top10 = items.take(10).toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          child: Text(
            title,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 18,
              fontWeight: FontWeight.bold,
            ),
          ),
        ),
        SizedBox(
          height: 180,
          child: ListView.builder(
            padding: const EdgeInsets.symmetric(horizontal: 14),
            scrollDirection: Axis.horizontal,
            itemCount: top10.length,
            itemBuilder: (context, index) {
              final item = top10[index];
              final rank = index + 1;

              return GestureDetector(
                onTap: () {
                  Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => DetailScreen(item: item)),
                  );
                },
                child: Container(
                  width: 140,
                  margin: const EdgeInsets.only(right: 6),
                  child: Stack(
                    children: [
                      Positioned(
                        left: 0,
                        bottom: -15,
                        child: Text(
                          '$rank',
                          style: TextStyle(
                            fontSize: 110,
                            fontWeight: FontWeight.w900,
                            color: Colors.transparent,
                            shadows: const [
                              Shadow(color: Color(0xFF666666), blurRadius: 1, offset: Offset(2, 2)),
                              Shadow(color: Color(0xFF222222), blurRadius: 4, offset: Offset(-2, -2)),
                            ],
                            foreground: Paint()
                              ..style = PaintingStyle.stroke
                              ..strokeWidth = 3
                              ..color = const Color(0xFF888888),
                          ),
                        ),
                      ),
                      Positioned(
                        right: 0,
                        top: 0,
                        bottom: 0,
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(6),
                          child: CachedNetworkImage(
                            imageUrl: item.posterUrl,
                            width: 100,
                            fit: BoxFit.cover,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}
