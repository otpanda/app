import 'package:material_ui/material_ui.dart';

/// A thin bar along the bottom edge of a code tile that empties from right to
/// left over the code's remaining lifetime. Give it a key that changes with
/// the code's period so a new code restarts it full. Each rebuild re-derives
/// the target from [remainingMs] (one second ahead), so a paused or resumed
/// clock cannot leave it lagging. Decorative: excluded from semantics, and
/// still (coarsely quantised) when the system asks to reduce motion.
class RefreshBar extends StatelessWidget {
  const RefreshBar({
    super.key,
    required this.remainingMs,
    required this.periodMs,
    this.color = const Color(0xff0a7955),
  });
  final int remainingMs, periodMs;
  final Color color;

  /// Fraction of the period left after [ms] milliseconds from now.
  double _fraction(int ms) => periodMs <= 0
      ? 0.0
      : ((remainingMs - ms) / periodMs).clamp(0.0, 1.0).toDouble();

  @override
  Widget build(BuildContext context) {
    final remaining = remainingMs < 0 ? 0 : remainingMs;
    final still = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    Widget bar(double f) => Align(
      alignment: Alignment.centerLeft,
      child: FractionallySizedBox(
        widthFactor: f,
        child: ColoredBox(color: color, child: const SizedBox(height: 3)),
      ),
    );
    final lead = remaining < 1000 ? remaining : 1000;
    return ExcludeFocus(
      child: ExcludeSemantics(
        child: RepaintBoundary(
          child: SizedBox(
            height: 3,
            child: still || remaining == 0
                ? bar((_fraction(0) * 100).floorToDouble() / 100)
                : TweenAnimationBuilder<double>(
                    tween: Tween<double>(
                      begin: _fraction(0),
                      end: _fraction(lead),
                    ),
                    duration: Duration(milliseconds: lead),
                    curve: Curves.linear,
                    builder: (_, f, _) => bar(f),
                  ),
          ),
        ),
      ),
    );
  }
}
