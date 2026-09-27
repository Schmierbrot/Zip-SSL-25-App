import 'dart:async';
import 'dart:ui';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import 'ble/zip_client.dart';
import 'core/haptics.dart';
import 'core/providers.dart';
import 'core/theme.dart';
import 'core/toast.dart';
import 'core/zip_session.dart';
import 'data/zip_data_source.dart';
import 'features/dashboard/dashboard_screen.dart';
import 'features/dashboard/temperature_warning.dart';
import 'features/lights/lights_screen.dart';
import 'features/settings/settings_screen.dart';
import 'features/trips/trips_screen.dart';

class ZipApp extends StatelessWidget {
  const ZipApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Zip',
      debugShowCheckedModeBanner: false,
      theme: buildZipTheme(),
      darkTheme: buildZipTheme(),
      themeMode: ThemeMode.dark,
      scaffoldMessengerKey: scaffoldMessengerKey,
      locale: const Locale('de', 'DE'),
      supportedLocales: const [Locale('de', 'DE')],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      scrollBehavior: const _ZipScrollBehavior(),
      home: const AnnotatedRegion<SystemUiOverlayStyle>(
        value: SystemUiOverlayStyle(
          statusBarColor: Colors.transparent,
          statusBarIconBrightness: Brightness.light,
          statusBarBrightness: Brightness.dark,
          systemNavigationBarColor: ZipColors.background,
          systemNavigationBarIconBrightness: Brightness.light,
        ),
        child: RootShell(),
      ),
    );
  }
}

/// iOS-artiges Scrollen (federnd, ohne Glow) auf allen Plattformen.
class _ZipScrollBehavior extends MaterialScrollBehavior {
  const _ZipScrollBehavior();

  @override
  ScrollPhysics getScrollPhysics(BuildContext context) => const BouncingScrollPhysics();

  @override
  Widget buildOverscrollIndicator(BuildContext context, Widget child, ScrollableDetails details) =>
      child;
}

class _Tab {
  const _Tab(this.label, this.icon, this.activeIcon);

  final String label;
  final IconData icon;
  final IconData activeIcon;
}

const _tabs = [
  _Tab('Dashboard', CupertinoIcons.speedometer, CupertinoIcons.speedometer),
  _Tab('Fahrten', CupertinoIcons.map, CupertinoIcons.map_fill),
  _Tab('Licht', CupertinoIcons.lightbulb, CupertinoIcons.lightbulb_fill),
  _Tab('Einstellungen', CupertinoIcons.gear_alt, CupertinoIcons.gear_alt_fill),
];

/// Tab-Navigation, App-Lebenszyklus, Wakelock und globale Hinweise.
class RootShell extends ConsumerStatefulWidget {
  const RootShell({super.key});

  @override
  ConsumerState<RootShell> createState() => _RootShellState();
}

class _RootShellState extends ConsumerState<RootShell> {
  int _index = 0;
  bool _foreground = true;
  bool? _wakelockOn;
  late final AppLifecycleListener _lifecycle;

  StreamSubscription<ZipNotice>? _noticeSub;

  @override
  void initState() {
    super.initState();
    _lifecycle = AppLifecycleListener(onStateChange: _onLifecycle);
    _subscribeNotices(ref.read(zipClientProvider));
  }

  /// Einmalige Hinweise direkt vom Stream – auch zweimal derselbe Hinweis
  /// (z. B. erneut fehlgeschlagene Kopplung) soll angezeigt werden.
  void _subscribeNotices(ZipClient client) {
    unawaited(_noticeSub?.cancel());
    _noticeSub = client.notices.listen((notice) {
      final isError = notice.kind != ZipNoticeKind.info;
      if (isError) unawaited(Haptics.error());
      showToast(notice.message, isError: isError);
    });
  }

  @override
  void dispose() {
    unawaited(_noticeSub?.cancel());
    _lifecycle.dispose();
    unawaited(WakelockPlus.disable().catchError((Object _) {}));
    super.dispose();
  }

