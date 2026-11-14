import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/media_item.dart';
import '../core/constants/api_constants.dart';
import '../services/tmdb_service.dart';
import '../services/user_state_service.dart';
import '../widgets/hero_billboard.dart';
import '../widgets/continue_watching_rail.dart';
import '../widgets/top_10_rail.dart';
import '../widgets/content_rail.dart';
import 'profile_screen.dart';

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
  List<MediaItem> _top10 = [];
  List<MediaItem> _topRated = [];
  List<MediaItem> _popularTv = [];
  List<MediaItem> _kdrama = [];
  List<MediaItem> _nollywood = [];
  List<MediaItem> _anime = [];

  @override
  void initState() {
    super.initState();
    _loadFeed();
  }

  Future<void> _loadFeed() async {
    try {
      final trendingFuture = _tmdbService.getTrending();
      final top10Future = _tmdbService.getTop10Today();
      final topRatedFuture = _tmdbService.getTopRated();
      final popularTvFuture = _tmdbService.getPopularTv();
      final kdramaFuture = _tmdbService.getKdramas();
      final nollywoodFuture = _tmdbService.getNollywood();
      final animeFuture = _tmdbService.getAnime();

      final results = await Future.wait([
        trendingFuture,
        top10Future,
        topRatedFuture,
        popularTvFuture,
        kdramaFuture,
        nollywoodFuture,
        animeFuture,
      ]);

      if (mounted) {
        setState(() {
          _trending = results[0];
          _top10 = results[1];
          _topRated = results[2];
          _popularTv = results[3];
          _kdrama = results[4];
          _nollywood = results[5];
          _anime = results[6];

          if (_trending.isNotEmpty) {
            _heroItem = _trending.first;
          }
          _isLoading = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _isLoading = false);
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
        backgroundColor: Colors.black.withValues(alpha: 0.5),
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
            GestureDetector(
              onTap: () {
                Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const ProfileScreen()),
                );
              },
              child: CircleAvatar(
                radius: 14,
                backgroundImage: NetworkImage(userState.currentProfile.avatarUrl),
              ),
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
              if (_isCatalogueEmpty) _buildEmptyCatalogue(),
              HeroBillboard(item: _heroItem),
              const SizedBox(height: 12),
              if (userState.continueWatching.isNotEmpty)
                ContinueWatchingRail(items: userState.continueWatching),
              if (_top10.isNotEmpty)
                Top10Rail(title: 'Top 10 Today', items: _top10),
              ContentRail(title: 'Trending Now', items: _trending),
              ContentRail(title: 'Popular on Flix', items: _popularTv),
              ContentRail(title: 'Korean Dramas', items: _kdrama),
              if (_nollywood.isNotEmpty)
                ContentRail(title: 'Nollywood Cinema', items: _nollywood),
              ContentRail(title: 'Anime Action', items: _anime),
              ContentRail(title: 'Critically Acclaimed', items: _topRated),
            ],
          ),
        ),
      ),
    );
  }

  bool get _isCatalogueEmpty =>
      _trending.isEmpty &&
      _topRated.isEmpty &&
      _popularTv.isEmpty &&
      _kdrama.isEmpty &&
      _nollywood.isEmpty &&
      _anime.isEmpty;

  Widget _buildEmptyCatalogue() {
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 96, 16, 8),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF1F1F1F),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xFF2B2B2B)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Catalogue unavailable',
            style: TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 6),
          Text(
            ApiConstants.hasTmdbCredentials
                ? 'TMDB could not be reached. Check your connection and pull to refresh.'
                : 'No TMDB credentials were compiled into this build. Rebuild with '
                    '--dart-define=TMDB_API_KEY=your_key to load the catalogue.',
            style: const TextStyle(color: Color(0xFFA3A3A3), fontSize: 12, height: 1.4),
          ),
        ],
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
