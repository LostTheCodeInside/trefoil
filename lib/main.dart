import 'package:dynamic_color/dynamic_color.dart';
import 'package:flutter/material.dart';

import 'l10n/app_localizations.dart';

import 'core/tunnel_controller.dart';
import 'ui/app_shell.dart';

void main() {
  runApp(const TrefoilApp());
}

/// Exposes the single [TunnelController] to the widget tree.
///
/// An [InheritedNotifier] rather than a package: there is exactly one controller and
/// one place it is created, so the ceremony of a DI container would not buy anything.
///
/// [changes] is what dependents are rebuilt by, and defaults to the controller. A
/// tab that is out of sight passes a relay it holds back, so the controller is the
/// same everywhere but only the screens being looked at rebuild (see AppShell).
class TunnelScope extends InheritedNotifier<Listenable> {
  const TunnelScope({
    super.key,
    required this.controller,
    Listenable? changes,
    required super.child,
  }) : super(notifier: changes ?? controller);

  final TunnelController controller;

  static TunnelController of(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<TunnelScope>();
    assert(scope != null, 'No TunnelScope above this widget');
    return scope!.controller;
  }

  /// For callbacks that only need to *call* the controller. Using this instead of
  /// [of] avoids subscribing the widget to every state change it does not render.
  static TunnelController read(BuildContext context) =>
      context.getInheritedWidgetOfExactType<TunnelScope>()!.controller;
}

class TrefoilApp extends StatefulWidget {
  const TrefoilApp({super.key});

  @override
  State<TrefoilApp> createState() => _TrefoilAppState();
}

class _TrefoilAppState extends State<TrefoilApp> {
  final TunnelController _controller = TunnelController();

  @override
  void initState() {
    super.initState();
    _controller.init();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return TunnelScope(
      controller: _controller,
      // Android 12+ exposes a palette derived from the wallpaper. Using it where it
      // exists makes the app look like part of the system; the brand colour stays the
      // fallback everywhere else, including on the launcher icon, which cannot follow
      // the wallpaper.
      //
      // Listening to the locale alone, rather than to the whole controller, is what
      // keeps this cheap. Rebuilding here rebuilds `MaterialApp` and with it every
      // route below it; the controller changes for all sorts of reasons that have no
      // bearing on the app's theme or language.
      child: ValueListenableBuilder<ThemeMode>(
        valueListenable: _controller.themeModeListenable,
        builder: (context, themeMode, _) => ValueListenableBuilder<Locale?>(
          valueListenable: _controller.localeListenable,
          builder: (context, locale, _) => DynamicColorBuilder(
            builder: (lightDynamic, darkDynamic) => MaterialApp(
              onGenerateTitle: (context) => AppLocalizations.of(context).appTitle,
              debugShowCheckedModeBanner: false,
              theme: _theme(Brightness.light, lightDynamic),
              darkTheme: _theme(Brightness.dark, darkDynamic),
              themeMode: themeMode,
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              // Null follows the device language, which is what most people want and
              // what a fresh install gets.
              locale: locale,
              home: const AppShell(),
            ),
          ),
        ),
      ),
    );
  }

  static const _brandSeed = Color(0xFF4C5FD5);

  /// Built once. Deriving a scheme from a seed runs the whole Material colour
  /// algorithm, and the seed is a compile-time constant, so there is nothing to
  /// recompute -- but it used to be recomputed on every rebuild of this widget.
  static final _brandLight = ColorScheme.fromSeed(seedColor: _brandSeed);
  static final _brandDark = ColorScheme.fromSeed(
    seedColor: _brandSeed,
    brightness: Brightness.dark,
  );

  static ThemeData _theme(Brightness brightness, ColorScheme? dynamicScheme) {
    // harmonized() nudges the wallpaper palette toward the brand hue, so accents stay
    // recognisably this app rather than becoming whatever the wallpaper happens to be.
    final scheme =
        dynamicScheme?.harmonized() ?? (brightness == Brightness.light ? _brandLight : _brandDark);
    return ThemeData(
      colorScheme: scheme,
      useMaterial3: true,
      scaffoldBackgroundColor: scheme.surface,
      appBarTheme: AppBarTheme(
        backgroundColor: scheme.surface,
        surfaceTintColor: scheme.surfaceTint,
        centerTitle: false,
      ),
      cardTheme: CardThemeData(
        elevation: 0,
        color: scheme.surfaceContainerLow,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        clipBehavior: Clip.antiAlias,
      ),
      listTileTheme: const ListTileThemeData(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(12))),
      ),
      inputDecorationTheme: const InputDecorationTheme(border: OutlineInputBorder()),
    );
  }
}
