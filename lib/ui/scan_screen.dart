import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../l10n/app_localizations.dart';

/// Scans a share link or subscription URL from a QR code.
///
/// Pops with the decoded string, or null if the user backs out. Deliberately does
/// not import anything itself: the caller knows whether it asked for a server or a
/// subscription, and keeping that decision there avoids guessing from the text.
class ScanScreen extends StatefulWidget {
  const ScanScreen({super.key});

  @override
  State<ScanScreen> createState() => _ScanScreenState();
}

class _ScanScreenState extends State<ScanScreen> {
  final MobileScannerController _controller = MobileScannerController(
    formats: const [BarcodeFormat.qrCode],
    detectionSpeed: DetectionSpeed.noDuplicates,
  );

  /// A QR code is detected many times a second; without this the screen would try
  /// to pop repeatedly and the first result would race the rest.
  bool _handled = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _onDetect(BarcodeCapture capture) {
    if (_handled) return;
    final value = capture.barcodes
        .map((barcode) => barcode.rawValue)
        .firstWhere((raw) => raw != null && raw.trim().isNotEmpty, orElse: () => null);
    if (value == null) return;
    _handled = true;
    Navigator.of(context).pop(value.trim());
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.scanTitle),
        actions: [
          IconButton(
            icon: const Icon(Icons.flashlight_on_outlined),
            tooltip: l10n.torch,
            onPressed: _controller.toggleTorch,
          ),
        ],
      ),
      body: Stack(
        fit: StackFit.expand,
        children: [
          MobileScanner(
            controller: _controller,
            onDetect: _onDetect,
            errorBuilder: (context, error) => Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Text(
                  l10n.cameraUnavailable(error.errorCode.name),
                  textAlign: TextAlign.center,
                ),
              ),
            ),
          ),
          IgnorePointer(
            child: Center(
              child: Container(
                width: 240,
                height: 240,
                decoration: BoxDecoration(
                  border: Border.all(color: Colors.white70, width: 2),
                  borderRadius: BorderRadius.circular(16),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
