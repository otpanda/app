import 'package:flutter_svg/flutter_svg.dart';
import 'package:material_ui/material_ui.dart';

import 'service_directory.dart';

/// The 36px rounded tile used on code tiles and entry rows. Cosmetic only: a
/// logo from the 2FA Directory when the service name matches one catalogue
/// row exactly (trimmed, case-folded, never a substring), else the first
/// letter. A familiar logo is not a verified identity and never feeds
/// autofill or code release. The letter shows first and stays on any
/// failure, so the tile never changes size when a logo arrives.
class ServiceAvatar extends StatefulWidget {
  final String service;

  /// Immutable scanned issuer, separate from the editable display name.
  final String? issuer;

  /// Persisted identity, when the entry has one. Wins over the label.
  final String? serviceId, websiteHost;
  final Color color;
  final Color ink;
  final double fontSize;
  final ServiceDirectory? directory;
  const ServiceAvatar({
    super.key,
    required this.service,
    this.issuer,
    this.serviceId,
    this.websiteHost,
    required this.color,
    required this.ink,
    this.fontSize = 14,
    this.directory,
  });
  @override
  State<ServiceAvatar> createState() => _ServiceAvatarState();
}

class _ServiceAvatarState extends State<ServiceAvatar> {
  ServiceDirectory get _dir => widget.directory ?? ServiceDirectory.instance;
  LogoImage? _logo;
  String? _wanted;
  int _gen = 0;

  @override
  void initState() {
    super.initState();
    _dir.addListener(_resolve);
    _dir.ensureLoaded();
    _resolve();
  }

  @override
  void didUpdateWidget(ServiceAvatar old) {
    super.didUpdateWidget(old);
    if (old.service != widget.service ||
        old.issuer != widget.issuer ||
        old.serviceId != widget.serviceId ||
        old.websiteHost != widget.websiteHost ||
        old.directory != widget.directory) {
      if (old.directory != widget.directory) {
        (old.directory ?? ServiceDirectory.instance).removeListener(_resolve);
        _dir.addListener(_resolve);
        _dir.ensureLoaded();
      }
      _logo = null;
      _wanted = null;
      _resolve();
    }
  }

  @override
  void dispose() {
    _dir.removeListener(_resolve);
    super.dispose();
  }

  void _resolve() {
    final icon = _dir
        .resolve(
          serviceId: widget.serviceId,
          host: widget.websiteHost,
          name: widget.issuer ?? widget.service,
        )
        ?.icon;
    if (icon == null || icon == _wanted) return;
    _wanted = icon;
    final cached = _dir.cachedLogo(icon);
    if (cached != null) {
      _logo = cached;
      return;
    }
    final gen = ++_gen;
    _dir.logo(icon).then((l) {
      if (!mounted || gen != _gen || l == null) return;
      setState(() => _logo = l);
    });
  }

  @override
  Widget build(BuildContext context) {
    final logo = _logo;
    return Container(
      width: 36,
      height: 36,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: logo != null ? Colors.white : widget.color,
        borderRadius: BorderRadius.circular(10),
      ),
      child: logo != null ? _image(logo) : _letter(),
    );
  }

  Widget _letter() => Text(
    widget.service.isEmpty ? '?' : widget.service[0].toUpperCase(),
    style: TextStyle(
      fontWeight: FontWeight.w800,
      fontSize: widget.fontSize,
      color: widget.ink,
    ),
  );

  Widget _image(LogoImage logo) {
    Widget fallback(BuildContext _, [Object? e, StackTrace? s]) => _letter();
    return Padding(
      padding: const EdgeInsets.all(6),
      child: ExcludeSemantics(
        child: logo.kind == LogoKind.svg
            ? SvgPicture.memory(
                logo.bytes,
                width: 24,
                height: 24,
                fit: BoxFit.contain,
                errorBuilder: (c, e, s) => fallback(c),
              )
            : Image.memory(
                logo.bytes,
                width: 24,
                height: 24,
                cacheWidth: 72,
                fit: BoxFit.contain,
                filterQuality: FilterQuality.medium,
                gaplessPlayback: true,
                errorBuilder: (c, e, s) => fallback(c),
              ),
      ),
    );
  }
}
