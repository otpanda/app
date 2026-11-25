import 'package:material_ui/material_ui.dart';
import 'package:otpanda_client/device_brand_icon.dart';

void main() => runApp(
  MaterialApp(
    home: Scaffold(
      backgroundColor: Colors.white,
      body: Center(
        child: Wrap(
          spacing: 20,
          runSpacing: 20,
          children: [
            for (final b in DeviceBrand.values)
              Column(
                children: [
                  IconTheme(
                    data: const IconThemeData(color: Color(0xFF1B6B4A)),
                    child: DeviceBrandIcon(brand: b, size: 64),
                  ),
                  Text(b.name),
                ],
              ),
            const Column(
              children: [
                DeviceBrandIcon(
                  brand: null,
                  fallback: Icons.language,
                  size: 64,
                ),
                Text('fallback'),
              ],
            ),
          ],
        ),
      ),
    ),
  ),
);
