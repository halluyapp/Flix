import 'package:flutter/material.dart';

import '../models/caption_track.dart';
import '../models/offline_download.dart';
import '../models/stream_source.dart';

class PlayerMediaOptionsSheet extends StatelessWidget {
  final bool isOffline;
  final List<StreamSource> sources;
  final StreamSource? selectedSource;
  final List<CaptionTrack> captions;
  final CaptionTrack? selectedCaption;
  final List<OfflineSubtitle> offlineSubtitles;
  final OfflineSubtitle? selectedOfflineSubtitle;
  final VoidCallback onSubtitleOff;
  final ValueChanged<StreamSource> onQualitySelected;
  final ValueChanged<CaptionTrack> onCaptionSelected;
  final ValueChanged<OfflineSubtitle> onOfflineCaptionSelected;

  const PlayerMediaOptionsSheet({
    super.key,
    required this.isOffline,
    required this.sources,
    required this.selectedSource,
    required this.captions,
    required this.selectedCaption,
    required this.offlineSubtitles,
    required this.selectedOfflineSubtitle,
    required this.onSubtitleOff,
    required this.onQualitySelected,
    required this.onCaptionSelected,
    required this.onOfflineCaptionSelected,
  });

  @override
  Widget build(BuildContext context) {
    final subtitleOffSelected =
        isOffline ? selectedOfflineSubtitle == null : selectedCaption == null;
    return SafeArea(
      top: false,
      child: SizedBox(
        height: MediaQuery.of(context).size.height * 0.78,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(18, 14, 18, 18),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                  child: Container(
                      width: 38,
                      height: 4,
                      decoration: BoxDecoration(
                          color: Colors.white24,
                          borderRadius: BorderRadius.circular(4)))),
              const SizedBox(height: 16),
              const Text('Playback settings',
                  style: TextStyle(
                      color: Colors.white,
                      fontSize: 18,
                      fontWeight: FontWeight.w700)),
              const SizedBox(height: 14),
              Expanded(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text('VIDEO QUALITY',
                              style: TextStyle(
                                  color: Colors.white60,
                                  fontSize: 11,
                                  fontWeight: FontWeight.w800,
                                  letterSpacing: 1)),
                          const SizedBox(height: 8),
                          Expanded(
                            child: ListView(
                              children: [
                                if (sources.isEmpty)
                                  ListTile(
                                      dense: true,
                                      contentPadding: EdgeInsets.zero,
                                      title: Text(
                                          isOffline
                                              ? 'Saved offline'
                                              : 'No alternate versions available',
                                          style: const TextStyle(
                                              color: Colors.white70)))
                                else
                                  ...sources.map((source) {
                                    final selected =
                                        source.url == selectedSource?.url;
                                    return ListTile(
                                      dense: true,
                                      contentPadding: EdgeInsets.zero,
                                      title: Text(
                                          '${source.resolution} · ${source.format}',
                                          style: TextStyle(
                                              color: selected
                                                  ? const Color(0xFFE50914)
                                                  : Colors.white,
                                              fontWeight: selected
                                                  ? FontWeight.bold
                                                  : FontWeight.normal)),
                                      trailing: selected
                                          ? const Icon(Icons.check,
                                              color: Color(0xFFE50914))
                                          : null,
                                      onTap: () {
                                        Navigator.pop(context);
                                        onQualitySelected(source);
                                      },
                                    );
                                  }),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                    const VerticalDivider(color: Colors.white24, width: 24),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text('SUBTITLES',
                              style: TextStyle(
                                  color: Colors.white60,
                                  fontSize: 11,
                                  fontWeight: FontWeight.w800,
                                  letterSpacing: 1)),
                          const SizedBox(height: 8),
                          Expanded(
                            child: ListView(
                              children: [
                                ListTile(
                                  dense: true,
                                  contentPadding: EdgeInsets.zero,
                                  title: Text('Off',
                                      style: TextStyle(
                                          color: subtitleOffSelected
                                              ? const Color(0xFFE50914)
                                              : Colors.white,
                                          fontWeight: subtitleOffSelected
                                              ? FontWeight.bold
                                              : FontWeight.normal)),
                                  trailing: subtitleOffSelected
                                      ? const Icon(Icons.check,
                                          color: Color(0xFFE50914))
                                      : null,
                                  onTap: () {
                                    Navigator.pop(context);
                                    onSubtitleOff();
                                  },
                                ),
                                if (isOffline)
                                  ...offlineSubtitles.map((subtitle) {
                                    final selected = subtitle.path ==
                                        selectedOfflineSubtitle?.path;
                                    return ListTile(
                                      dense: true,
                                      contentPadding: EdgeInsets.zero,
                                      title: Text(subtitle.languageName,
                                          style: TextStyle(
                                              color: selected
                                                  ? const Color(0xFFE50914)
                                                  : Colors.white,
                                              fontWeight: selected
                                                  ? FontWeight.bold
                                                  : FontWeight.normal)),
                                      trailing: selected
                                          ? const Icon(Icons.check,
                                              color: Color(0xFFE50914))
                                          : null,
                                      onTap: () {
                                        Navigator.pop(context);
                                        onOfflineCaptionSelected(subtitle);
                                      },
                                    );
                                  })
                                else
                                  ...captions.map((caption) {
                                    final selected =
                                        caption.id == selectedCaption?.id;
                                    return ListTile(
                                      dense: true,
                                      contentPadding: EdgeInsets.zero,
                                      title: Text(caption.languageName,
                                          style: TextStyle(
                                              color: selected
                                                  ? const Color(0xFFE50914)
                                                  : Colors.white,
                                              fontWeight: selected
                                                  ? FontWeight.bold
                                                  : FontWeight.normal)),
                                      trailing: selected
                                          ? const Icon(Icons.check,
                                              color: Color(0xFFE50914))
                                          : null,
                                      onTap: () {
                                        Navigator.pop(context);
                                        onCaptionSelected(caption);
                                      },
                                    );
                                  }),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
