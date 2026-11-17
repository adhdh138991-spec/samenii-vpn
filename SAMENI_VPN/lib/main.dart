import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_v2ray/flutter_v2ray.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const SameniVpnApp());
}

class SameniVpnApp extends StatelessWidget {
  const SameniVpnApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'SAMENI VPN',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFFD71935),
          brightness: Brightness.dark,
        ),
        scaffoldBackgroundColor: const Color(0xFF0B0D12),
        appBarTheme: const AppBarTheme(backgroundColor: Color(0xFF10131B), foregroundColor: Colors.white),
        cardTheme: const CardThemeData(color: Color(0xFF151923), elevation: 2),
        useMaterial3: true,
      ),
      home: const VpnHomePage(),
    );
  }
}

class ConfigItem {
  final String url;
  int? delay;
  ConfigItem({required this.url, this.delay});
}

class VpnHomePage extends StatefulWidget {
  const VpnHomePage({super.key});

  @override
  State<VpnHomePage> createState() => _VpnHomePageState();
}

class _VpnHomePageState extends State<VpnHomePage> {
  late final FlutterV2ray _v2ray;
  final List<ConfigItem> _configs = [];
  ConfigItem? _selected;
  bool _initializing = true;
  bool _connecting = false;
  bool _connected = false;
  bool _testing = false;
  String _status = 'قطع';
  String _log = '';
  String _subUrl = '';

  @override
  void initState() {
    super.initState();
    _v2ray = FlutterV2ray(
      onStatusChanged: (status) {
        if (!mounted) return;
        final s = status.toString();
        setState(() {
          _status = s;
          final lower = s.toLowerCase();
          _connected =
              lower.contains('connected') && !lower.contains('disconnected');
        });
      },
      onLog: (log) {
        if (!mounted) return;
        setState(() => _log = log);
      },
    );
    _init();
  }

  Future<void> _init() async {
    try {
      await _v2ray.initializeV2Ray();
      final prefs = await SharedPreferences.getInstance();
      _subUrl = prefs.getString('sub_url') ?? '';
      if (_subUrl.isNotEmpty) {
        await _loadConfigs();
      }
    } catch (e) {
      _snack('خطا در راه‌اندازی: $e');
    } finally {
      if (mounted) setState(() => _initializing = false);
    }
  }

  Future<void> _loadConfigs() async {
    if (_subUrl.isEmpty) {
      _snack('ابتدا از تنظیمات، لینک اشتراک را وارد کنید');
      return;
    }

    final all = <ConfigItem>[];
    try {
      final res = await http
          .get(Uri.parse(_subUrl))
          .timeout(const Duration(seconds: 20));
      if (res.statusCode != 200) {
        _snack('خطای دریافت: ${res.statusCode}');
        return;
      }

      String body = res.body.trim();

      // اگر Base64 بود، دیکد کن
      if (!body.contains('://')) {
        try {
          body = utf8.decode(base64.decode(base64.normalize(body)));
        } catch (_) {}
      }

      for (final line in const LineSplitter().convert(body)) {
        final t = line.trim();
        if (t.startsWith('vmess://') ||
            t.startsWith('vless://') ||
            t.startsWith('trojan://') ||
            t.startsWith('ss://')) {
          all.add(ConfigItem(url: t));
        }
      }

      final map = {for (final c in all) c.url: c};
      if (!mounted) return;
      setState(() {
        _configs
          ..clear()
          ..addAll(map.values);
      });
      _snack('${_configs.length} کانفیگ بارگذاری شد');
    } catch (e) {
      _snack('خطا: $e');
    }
  }

  Future<int> _delayOf(String url) async {
    try {
      final parser = FlutterV2ray.parseFromURL(url);
      final d = await _v2ray
          .getServerDelay(config: parser.getFullConfiguration())
          .timeout(const Duration(seconds: 6));
      return d;
    } catch (_) {
      return 99999;
    }
  }

  Future<void> _testAll() async {
    if (_testing || _configs.isEmpty) return;
    setState(() => _testing = true);
    try {
      for (final c in _configs) {
        final d = await _delayOf(c.url);
        c.delay = d;
        if (mounted) setState(() {});
      }
    } finally {
      if (mounted) setState(() => _testing = false);
    }
  }

  Future<void> _connectBest() async {
    if (_connecting) return;
    if (_connected) {
      await _disconnect();
      return;
    }
    setState(() => _connecting = true);

    try {
      if (_configs.isEmpty) await _loadConfigs();
      if (_configs.isEmpty) return;

      ConfigItem? best;
      int bestDelay = 1 << 30;

      // برای سرعت بیشتر، فقط ۳۰ کانفیگ اول را تست می‌کنیم
      final sample = _configs.take(30).toList();
      for (final c in sample) {
        final d = await _delayOf(c.url);
        c.delay = d;
        if (d < bestDelay) {
          bestDelay = d;
          best = c;
        }
        if (mounted) setState(() {});
      }

      if (best == null || bestDelay >= 99999) {
        _snack('کانفیگ سالمی پیدا نشد');
        return;
      }

      await _connect(best);
    } finally {
      if (mounted) setState(() => _connecting = false);
    }
  }

