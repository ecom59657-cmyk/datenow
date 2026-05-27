import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';

/// Shared base for the Apple + Google sign-in buttons on AuthLanding.
///
/// Apple HIG-compliant ish: 52 dp tall, 14 dp radius, semibold label,
/// single-line with `TextOverflow.fade` so long French translations
/// ("Continuer avec Google") never wrap. A subtle press animation
/// (scale 0.97 + opacity 0.85, spring-back) + a light haptic make
/// each tap feel native rather than a Material button on iOS.
class _OAuthButton extends StatefulWidget {
  const _OAuthButton({
    required this.label,
    required this.onPressed,
    required this.backgroundColor,
    required this.foregroundColor,
    required this.icon,
    this.borderColor,
    this.shadowColor,
  });

  final String label;
  final VoidCallback? onPressed;
  final Color backgroundColor;
  final Color foregroundColor;
  final Widget icon;
  final Color? borderColor;
  final Color? shadowColor;

  @override
  State<_OAuthButton> createState() => _OAuthButtonState();
}

class _OAuthButtonState extends State<_OAuthButton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 120),
    reverseDuration: const Duration(milliseconds: 200),
    lowerBound: 0,
    upperBound: 1,
  );

  late final Animation<double> _scale = Tween<double>(
    begin: 1,
    end: 0.97,
  ).animate(CurvedAnimation(parent: _ctrl, curve: Curves.easeOut));

  late final Animation<double> _opacity = Tween<double>(
    begin: 1,
    end: 0.85,
  ).animate(CurvedAnimation(parent: _ctrl, curve: Curves.easeOut));

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  void _down(_) {
    if (widget.onPressed == null) return;
    _ctrl.forward();
  }

  void _up(_) {
    if (!_ctrl.isAnimating && _ctrl.value == 0) return;
    _ctrl.reverse();
  }

  void _cancel() => _up(null);

  void _tap() {
    if (widget.onPressed == null) return;
    HapticFeedback.lightImpact();
    widget.onPressed!();
  }

  @override
  Widget build(BuildContext context) {
    final disabled = widget.onPressed == null;
    return Semantics(
      button: true,
      enabled: !disabled,
      label: widget.label,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: _down,
        onTapUp: _up,
        onTapCancel: _cancel,
        onTap: _tap,
        child: AnimatedBuilder(
          animation: _ctrl,
          builder: (context, _) {
            return Transform.scale(
              scale: _scale.value,
              child: Opacity(
                opacity: disabled ? 0.55 : _opacity.value,
                child: Container(
                  height: 52,
                  decoration: BoxDecoration(
                    color: widget.backgroundColor,
                    borderRadius: BorderRadius.circular(14),
                    border: widget.borderColor == null
                        ? null
                        : Border.all(
                            color: widget.borderColor!,
                            width: 1,
                          ),
                    boxShadow: widget.shadowColor == null
                        ? null
                        : [
                            BoxShadow(
                              color: widget.shadowColor!,
                              blurRadius: 18,
                              spreadRadius: 0,
                              offset: const Offset(0, 6),
                            ),
                          ],
                  ),
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    mainAxisSize: MainAxisSize.max,
                    children: [
                      widget.icon,
                      const SizedBox(width: 10),
                      Flexible(
                        child: Text(
                          widget.label,
                          maxLines: 1,
                          overflow: TextOverflow.fade,
                          softWrap: false,
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: widget.foregroundColor,
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                            letterSpacing: -0.2,
                            height: 1.1,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

/// Apple-style "Continue with Apple" button. Pure black surface, white
/// Apple glyph from Material Icons.apple (close enough to the SF Symbol
/// mark at this size to feel native on iOS), subtle dark shadow for the
/// lift the official SignInWithAppleButton intentionally lacks.
class AppleSignInButton extends StatelessWidget {
  const AppleSignInButton({
    super.key,
    required this.label,
    required this.onPressed,
  });

  final String label;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return _OAuthButton(
      label: label,
      onPressed: onPressed,
      backgroundColor: Colors.black,
      foregroundColor: Colors.white,
      shadowColor: Colors.black.withValues(alpha: 0.28),
      icon: const Padding(
        // Optical alignment: the Apple glyph hangs a touch low without
        // this nudge — pulls the mark up so its visual centre sits on
        // the text baseline rather than the descender line.
        padding: EdgeInsets.only(bottom: 3),
        child: Icon(Icons.apple, color: Colors.white, size: 20),
      ),
    );
  }
}

/// Google-style "Continue with Google" button. Off-white surface with a
/// hairline border, real multi-coloured Google "G" mark drawn from the
/// official SVG paths (no asset bundling needed — paths are inlined).
class GoogleSignInButton extends StatelessWidget {
  const GoogleSignInButton({
    super.key,
    required this.label,
    required this.onPressed,
  });

  final String label;
  final VoidCallback? onPressed;

  // Apple HIG hint colours: the Google button on a dark surface reads
  // best as plain white. We hint a tiny warmth (off-white) only to
  // match the rest of the dark theme's elevated surfaces.
  static const Color _surface = Color(0xFFFFFFFF);
  static const Color _foreground = Color(0xFF1F1F1F);
  static const Color _border = Color(0x14000000);
  static const Color _shadow = Color(0x14000000);

  @override
  Widget build(BuildContext context) {
    return _OAuthButton(
      label: label,
      onPressed: onPressed,
      backgroundColor: _surface,
      foregroundColor: _foreground,
      borderColor: _border,
      shadowColor: _shadow,
      icon: const SizedBox(
        width: 18,
        height: 18,
        child: _GoogleGGlyph(),
      ),
    );
  }
}

/// Official Google "G" mark, inlined as an SVG string so we don't ship
/// an asset for a single icon. Source: Google identity brand pack —
/// the standard 4-colour G glyph (yellow/red/green/blue).
class _GoogleGGlyph extends StatelessWidget {
  const _GoogleGGlyph();

  static const String _svg = '''
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 48 48">
  <path fill="#FFC107" d="M43.611 20.083H42V20H24v8h11.303c-1.649 4.657-6.08 8-11.303 8-6.627 0-12-5.373-12-12s5.373-12 12-12c3.059 0 5.842 1.154 7.961 3.039l5.657-5.657C34.046 6.053 29.268 4 24 4 12.955 4 4 12.955 4 24s8.955 20 20 20 20-8.955 20-20c0-1.341-.138-2.65-.389-3.917z"/>
  <path fill="#FF3D00" d="M6.306 14.691l6.571 4.819C14.655 15.108 18.961 12 24 12c3.059 0 5.842 1.154 7.961 3.039l5.657-5.657C34.046 6.053 29.268 4 24 4 16.318 4 9.656 8.337 6.306 14.691z"/>
  <path fill="#4CAF50" d="M24 44c5.166 0 9.86-1.977 13.409-5.192l-6.19-5.238A11.91 11.91 0 0124 36c-5.202 0-9.619-3.317-11.283-7.946l-6.522 5.025C9.505 39.556 16.227 44 24 44z"/>
  <path fill="#1976D2" d="M43.611 20.083H42V20H24v8h11.303a12.04 12.04 0 01-4.087 5.571l.003-.002 6.19 5.238C36.971 39.205 44 34 44 24c0-1.341-.138-2.65-.389-3.917z"/>
</svg>
''';

  @override
  Widget build(BuildContext context) {
    return SvgPicture.string(_svg);
  }
}
