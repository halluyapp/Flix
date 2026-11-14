import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:provider/provider.dart';
import '../models/media_item.dart';
import '../models/episode.dart';
import '../services/tmdb_service.dart';
import '../services/user_state_service.dart';
import '../widgets/content_rail.dart';
import 'player_screen.dart';

class DetailScreen extends StatefulWidget {
  final MediaItem item;

  const DetailScreen({super.key, required this.item});

  @override
  State<DetailScreen> createState() => _DetailScreenState();
}

class _DetailScreenState extends State<DetailScreen> with SingleTickerProviderStateMixin {
  final TmdbService _tmdbService = TmdbService();
  late TabController _tabController;
  List<Episode> _episodes = [];
  List<MediaItem> _similar = [];
  int _selectedSeason = 1;
  bool _isLoadingEpisodes = false;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: widget.item.mediaType == 'tv' ? 2 : 1, vsync: this);
    _loadData();
  }

  Future<void> _loadData() async {
    if (widget.item.mediaType == 'tv') {
      _loadSeasonEpisodes(1);
    }
    try {
      final sim = await _tmdbService.getByGenre(
        widget.item.genreIds.isNotEmpty ? widget.item.genreIds.first : 28,
        isTv: widget.item.mediaType == 'tv',
      );
      if (mounted) setState(() => _similar = sim);
    } catch (_) {}
  }

  Future<void> _loadSeasonEpisodes(int season) async {
    setState(() => _isLoadingEpisodes = true);
    try {
      final eps = await _tmdbService.getSeasonEpisodes(widget.item.id, season);
      if (mounted) {
        setState(() {
          _episodes = eps;
          _selectedSeason = season;
          _isLoadingEpisodes = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _isLoadingEpisodes = false);
    }
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final userState = Provider.of<UserStateService>(context);
    final inMyList = userState.isInMyList(widget.item);

    return Scaffold(
      backgroundColor: const Color(0xFF141414),
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        actions: [
          IconButton(
            icon: const Icon(Icons.cast, color: Colors.white),
            onPressed: () {},
          ),
          IconButton(
            icon: const Icon(Icons.close, color: Colors.white),
            onPressed: () => Navigator.of(context).pop(),
          ),
        ],
      ),
      body: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Backdrop
            Stack(
              alignment: Alignment.center,
              children: [
                CachedNetworkImage(
                  imageUrl: widget.item.backdropUrl,
                  height: 220,
                  width: double.infinity,
                  fit: BoxFit.cover,
                ),
                Container(
                  height: 220,
                  color: Colors.black.withOpacity(0.35),
                ),
                GestureDetector(
                  onTap: () {
                    Navigator.of(context).push(
                      MaterialPageRoute(builder: (_) => PlayerScreen(item: widget.item)),
                    );
                  },
                  child: Container(
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: Colors.black.withOpacity(0.6),
                      shape: BoxShape.circle,
                      border: Border.all(color: Colors.white, width: 2),
                    ),
                    child: const Icon(Icons.play_arrow, color: Colors.white, size: 36),
                  ),
                ),
              ],
            ),
            Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    widget.item.title,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 22,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Text(
                        '${widget.item.matchScore}% Match',
                        style: const TextStyle(
                          color: Color(0xFF46D369),
                          fontWeight: FontWeight.bold,
                          fontSize: 13,
                        ),
                      ),
                      const SizedBox(width: 10),
                      Text(
                        '${widget.item.releaseYear}',
                        style: const TextStyle(color: Colors.white70, fontSize: 13),
                      ),
                      const SizedBox(width: 10),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                        decoration: BoxDecoration(
                          color: const Color(0xFF333333),
                          borderRadius: BorderRadius.circular(2),
                        ),
                        child: const Text('18+', style: TextStyle(color: Colors.white, fontSize: 10)),
                      ),
                      const SizedBox(width: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                        decoration: BoxDecoration(
                          color: const Color(0xFF333333),
                          borderRadius: BorderRadius.circular(2),
                        ),
                        child: const Text('Ultra HD 4K', style: TextStyle(color: Colors.white, fontSize: 10)),
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),
                  // Play Button
                  SizedBox(
                    width: double.infinity,
                    height: 44,
                    child: ElevatedButton.icon(
                      onPressed: () {
                        Navigator.of(context).push(
                          MaterialPageRoute(builder: (_) => PlayerScreen(item: widget.item)),
                        );
                      },
                      icon: const Icon(Icons.play_arrow, color: Colors.black, size: 26),
                      label: const Text(
                        'Play',
                        style: TextStyle(color: Colors.black, fontSize: 16, fontWeight: FontWeight.bold),
                      ),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.white,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  // Download Button
                  SizedBox(
                    width: double.infinity,
                    height: 44,
                    child: ElevatedButton.icon(
                      onPressed: () {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('Download started...')),
                        );
                      },
                      icon: const Icon(Icons.download, color: Colors.white, size: 22),
                      label: const Text(
                        'Download',
                        style: TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.w600),
                      ),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF262626),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
                      ),
                    ),
                  ),
                  const SizedBox(height: 14),
                  Text(
                    widget.item.overview,
                    style: const TextStyle(color: Colors.white, fontSize: 13, height: 1.4),
                  ),
                  const SizedBox(height: 18),
                  // Action Row
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceAround,
                    children: [
                      GestureDetector(
                        onTap: () => userState.toggleMyList(widget.item),
                        child: Column(
                          children: [
                            Icon(inMyList ? Icons.check : Icons.add, color: Colors.white, size: 26),
                            const SizedBox(height: 4),
                            Text(inMyList ? 'In List' : 'My List', style: const TextStyle(color: Colors.white70, fontSize: 11)),
                          ],
                        ),
                      ),
                      const Column(
                        children: [
                          Icon(Icons.thumb_up_alt_outlined, color: Colors.white, size: 24),
                          SizedBox(height: 4),
                          Text('Rate', style: TextStyle(color: Colors.white70, fontSize: 11)),
                        ],
                      ),
                      const Column(
                        children: [
                          Icon(Icons.share, color: Colors.white, size: 24),
                          SizedBox(height: 4),
                          Text('Share', style: TextStyle(color: Colors.white70, fontSize: 11)),
                        ],
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const Divider(color: Color(0xFF2B2B2B), thickness: 1),
            // Episodes / More Like This Tab
            if (widget.item.mediaType == 'tv') ...[
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 14),
                child: Row(
                  children: [
                    DropdownButton<int>(
                      value: _selectedSeason,
                      dropdownColor: const Color(0xFF1F1F1F),
                      underline: const SizedBox.shrink(),
                      icon: const Icon(Icons.arrow_drop_down, color: Colors.white),
                      style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold),
                      items: List.generate(
                        5,
                        (index) => DropdownMenuItem(
                          value: index + 1,
                          child: Text('Season ${index + 1}'),
                        ),
                      ),
                      onChanged: (val) {
                        if (val != null) _loadSeasonEpisodes(val);
                      },
                    ),
                  ],
                ),
              ),
              if (_isLoadingEpisodes)
                const Center(child: Padding(padding: EdgeInsets.all(20), child: CircularProgressIndicator(color: Color(0xFFE50914))))
              else
                ListView.builder(
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  itemCount: _episodes.length,
                  itemBuilder: (context, index) {
                    final ep = _episodes[index];
                    return ListTile(
                      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                      leading: ClipRRect(
                        borderRadius: BorderRadius.circular(4),
                        child: CachedNetworkImage(
                          imageUrl: ep.thumbnail,
                          width: 100,
                          height: 60,
                          fit: BoxFit.cover,
                        ),
                      ),
                      title: Text(
                        '${ep.episodeNumber}. ${ep.name}',
                        style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.bold),
                      ),
                      subtitle: Text(
                        '${ep.runtime}m',
                        style: const TextStyle(color: Colors.white54, fontSize: 11),
                      ),
                      trailing: IconButton(
                        icon: const Icon(Icons.download_for_offline_outlined, color: Colors.white70),
                        onPressed: () {},
                      ),
                      onTap: () {
                        Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) => PlayerScreen(
                              item: widget.item,
                              startSeason: ep.seasonNumber,
                              startEpisode: ep.episodeNumber,
                            ),
                          ),
                        );
                      },
                    );
                  },
                ),
            ],
            const SizedBox(height: 10),
            ContentRail(title: 'More Like This', items: _similar),
            const SizedBox(height: 30),
          ],
        ),
      ),
    );
  }
}
