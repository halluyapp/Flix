import 'package:flutter/material.dart';
import '../models/media_item.dart';
import '../services/tmdb_service.dart';
import '../widgets/media_card.dart';

class SearchScreen extends StatefulWidget {
  const SearchScreen({super.key});

  @override
  State<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends State<SearchScreen> {
  final TmdbService _tmdbService = TmdbService();
  final TextEditingController _controller = TextEditingController();
  List<MediaItem> _results = [];
  bool _isSearching = false;

  void _onSearch(String query) async {
    if (query.trim().isEmpty) {
      setState(() => _results = []);
      return;
    }
    setState(() => _isSearching = true);
    final res = await _tmdbService.search(query);
    if (mounted) {
      setState(() {
        _results = res;
        _isSearching = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF141414),
      appBar: AppBar(
        backgroundColor: const Color(0xFF1F1F1F),
        elevation: 0,
        title: TextField(
          controller: _controller,
          style: const TextStyle(color: Colors.white),
          cursorColor: const Color(0xFFE50914),
          decoration: InputDecoration(
            hintText: 'Search for movies, TV shows...',
            hintStyle: const TextStyle(color: Colors.white38, fontSize: 14),
            border: InputBorder.none,
            prefixIcon: const Icon(Icons.search, color: Colors.white54),
            suffixIcon: _controller.text.isNotEmpty
                ? IconButton(
                    icon: const Icon(Icons.clear, color: Colors.white54),
                    onPressed: () {
                      _controller.clear();
                      _onSearch('');
                    },
                  )
                : null,
          ),
          onChanged: _onSearch,
        ),
      ),
      body: _isSearching
          ? const Center(child: CircularProgressIndicator(color: Color(0xFFE50914)))
          : _results.isEmpty
              ? const Center(
                  child: Text('Search millions of movies and series', style: TextStyle(color: Colors.white38)),
                )
              : GridView.builder(
                  padding: const EdgeInsets.all(12),
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 3,
                    crossAxisSpacing: 8,
                    mainAxisSpacing: 10,
                    childAspectRatio: 0.68,
                  ),
                  itemCount: _results.length,
                  itemBuilder: (context, index) {
                    return MediaCard(item: _results[index]);
                  },
                ),
    );
  }
}
