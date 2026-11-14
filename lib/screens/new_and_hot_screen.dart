import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../models/media_item.dart';
import '../services/tmdb_service.dart';
import 'detail_screen.dart';

class NewAndHotScreen extends StatefulWidget {
  const NewAndHotScreen({super.key});

  @override
  State<NewAndHotScreen> createState() => _NewAndHotScreenState();
}

class _NewAndHotScreenState extends State<NewAndHotScreen> {
  final TmdbService _tmdbService = TmdbService();
  List<MediaItem> _items = [];
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadItems();
  }

  Future<void> _loadItems() async {
    try {
      final res = await _tmdbService.getPopularMovies();
      setState(() {
        _items = res;
        _isLoading = false;
      });
    } catch (_) {
      setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return const Scaffold(
        backgroundColor: Color(0xFF141414),
        body: Center(child: CircularProgressIndicator(color: Color(0xFFE50914))),
      );
    }

    return Scaffold(
      backgroundColor: const Color(0xFF141414),
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        title: const Text(
          'New & Hot',
          style: TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.bold),
        ),
      ),
      body: ListView.builder(
        itemCount: _items.length,
        itemBuilder: (context, index) {
          final item = _items[index];
          return GestureDetector(
            onTap: () {
              Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => DetailScreen(item: item)),
              );
            },
            child: Container(
              margin: const EdgeInsets.only(bottom: 24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  CachedNetworkImage(
                    imageUrl: item.backdropUrl,
                    height: 200,
                    width: double.infinity,
                    fit: BoxFit.cover,
                  ),
                  Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          item.title,
                          style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          item.overview,
                          maxLines: 3,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(color: Colors.white70, fontSize: 13),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}
