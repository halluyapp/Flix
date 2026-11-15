import 'dart:async';

import 'package:flutter/material.dart';

import '../models/media_item.dart';
import '../services/tmdb_service.dart';
import '../widgets/media_card.dart';

const Color _accent = Color(0xFFE50914);

class SearchScreen extends StatefulWidget {
  const SearchScreen({super.key});

  @override
  State<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends State<SearchScreen> {
  static const Duration _debounceDelay = Duration(milliseconds: 350);

  final TmdbService _tmdbService = TmdbService();
  final TextEditingController _controller = TextEditingController();
  Timer? _debounce;
  List<MediaItem> _results = const [];
  bool _isSearching = false;
  bool _hasSearched = false;
  String? _error;
  int _requestId = 0;

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.dispose();
    super.dispose();
  }

  void _onQueryChanged(String value) {
    final query = value.trim();
    _debounce?.cancel();
    setState(() {
      _error = null;
      if (query.isEmpty) {
        _results = const [];
        _hasSearched = false;
        _isSearching = false;
      }
    });
    if (query.isEmpty) {
      // Invalidate any in-flight response so it cannot repopulate the grid.
      _requestId++;
      return;
    }
    setState(() => _isSearching = true);
    _debounce = Timer(_debounceDelay, () => unawaited(_runSearch(query)));
  }

  Future<void> _runSearch(String query) async {
    final requestId = ++_requestId;
    _tmdbService.resetSupabaseConnectionStatus();
    final results = await _tmdbService.search(query);
    // A newer query (or a cleared field) always wins over a slow older one.
    if (!mounted || requestId != _requestId) return;
    final failed = results.isEmpty && !_tmdbService.hasSuccessfulSupabaseResponse;
    setState(() {
      _results = results;
      _isSearching = false;
      _hasSearched = true;
      _error = failed
          ? 'Search is unavailable right now. Check your connection and try again.'
          : null;
    });
  }

  void _clear() {
    _debounce?.cancel();
    _controller.clear();
    _requestId++;
    setState(() {
      _results = const [];
      _isSearching = false;
      _hasSearched = false;
      _error = null;
    });
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
          cursorColor: _accent,
          textInputAction: TextInputAction.search,
          onChanged: _onQueryChanged,
          onSubmitted: (value) {
            _debounce?.cancel();
            final query = value.trim();
            if (query.isNotEmpty) {
              setState(() => _isSearching = true);
              unawaited(_runSearch(query));
            }
          },
          decoration: InputDecoration(
            hintText: 'Search movies and TV shows',
            hintStyle: const TextStyle(color: Colors.white38, fontSize: 14),
            border: InputBorder.none,
            prefixIcon: const Icon(Icons.search, color: Colors.white54),
            suffixIcon: _controller.text.isEmpty
                ? null
                : IconButton(
                    tooltip: 'Clear search',
                    icon: const Icon(Icons.clear, color: Colors.white54),
                    onPressed: _clear,
                  ),
          ),
        ),
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_isSearching && _results.isEmpty) {
      return const Center(
        child: CircularProgressIndicator(color: _accent),
      );
    }
    if (_error != null) {
      return _stateMessage(
        icon: Icons.cloud_off,
        title: 'Search unavailable',
        message: _error!,
        action: TextButton(
          onPressed: () {
            final query = _controller.text.trim();
            if (query.isNotEmpty) {
              setState(() => _isSearching = true);
              unawaited(_runSearch(query));
            }
          },
          child: const Text('Try again', style: TextStyle(color: _accent)),
        ),
      );
    }
    if (_results.isEmpty) {
      return _stateMessage(
        icon: Icons.search,
        title: _hasSearched ? 'No results' : 'Find something to watch',
        message: _hasSearched
            ? 'Nothing matched "${_controller.text.trim()}". Try a shorter '
                'title or the original language title.'
            : 'Search the TMDB catalogue for movies and series.',
      );
    }
    return GridView.builder(
      padding: const EdgeInsets.all(12),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        crossAxisSpacing: 8,
        mainAxisSpacing: 10,
        childAspectRatio: 0.68,
      ),
      itemCount: _results.length,
      itemBuilder: (context, index) => MediaCard(item: _results[index]),
    );
  }

  Widget _stateMessage({
    required IconData icon,
    required String title,
    required String message,
    Widget? action,
  }) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: Colors.white24, size: 46),
            const SizedBox(height: 14),
            Text(
              title,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 16,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              message,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: Colors.white54,
                fontSize: 13,
                height: 1.45,
              ),
            ),
            if (action != null) ...[const SizedBox(height: 10), action],
          ],
        ),
      ),
    );
  }
}
