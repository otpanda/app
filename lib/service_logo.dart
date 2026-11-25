import 'package:material_ui/material_ui.dart';

import 'device_brand_icon.dart';

/// Cosmetic only. Maps an entry's service name to a bundled mark from the
/// closed set already shipped for the device list. The match is exact on the
/// trimmed, lower-cased name, never a substring search. A familiar mark is not
/// a verified identity: it never feeds autofill or code release.
///
/// "Mozilla" uses the Firefox mark because the catalog lists the Mozilla
/// account service at accounts.firefox.com (Firefox Accounts).
DeviceBrand? serviceBrandFor(String? service) {
  if (service == null) return null;
  const aliases = <String, DeviceBrand>{
    'mozilla': DeviceBrand.firefox,
    'mozilla account': DeviceBrand.firefox,
    'firefox': DeviceBrand.firefox,
    'firefox account': DeviceBrand.firefox,
    'firefox accounts': DeviceBrand.firefox,
    'mozilla firefox': DeviceBrand.firefox,
    'opera': DeviceBrand.opera,
    'brave': DeviceBrand.brave,
    'apple': DeviceBrand.apple,
    'apple id': DeviceBrand.apple,
  };
  return aliases[service.trim().toLowerCase()];
}

/// The 36px rounded tile used on code tiles and entry rows: a mark when the
/// service resolves, else the first letter.
class ServiceAvatar extends StatelessWidget {
  final String service;
  final Color color;
  final Color ink;
  final double fontSize;
  const ServiceAvatar({
    super.key,
    required this.service,
    required this.color,
    required this.ink,
    this.fontSize = 14,
  });
  @override
  Widget build(BuildContext context) {
    final brand = serviceBrandFor(service);
    return Container(
      width: 36,
      height: 36,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(10),
      ),
      child: brand != null
          ? IconTheme(
              data: IconThemeData(color: ink),
              child: DeviceBrandIcon(brand: brand, size: 20),
            )
          : Text(
              service.isEmpty ? '?' : service[0].toUpperCase(),
              style: TextStyle(
                fontWeight: FontWeight.w800,
                fontSize: fontSize,
                color: ink,
              ),
            ),
    );
  }
}
