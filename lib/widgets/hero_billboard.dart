import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:provider/provider.dart';
import '../models/media_item.dart';
import '../services/user_state_service.dart';
import '../screens/detail_screen.dart';
import '../screens/player_screen.dart';

class HeroBillboard extends StatelessWidget {
  final MediaItem? item;

  const HeroBillboard({super.key, this.item});

  @override
  Widget build(BuildContext context) {
    if (item == null) {
      return Container(
        height: 440,
        color: const Color(0xFF141414),
      );
    }

    final userState = Provider.of<UserStateService>(context);
    final inMyList = userState.isInMyList(item!);

    return Stack(
      children: [
        CachedNetworkImage(
          imageUrl: item!.backdropUrl,
          height: 480,
          width: double.infinity,
          fit: BoxFit.cover,
        ),
        Container(
          height: 480,
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                Colors.black.withValues(alpha: 0.3),
                Colors.transparent,
                const Color(0xFF141414).withValues(alpha: 0.8),
                const Color(0xFF141414),
              ],
              stops: const [0.0, 0.4, 0.8, 1.0],
            ),
          ),
        ),
        Positioned(
          left: 16,
          right: 16,
          bottom: 12,
          child: Column(
            children: [
              Text(
                item!.title.toUpperCase(),
                textAlign: TextAlign.center,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 26,
                  fontWeight: FontWeight.w900,
                  letterSpacing: 1.1,
                ),
              ),
              const SizedBox(height: 6),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color: const Color(0xFFE50914),
                      borderRadius: BorderRadius.circular(2),
                    ),
                    child: const Text(
                      'TOP 10',
                      style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: Colors.white),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    '#1 in Movies Today • ${item!.releaseYear}',
                    style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w600),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  GestureDetector(
                    onTap: () => userState.toggleMyList(item!),
                    child: Column(
                      children: [
                        Icon(
                          inMyList ? Icons.check : Icons.add,
                          color: Colors.white,
                          size: 26,
                        ),
                        const SizedBox(height: 4),
                        Text(
                          inMyList ? 'In List' : 'My List',
                          style: const TextStyle(color: Colors.white70, fontSize: 11),
                        ),
                      ],
                    ),
                  ),
                  ElevatedButton.icon(
                    onPressed: () {
                      Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => PlayerScreen(item: item!),
                        ),
                      );
                    },
                    icon: const Icon(Icons.play_arrow, color: Colors.black, size: 26),
                    label: const Text(
                      'Play',
                      style: TextStyle(
                        color: Colors.black,
                        fontWeight: FontWeight.bold,
                        fontSize: 15,
                      ),
                    ),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(horizontal: 26, vertical: 10),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(4),
                      ),
                    ),
                  ),
                  GestureDetector(
                    onTap: () {
                      Navigator.of(context).push(
                        MaterialPageRoute(builder: (_) => DetailScreen(item: item!)),
                      );
                    },
                    child: const Column(
                      children: [
                        Icon(Icons.info_outline, color: Colors.white, size: 26),
                        SizedBox(height: 4),
                        Text('Info', style: TextStyle(color: Colors.white70, fontSize: 11)),
                      ],
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }
}
