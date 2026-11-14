import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:share_plus/share_plus.dart';
import '../models/media_item.dart';
import '../services/tmdb_service.dart';
import 'detail_screen.dart';

class NewAndHotScreen extends StatefulWidget {
  const NewAndHotScreen({super.key});

  @override
  State<NewAndHotScreen> createState() => _NewAndHotScreenState();
}

class _NewAndHotScreenState extends State<NewAndHotScreen> with SingleTickerProviderStateMixin {
  final TmdbService _tmdbService = TmdbService();
  late TabController _tabController;
  List<MediaItem> _comingSoon = [];
  List<MediaItem> _everyonesWatching = [];
  bool _isLoading = true;
  final Set<int> _remindedIds = {};

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    _loadItems();
  }

  Future<void> _loadItems() async {
    try {
      final upcomingFuture = _tmdbService.getUpcoming();
      final trendingFuture = _tmdbService.getTrending();
      final results = await Future.wait([upcomingFuture, trendingFuture]);

      if (mounted) {
        setState(() {
          _comingSoon = results[0];
          _everyonesWatching = results[1];
          _isLoading = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  void _toggleRemindMe(int id) {
    setState(() {
      if (_remindedIds.contains(id)) {
        _remindedIds.remove(id);
      } else {
        _remindedIds.add(id);
      }
    });
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
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
        backgroundColor: Colors.black.withOpacity(0.8),
        elevation: 0,
        title: const Text(
          'New & Hot',
          style: TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.bold),
        ),
        bottom: TabBar(
          controller: _tabController,
          indicatorColor: const Color(0xFFE50914),
          indicatorWeight: 3,
          labelColor: Colors.white,
          unselectedLabelColor: Colors.white54,
          tabs: const [
            Tab(icon: Icon(Icons.celebration_outlined), text: 'Coming Soon'),
            Tab(icon: Icon(Icons.local_fire_department_outlined), text: "Everyone's Watching"),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabController,
        children: [
          _buildFeedList(_comingSoon, isUpcoming: true),
          _buildFeedList(_everyonesWatching, isUpcoming: false),
        ],
      ),
    );
  }

  Widget _buildFeedList(List<MediaItem> items, {required bool isUpcoming}) {
    if (items.isEmpty) {
      return const Center(
        child: Text('No titles available right now.', style: TextStyle(color: Colors.white38)),
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: 16),
      itemCount: items.length,
      itemBuilder: (context, index) {
        final item = items[index];
        final isReminded = _remindedIds.contains(item.id);

        return GestureDetector(
          onTap: () {
            Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => DetailScreen(item: item)),
            );
          },
          child: Container(
            margin: const EdgeInsets.only(bottom: 28),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Stack(
                  children: [
                    CachedNetworkImage(
                      imageUrl: item.backdropUrl,
                      height: 200,
                      width: double.infinity,
                      fit: BoxFit.cover,
                    ),
                    if (isUpcoming && item.releaseDate.isNotEmpty)
                      Positioned(
                        top: 12,
                        left: 12,
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                          decoration: BoxDecoration(
                            color: Colors.black87,
                            borderRadius: BorderRadius.circular(4),
                            border: Border.all(color: const Color(0xFFE50914)),
                          ),
                          child: Text(
                            'Arriving ${item.releaseDate}',
                            style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.bold),
                          ),
                        ),
                      ),
                  ],
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Expanded(
                            child: Text(
                              item.title,
                              style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          Row(
                            children: [
                              IconButton(
                                icon: Icon(
                                  isReminded ? Icons.notifications_active : Icons.notifications_none,
                                  color: isReminded ? const Color(0xFFE50914) : Colors.white70,
                                  size: 24,
                                ),
                                onPressed: () => _toggleRemindMe(item.id),
                              ),
                              IconButton(
                                icon: const Icon(Icons.share, color: Colors.white70, size: 22),
                                onPressed: () {
                                  Share.share('Watch ${item.title} on Flix! https://flix.app/title/${item.id}');
                                },
                              ),
                            ],
                          ),
                        ],
                      ),
                      const SizedBox(height: 6),
                      Text(
                        item.overview,
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(color: Colors.white70, fontSize: 13, height: 1.4),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
