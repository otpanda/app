import 'package:material_ui/material_ui.dart';

import 'google_g.dart';

/// Light-theme "Continue with Google" button following
/// https://developers.google.com/identity/branding-guidelines (custom button):
/// fill #FFFFFF, 1px inside stroke #747775, text #1F1F1F, 14/20 Google Sans Medium (OFL, bundled),
/// 12px left padding, 10px after the logo, 12px right padding, standard
/// colour "G" on white at fixed size. Font: Google Sans (SIL OFL 1.1,
/// https://github.com/google/fonts/tree/main/ofl/googlesans).
class GoogleSignInButton extends StatelessWidget {
  final VoidCallback? onPressed;
  final String label;
  final bool loading;
  const GoogleSignInButton({
    super.key,
    required this.onPressed,
    this.label = 'Continue with Google',
    this.loading = false,
  });

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    label: label,
    child: Material(
      color: Colors.white,
      shape: const StadiumBorder(side: BorderSide(color: Color(0xff747775))),
      child: InkWell(
        customBorder: const StadiumBorder(),
        onTap: onPressed,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 48),
          child: Padding(
            padding: const EdgeInsets.only(left: 12, right: 12),
            child: Opacity(
              opacity: onPressed == null && !loading ? 0.38 : 1,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (loading)
                    const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        semanticsLabel: 'Signing in with Google',
                      ),
                    )
                  else
                    Image.memory(googleGImage, width: 20, height: 20),
                  const SizedBox(width: 10),
                  Flexible(
                    child: Text(
                      label,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontFamily: 'GoogleSans',
                        fontVariations: [FontVariation('wght', 500)],
                        color: Color(0xff1F1F1F),
                        fontSize: 14,
                        height: 20 / 14,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    ),
  );
}
