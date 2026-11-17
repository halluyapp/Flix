import 'package:flutter_test/flutter_test.dart';
import 'package:flix/services/player_gesture_logic.dart';

void main() {
  group('PlayerGestureLogic.seekTarget', () {
    const duration = Duration(minutes: 10);

    test('moves forward for a right swipe', () {
      final target = PlayerGestureLogic.seekTarget(
        start: const Duration(minutes: 2),
        horizontalDelta: 100,
        screenWidth: 400,
        duration: duration,
      );
      expect(target, const Duration(minutes: 5, seconds: 45));
    });

    test('moves backward for a left swipe', () {
      final target = PlayerGestureLogic.seekTarget(
        start: const Duration(minutes: 5),
        horizontalDelta: -100,
        screenWidth: 400,
        duration: duration,
      );
      expect(target, const Duration(minutes: 1, seconds: 15));
    });

    test('clamps at both ends of the media', () {
      expect(
        PlayerGestureLogic.seekTarget(
          start: Duration.zero,
          horizontalDelta: -20,
          screenWidth: 400,
          duration: duration,
        ),
        Duration.zero,
      );
      expect(
        PlayerGestureLogic.seekTarget(
          start: duration,
          horizontalDelta: 20,
          screenWidth: 400,
          duration: duration,
        ),
        duration,
      );
    });

    test('returns zero for unusable geometry or duration', () {
      expect(
        PlayerGestureLogic.seekTarget(
          start: const Duration(seconds: 10),
          horizontalDelta: 10,
          screenWidth: 0,
          duration: duration,
        ),
        Duration.zero,
      );
      expect(
        PlayerGestureLogic.seekTarget(
          start: const Duration(seconds: 10),
          horizontalDelta: 10,
          screenWidth: 100,
          duration: Duration.zero,
        ),
        Duration.zero,
      );
    });
  });
}
