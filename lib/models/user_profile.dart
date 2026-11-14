class UserProfile {
  final String id;
  final String name;
  final String avatarUrl;
  final bool isKids;

  UserProfile({
    required this.id,
    required this.name,
    required this.avatarUrl,
    this.isKids = false,
  });

  static List<UserProfile> get defaultProfiles => [
        UserProfile(
          id: '1',
          name: 'V-World',
          avatarUrl: 'https://assets.nflxext.com/ffe/siteui/vlv3/avatar-red.png',
        ),
        UserProfile(
          id: '2',
          name: 'Alex',
          avatarUrl: 'https://assets.nflxext.com/ffe/siteui/vlv3/avatar-blue.png',
        ),
        UserProfile(
          id: '3',
          name: 'Kids',
          avatarUrl: 'https://assets.nflxext.com/ffe/siteui/vlv3/avatar-kids.png',
          isKids: true,
        ),
      ];
}
