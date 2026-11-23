import 'dart:convert';

import 'package:http/http.dart' as http;

import '../core/constants/api_constants.dart';
import '../models/provider_clip.dart';
import 'moviebox_service.dart';

enum ClipsFeedSource { supabase, providerFallback }

class ClipsFeed {
  final List<ProviderClip> items;
  final ClipsFeedSource source;

  const ClipsFeed({required this.items, required this.source});
}

/// Loads the short-film feed through Flix's Supabase Edge Function first.
///
/// The provider fallback keeps Clips available during a Supabase outage. Both
/// paths run the same strict provider-metadata filter; neither path invents
/// catalogue entries. [ClipsFeed.source] lets the UI report which path served
/// the visible catalogue.
class ClipsService {
  final MovieBoxService _provider = MovieBoxService();

  Future<ClipsFeed> fetchShortFilms() async {
    final backendItems = await _fetchFromSupabase();
    if (backendItems != null && backendItems.isNotEmpty) {
      return ClipsFeed(items: backendItems, source: ClipsFeedSource.supabase);
    }
    return ClipsFeed(
      items: await _provider.searchShortFilms(),
      source: ClipsFeedSource.providerFallback,
    );
  }

  Future<List<ProviderClip>?> _fetchFromSupabase() async {
    try {
      final uri = Uri.parse('${ApiConstants.supabaseUrl}/functions/v1/clips-feed');
      final response = await http
          .get(uri, headers: const {'Accept': 'application/json'})
          .timeout(const Duration(seconds: 18));
      if (response.statusCode != 200) return null;

      final decoded = json.decode(response.body);
      final root = decoded is Map && decoded['data'] is Map ? decoded['data'] : decoded;
      final rawItems = root is Map ? root['items'] : root;
      if (rawItems is! List) return null;

      return rawItems
          .whereType<Map>()
          .map((raw) => ProviderClip.fromProviderJson(Map<String, dynamic>.from(raw)))
          .whereType<ProviderClip>()
          .toList();
    } catch (_) {
      return null;
    }
  }
}
