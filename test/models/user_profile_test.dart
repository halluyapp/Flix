import 'package:flutter_test/flutter_test.dart';
import 'package:flix/models/user_profile.dart';

void main() {
  group('UserProfile Model Tests', () {
    test('verifies correct PIN and rejects incorrect PIN with SHA-256', () {
      final pinHash = UserProfile.hashPin('1234');
      final profile = UserProfile(
        id: 'p1',
        name: 'Adult Profile',
        avatarUrl: 'https://example.com/avatar.png',
        pinHash: pinHash,
      );

      expect(profile.hasPin, true);
      expect(profile.verifyPin('1234'), true);
      expect(profile.verifyPin('9999'), false);
    });

    test('profile with no PIN allows instant access', () {
      final profile = UserProfile(
        id: 'p2',
        name: 'Open Profile',
        avatarUrl: 'https://example.com/avatar.png',
      );

      expect(profile.hasPin, false);
      expect(profile.verifyPin(''), true);
    });

    test('serializes and deserializes from JSON accurately', () {
      final profile = UserProfile(
        id: 'p3',
        name: 'Kids Club',
        avatarUrl: 'https://example.com/kids.png',
        isKids: true,
      );

      final json = profile.toJson();
      final reconstituted = UserProfile.fromJson(json);

      expect(reconstituted.id, 'p3');
      expect(reconstituted.name, 'Kids Club');
      expect(reconstituted.isKids, true);
    });
  });
}