  void _onLifecycle(AppLifecycleState state) {
    final foreground = state == AppLifecycleState.resumed;
    if (foreground == _foreground) return;
    _foreground = foreground;
    ref.read(dataSourceProvider).setForeground(foreground);
    _updateWakelock();
  }

  /// Bildschirm nur auf dem Dashboard und nur bei Verbindung anlassen.
  void _updateWakelock() {
    final on = _foreground && _index == 0 && ref.read(linkStateProvider).isConnected;
    if (on == _wakelockOn) return;
    _wakelockOn = on;
    unawaited(
      WakelockPlus.toggle(enable: on).catchError((Object e) {
        debugPrint('Wakelock nicht verfügbar: $e');
      }),
    );
  }

  void _select(int index) {
    if (index == _index) return;
    unawaited(Haptics.selection());
    setState(() => _index = index);
    _updateWakelock();
  }

  @override
  Widget build(BuildContext context) {
    // Diese Provider sollen unabhängig vom sichtbaren Tab leben.
    ref.watch(zipSessionProvider);
    ref.watch(temperatureWarningProvider);

    ref.listen(linkStateProvider.select((s) => s.isConnected), (_, _) => _updateWakelock());

    ref.listen(temperatureWarningProvider.select((w) => w.active), (previous, active) {
      if (active && previous != true) unawaited(Haptics.warning());
    });

    // Neue Datenquelle (Demo an/aus) → Hinweise des neuen Clients abonnieren.
    ref.listen(zipClientProvider, (_, client) => _subscribeNotices(client));

    // Wechsel des Demo-Modus erzeugt eine neue Datenquelle → Vordergrund mitteilen.
    ref.listen(dataSourceProvider, (_, source) => source.setForeground(_foreground));

    return Scaffold(
      extendBody: true,
      backgroundColor: ZipColors.background,
      body: IndexedStack(
        index: _index,
        children: const [DashboardScreen(), TripsScreen(), LightsScreen(), SettingsScreen()],
      ),
      bottomNavigationBar: _ZipTabBar(index: _index, onSelect: _select),
    );
  }
}

/// Tab-Leiste im iOS-Stil: durchscheinend mit Hintergrund-Blur, dünne Icons,
/// aktiver Tab rot.
class _ZipTabBar extends StatelessWidget {
  const _ZipTabBar({required this.index, required this.onSelect});

  final int index;
  final ValueChanged<int> onSelect;

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.paddingOf(context).bottom;
    return ClipRect(
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
        child: DecoratedBox(
          decoration: const BoxDecoration(
            color: ZipColors.tabBar,
            border: Border(top: BorderSide(color: ZipColors.separator, width: 0.5)),
          ),
          child: Padding(
            padding: EdgeInsets.only(bottom: bottom > 0 ? bottom : ZipSpacing.xs),
            child: SizedBox(
              height: kZipTabBarHeight,
              child: Row(
                children: [
                  for (var i = 0; i < _tabs.length; i++)
                    Expanded(
                      child: _TabItem(tab: _tabs[i], active: i == index, onTap: () => onSelect(i)),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _TabItem extends StatelessWidget {
  const _TabItem({required this.tab, required this.active, required this.onTap});

  final _Tab tab;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final color = active ? ZipColors.accent : ZipColors.textSecondary;
    return Semantics(
      selected: active,
      button: true,
      label: tab.label,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            AnimatedSwitcher(
              duration: ZipMotion.fast,
              child: Icon(
                active ? tab.activeIcon : tab.icon,
                key: ValueKey(active),
                color: color,
                size: 25,
              ),
            ),
            const SizedBox(height: 3),
            AnimatedDefaultTextStyle(
              duration: ZipMotion.fast,
              style: ZipText.inter(size: 10, weight: FontWeight.w500, color: color),
              child: Text(tab.label, maxLines: 1, overflow: TextOverflow.fade, softWrap: false),
            ),
          ],
        ),
      ),
    );
  }
}
