import 'dart:convert';
import 'package:crypto/crypto.dart';

class UserProfile {
  final String id;
  final String name;
  final String avatarUrl;
  final bool isKids;
  final String? pinHash;
  final String language;

  UserProfile({
    required this.id,
    required this.name,
    required this.avatarUrl,
    this.isKids = false,
    this.pinHash,
    this.language = 'en',
  });

  bool get hasPin => pinHash != null && pinHash!.isNotEmpty;

  bool verifyPin(String enteredPin) {
    if (!hasPin) return true;
    final hash = sha256.convert(utf8.encode(enteredPin)).toString();
    return hash == pinHash;
  }

  static String hashPin(String rawPin) {
    return sha256.convert(utf8.encode(rawPin)).toString();
  }

  factory UserProfile.fromJson(Map<String, dynamic> json) {
    return UserProfile(
      id: (json['id'] ?? '1').toString(),
      name: (json['name'] ?? 'Viewer').toString(),
      avatarUrl: (json['avatar_url'] ?? json['avatarUrl'] ?? defaultAvatars.first).toString(),
      isKids: json['is_kids'] == true || json['isKids'] == true,
      pinHash: json['pin_hash'] ?? json['pinHash'],
      language: (json['language'] ?? 'en').toString(),
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'avatar_url': avatarUrl,
    'is_kids': isKids,
    'pin_hash': pinHash,
    'language': language,
  };

  static List<String> get defaultAvatars => [
    'https://assets.nflxext.com/ffe/siteui/vlv3/avatar-red.png',
    'https://assets.nflxext.com/ffe/siteui/vlv3/avatar-blue.png',
    'https://assets.nflxext.com/ffe/siteui/vlv3/avatar-yellow.png',
    'https://assets.nflxext.com/ffe/siteui/vlv3/avatar-kids.png',
    'https://assets.nflxext.com/ffe/siteui/vlv3/avatar-purple.png',
  ];

  static List<UserProfile> get defaultProfiles => [
    UserProfile(
      id: '1',
      name: 'V-World',
      avatarUrl: defaultAvatars[0],
    ),
    UserProfile(
      id: '2',
      name: 'Alex',
      avatarUrl: defaultAvatars[1],
    ),
    UserProfile(
      id: '3',
      name: 'Kids',
      avatarUrl: defaultAvatars[3],
      isKids: true,
    ),
  ];
}