  Future<void> _connect(ConfigItem c) async {
    try {
      if (_connected) await _v2ray.stopV2Ray();

      // Android requires explicit user consent before creating a VPN tunnel.
      final permissionGranted = await _v2ray.requestPermission();
      if (!permissionGranted) {
        _snack('مجوز ایجاد اتصال VPN داده نشد');
        return;
      }

      final parser = FlutterV2ray.parseFromURL(c.url);
      await _v2ray.startV2Ray(
        remark: parser.remark,
        config: parser.getFullConfiguration(),
        blockedApps: const [],
        bypassSubnets: const [],
      );
      if (mounted) setState(() => _selected = c);
    } catch (e) {
      _snack('خطای اتصال: $e');
    }
  }

  Future<void> _disconnect() async {
    try {
      await _v2ray.stopV2Ray();
    } catch (_) {}
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(msg)));
  }

  Future<void> _openSettings() async {
    final controller = TextEditingController(text: _subUrl);
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('لینک اشتراک (Subscription)'),
        content: TextField(
          controller: controller,
          maxLines: 4,
          decoration: const InputDecoration(
            hintText: 'https://...',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('انصراف'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            child: const Text('ذخیره'),
          ),
        ],
      ),
    );

    if (result == null) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('sub_url', result);
    setState(() {
      _subUrl = result;
      _configs.clear();
      _selected = null;
    });
    if (result.isNotEmpty) await _loadConfigs();
  }

  @override
  Widget build(BuildContext context) {
    if (_initializing) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('SAMENI VPN'),
        centerTitle: true,
        actions: [
          IconButton(
            icon: const Icon(Icons.settings),
            tooltip: 'تنظیمات',
            onPressed: _openSettings,
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            _statusCard(),
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              height: 60,
              child: FilledButton.icon(
                onPressed: _connecting ? null : _connectBest,
                style: FilledButton.styleFrom(
                  backgroundColor: _connected ? Colors.red : null,
                ),
                icon: _connecting
                    ? const SizedBox(
                        width: 22,
                        height: 22,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      )
                    : Icon(_connected ? Icons.stop : Icons.bolt, size: 28),
                label: Text(
                  _connecting
                      ? 'در حال یافتن بهترین سرور...'
                      : (_connected
                          ? 'قطع اتصال'
                          : 'اتصال به بهترین سرور'),
                  style: const TextStyle(fontSize: 16),
                ),
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _loadConfigs,
                    icon: const Icon(Icons.refresh),
                    label: const Text('به‌روزرسانی'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _testing ? null : _testAll,
                    icon: _testing
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child:
                                CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.speed),
                    label: const Text('تست پینگ'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Expanded(child: _configList()),
            if (_log.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  _log,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 10),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _statusCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  _connected ? Icons.shield : Icons.shield_outlined,
                  color: _connected ? Colors.green : Colors.red,
                  size: 32,
                ),
                const SizedBox(width: 8),
                Text(
                  _connected ? 'متصل' : 'قطع',
                  style: TextStyle(
                    fontSize: 26,
                    fontWeight: FontWeight.bold,
                    color: _connected ? Colors.green : Colors.red,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              _status,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 12),
            ),
            if (_selected != null)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  'پینگ سرور انتخاب‌شده: ${_selected!.delay ?? "?"} ms',
                  style: const TextStyle(fontSize: 11),
                ),
              ),
            if (_subUrl.isEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  '⚠️ ابتدا از تنظیمات (آیکون چرخ‌دنده) لینک اشتراک را وارد کنید',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 12,
                    color: Theme.of(context).colorScheme.error,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _configList() {
    if (_configs.isEmpty) {
      return const Center(
        child: Text(
          'کانفیگی وجود ندارد\nاز تنظیمات لینک اضافه کنید',
          textAlign: TextAlign.center,
        ),
      );
    }
    return ListView.builder(
      itemCount: _configs.length,
      itemBuilder: (context, i) {
        final c = _configs[i];
        final isSelected = _selected == c;
        return Card(
          margin: const EdgeInsets.symmetric(vertical: 2),
          child: ListTile(
            dense: true,
            leading: CircleAvatar(
              radius: 16,
              backgroundColor: isSelected
                  ? Colors.green
                  : Theme.of(context).colorScheme.primaryContainer,
              child: Text('${i + 1}', style: const TextStyle(fontSize: 11)),
            ),
            title: Text(
              c.url.length > 45 ? '${c.url.substring(0, 45)}...' : c.url,
              style: const TextStyle(fontSize: 11),
            ),
            trailing: Text(
              c.delay == null
                  ? '—'
                  : (c.delay! >= 99999 ? '✗' : '${c.delay}ms'),
              style: TextStyle(
                color: c.delay == null
                    ? null
                    : (c.delay! < 400
                        ? Colors.green
                        : (c.delay! < 1000 ? Colors.orange : Colors.red)),
                fontWeight: FontWeight.bold,
              ),
            ),
            onTap: () => _connect(c),
          ),
        );
      },
    );
  }
}