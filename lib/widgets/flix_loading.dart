import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Flix's local loading and buffering visuals.
///
/// These are rendered entirely by Flutter: no remote video, image or CDN
/// request is made, so they work offline and cost almost nothing on a low-end
/// device.
class FlixLoadingView extends StatelessWidget {
  final String message;
  final String? detail;

  const FlixLoadingView({
    super.key,
    required this.message,
    this.detail,
  });

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: Colors.black,
      child: Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const FlixWordmark(fontSize: 40),
              const SizedBox(height: 18),
              const FlixOrbitDots(size: 46, dotCount: 8),
              const SizedBox(height: 22),
              Text(
                message,
                textAlign: TextAlign.center,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                  height: 1.35,
                ),
              ),
              if (detail != null) ...[
                const SizedBox(height: 8),
                Text(
                  detail!,
                  textAlign: TextAlign.center,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Colors.white54,
                    fontSize: 12.5,
                    height: 1.45,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// The compact buffering indicator shown over an already-playing video.
class FlixBufferingIndicator extends StatelessWidget {
  final double size;

  const FlixBufferingIndicator({super.key, this.size = 34});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.45),
        borderRadius: BorderRadius.circular(10),
      ),
      child: FlixOrbitDots(size: size, dotCount: 8, dim: true),
    );
  }
}

class FlixWordmark extends StatelessWidget {
  final double fontSize;

  const FlixWordmark({super.key, this.fontSize = 34});

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: 'Flix',
      child: Text(
        'FLIX',
        style: TextStyle(
          color: const Color(0xFFE50914),
          fontSize: fontSize,
          fontWeight: FontWeight.w900,
          letterSpacing: fontSize * 0.06,
          height: 1,
        ),
      ),
    );
  }
}

/// Eight dots chasing around a circle, in the spirit of a streaming app's
/// loading mark. Driven by one low-cost animation controller.
class FlixOrbitDots extends StatefulWidget {
  final double size;
  final int dotCount;
  final bool dim;

  const FlixOrbitDots({
    super.key,
    this.size = 40,
    this.dotCount = 8,
    this.dim = false,
  });

  @override
  State<FlixOrbitDots> createState() => _FlixOrbitDotsState();
}

class _FlixOrbitDotsState extends State<FlixOrbitDots>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1150),
  )..repeat();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final count = widget.dotCount.clamp(3, 12);
    final radius = widget.size * 0.35;
    final dotSize = math.max(2.5, widget.size * 0.11);
    return Semantics(
      label: 'Loading',
      child: SizedBox(
        width: widget.size,
        height: widget.size,
        child: AnimatedBuilder(
          animation: _controller,
          builder: (context, _) {
            final progress = _controller.value * count;
            return Stack(
              alignment: Alignment.center,
              children: List.generate(count, (index) {
                final angle = (2 * math.pi * index) / count - math.pi / 2;
                final distance = (progress - index).abs();
                final wrapped = math.min(distance, count - distance);
                final opacity = (1 - (wrapped / count)).clamp(0.18, 1.0);
                return Transform.translate(
                  offset: Offset(
                    math.cos(angle) * radius,
                    math.sin(angle) * radius,
                  ),
                  child: Container(
                    width: dotSize,
                    height: dotSize,
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(
                        alpha: widget.dim ? opacity * 0.75 : opacity,
                      ),
                      shape: BoxShape.circle,
                    ),
                  ),
                );
              }),
            );
          },
        ),
      ),
    );
  }
}
