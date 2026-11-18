/// Pure seek math shared by the player gesture recognizer and unit tests.
class PlayerGestureLogic {
  const PlayerGestureLogic._();

  /// Maps horizontal pixels to a proportional seek within the media duration.
  /// A full screen-width swipe covers 1.5 media durations; callers may tune the
  /// multiplier without introducing extra seek calls during the gesture.
  static Duration seekTarget({
    required Duration start,
    required double horizontalDelta,
    required double screenWidth,
    required Duration duration,
  }) {
    if (screenWidth <= 0 || duration <= Duration.zero) return Duration.zero;
    final offset = (horizontalDelta * duration.inMilliseconds /
            screenWidth *
            1.5)
        .round();
    final target = (start.inMilliseconds + offset)
        .clamp(0, duration.inMilliseconds)
        .toInt();
    return Duration(milliseconds: target);
  }
}
