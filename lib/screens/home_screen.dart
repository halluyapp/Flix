import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/media_item.dart';
import '../services/tmdb_service.dart';
import '../services/user_state_service.dart';
import '../widgets/hero_billboard.dart';
import '../widgets/continue_watching_rail.dart';
import '../widgets/top_10_rail.dart';
import '../widgets/content_rail.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final TmdbService _tmdbService = TmdbService();
  bool _isLoading = true;

  MediaItem? _heroItem;
  List<MediaItem> _trending = [];
  List<MediaItem> _topRated = [];
  List<MediaItem> _popularTv = [];
  List<MediaItem> _actionMovies = [];
  List<MediaItem> _kDrama = [];

  @override
  void initState() {
    super.initState();
    _loadFeed();
  }

  Future<void> _loadFeed() async {
    try {
      final trendingFuture = _tmdbService.getTrending();
      final topRatedFuture = _tmdbService.getTopRated();
      final popularTvFuture = _tmdbService.getPopularTv();
      final actionFuture = _tmdbService.getByGenre(28); // 28 = Action
      final dramaFuture = _tmdbService.getByGenre(18, isTv: true); // 18 = Drama

      final results = await Future.wait([
        trendingFuture,
        topRatedFuture,
        popularTvFuture,
        actionFuture,
        dramaFuture,
      ]);

      setState(() {
        _trending = results[0];
        _topRated = results[1];
        _popularTv = results[2];
        _actionMovies = results[3];
        _kDrama = results[4];
        if (_trending.isNotEmpty) {
          _heroItem = _trending.first;
        }
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
        body: Center(
          child: CircularProgressIndicator(color: Color(0xFFE50914)),
        ),
      );
    }

    final userState = Provider.of<UserStateService>(context);

    return Scaffold(
      backgroundColor: const Color(0xFF141414),
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        backgroundColor: Colors.black.withOpacity(0.5),
        elevation: 0,
        title: Row(
          children: [
            const Text(
              'FLIX',
              style: TextStyle(
                color: Color(0xFFE50914),
                fontWeight: FontWeight.w900,
                fontSize: 26,
                letterSpacing: 2,
              ),
            ),
            const Spacer(),
            IconButton(
              icon: const Icon(Icons.cast, color: Colors.white, size: 22),
              onPressed: () {},
            ),
            const SizedBox(width: 4),
            CircleAvatar(
              radius: 14,
              backgroundImage: NetworkImage(userState.currentProfile.avatarUrl),
            ),
          ],
        ),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(34),
          child: Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                _buildFilterChip('TV Shows'),
                _buildFilterChip('Movies'),
                _buildFilterChip('Categories ▾'),
              ],
            ),
          ),
        ),
      ),
      body: RefreshIndicator(
        color: const Color(0xFFE50914),
        backgroundColor: const Color(0xFF1F1F1F),
        onRefresh: _loadFeed,
        child: SingleChildScrollView(
          padding: const EdgeInsets.only(bottom: 40),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              HeroBillboard(item: _heroItem),
              const SizedBox(height: 12),
              ContinueWatchingRail(items: userState.continueWatching),
              Top10Rail(title: 'Top 10 in Movies Today', items: _trending),
              ContentRail(title: 'Trending Now', items: _trending),
              ContentRail(title: 'Popular on Flix', items: _popularTv),
              ContentRail(title: 'Critically Acclaimed', items: _topRated),
              ContentRail(title: 'Action & Adventure', items: _actionMovies),
              ContentRail(title: 'Compelling TV Dramas', items: _kDrama),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildFilterChip(String label) {
    return GestureDetector(
      onTap: () {},
      child: Text(
        label,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 13,
          fontWeight: FontWeight.w500,
        ),
      ),
    );
  }
}
