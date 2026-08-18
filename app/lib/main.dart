import 'package:flutter/material.dart';

import 'api.dart';

void main() => runApp(const ScreenerApp());

class ScreenerApp extends StatelessWidget {
  const ScreenerApp({super.key});

  @override
  Widget build(BuildContext context) {
    // Green seed = the "quality/growth pass" feel; full light + dark support.
    const seed = Color(0xFF2E7D32);
    return MaterialApp(
      title: 'Stock Pre-Screen',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(colorSchemeSeed: seed, brightness: Brightness.light),
      darkTheme: ThemeData(colorSchemeSeed: seed, brightness: Brightness.dark),
      home: const HomePage(),
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  late Future<List<Stock>> _future;
  final _tickerCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    _future = fetchScreen(); // load the watchlist on first open
  }

  @override
  void dispose() {
    _tickerCtrl.dispose();
    super.dispose();
  }

  void _reload() {
    final text = _tickerCtrl.text.trim();
    setState(() => _future = fetchScreen(tickers: text.isEmpty ? null : text));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Stock Pre-Screen'),
        actions: [
          IconButton(
            tooltip: 'Refresh',
            onPressed: _reload,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: Column(
        children: [
          _SearchBar(controller: _tickerCtrl, onSubmit: _reload),
          Expanded(
            child: FutureBuilder<List<Stock>>(
              future: _future,
              builder: (context, snap) {
                if (snap.connectionState == ConnectionState.waiting) {
                  return const Center(child: CircularProgressIndicator());
                }
                if (snap.hasError) {
                  return _ErrorView(message: '${snap.error}', onRetry: _reload);
                }
                final stocks = snap.data ?? const <Stock>[];
                // Pull-to-refresh needs an always-scrollable child, hence the list.
                return RefreshIndicator(
                  onRefresh: () async => _reload(),
                  child: _ResultsList(stocks: stocks),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _SearchBar extends StatelessWidget {
  final TextEditingController controller;
  final VoidCallback onSubmit;
  const _SearchBar({required this.controller, required this.onSubmit});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: controller,
              textInputAction: TextInputAction.search,
              onSubmitted: (_) => onSubmit(),
              decoration: const InputDecoration(
                isDense: true,
                prefixIcon: Icon(Icons.search),
                border: OutlineInputBorder(),
                hintText: 'AAPL, TCS.NS …  (blank = watchlist)',
              ),
            ),
          ),
          const SizedBox(width: 8),
          FilledButton(onPressed: onSubmit, child: const Text('Screen')),
        ],
      ),
    );
  }
}

// ---- Buckets: fixed order + fixed colors so both themes stay legible. --------
const _bucketOrder = ['eligible', 'near-miss', 'rejected', 'insufficient'];
const _bucketTitle = {
  'eligible': 'Eligible',
  'near-miss': 'Near-miss',
  'rejected': 'Rejected',
  'insufficient': 'Insufficient data',
};

Color _bucketColor(String bucket) {
  switch (bucket) {
    case 'eligible':
      return const Color(0xFF2E7D32); // green
    case 'near-miss':
      return const Color(0xFFEF6C00); // amber
    case 'rejected':
      return const Color(0xFFC62828); // red
    default:
      return const Color(0xFF757575); // grey
  }
}

class _ResultsList extends StatelessWidget {
  final List<Stock> stocks;
  const _ResultsList({required this.stocks});

  @override
  Widget build(BuildContext context) {
    if (stocks.isEmpty) {
      return ListView(
        children: const [
          Padding(
            padding: EdgeInsets.all(40),
            child: Center(child: Text('No results.')),
          ),
        ],
      );
    }

    final children = <Widget>[];
    for (final bucket in _bucketOrder) {
      final group = stocks.where((s) => s.bucket == bucket).toList();
      if (group.isEmpty) continue;
      children.add(_SectionHeader(
        title: _bucketTitle[bucket]!,
        count: group.length,
        color: _bucketColor(bucket),
      ));
      children.addAll(group.map((s) => StockCard(stock: s)));
    }
    return ListView(
      padding: const EdgeInsets.only(bottom: 24),
      children: children,
    );
  }
}

class _SectionHeader extends StatelessWidget {
  final String title;
  final int count;
  final Color color;
  const _SectionHeader({
    required this.title,
    required this.count,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 16, 14, 6),
      child: Row(
        children: [
          Container(
            width: 10,
            height: 10,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          const SizedBox(width: 8),
          Text(
            title,
            style: Theme.of(context)
                .textTheme
                .titleSmall
                ?.copyWith(fontWeight: FontWeight.bold),
          ),
          const SizedBox(width: 6),
          Text('($count)', style: Theme.of(context).textTheme.titleSmall),
        ],
      ),
    );
  }
}

class StockCard extends StatelessWidget {
  final Stock stock;
  const StockCard({super.key, required this.stock});

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        stock.ticker,
                        style: Theme.of(context)
                            .textTheme
                            .titleMedium
                            ?.copyWith(fontWeight: FontWeight.bold),
                      ),
                      Text(
                        stock.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
                if (stock.currency.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: Text(
                      stock.currency,
                      style: Theme.of(context).textTheme.labelSmall,
                    ),
                  ),
                _BucketBadge(bucket: stock.bucket),
              ],
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: stock.checks.map((c) => _CheckChip(check: c)).toList(),
            ),
          ],
        ),
      ),
    );
  }
}

class _BucketBadge extends StatelessWidget {
  final String bucket;
  const _BucketBadge({required this.bucket});

  @override
  Widget build(BuildContext context) {
    final color = _bucketColor(bucket);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: color.withAlpha(30), // ~12% tint; withAlpha is stable across versions
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        _bucketTitle[bucket] ?? bucket,
        style: TextStyle(color: color, fontWeight: FontWeight.w600, fontSize: 12),
      ),
    );
  }
}

class _CheckChip extends StatelessWidget {
  final Check check;
  const _CheckChip({required this.check});

  @override
  Widget build(BuildContext context) {
    Color fg;
    IconData icon;
    switch (check.verdict) {
      case 'pass':
        fg = const Color(0xFF2E7D32);
        icon = Icons.check;
        break;
      case 'fail':
        fg = const Color(0xFFC62828);
        icon = Icons.close;
        break;
      default: // na
        fg = const Color(0xFF757575);
        icon = Icons.remove;
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: fg.withAlpha(28),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 13, color: fg),
          const SizedBox(width: 3),
          Text(
            '${check.label} ${_formatValue(check)}',
            style: TextStyle(fontSize: 12, color: fg, fontWeight: FontWeight.w500),
          ),
        ],
      ),
    );
  }
}

/// Formats a check's raw number the way the checklist reads it:
/// percentages for returns/growth, a bare ratio for debt/equity, and just the
/// sign for cash flow (all we care about there is positive vs negative).
String _formatValue(Check check) {
  final v = check.value;
  if (check.verdict == 'na' || v == null) return 'n/a';
  switch (check.key) {
    case 'ocf':
      return v > 0 ? '+' : '–';
    case 'de':
      return v.toStringAsFixed(1);
    default:
      return '${(v * 100).toStringAsFixed(0)}%';
  }
}

class _ErrorView extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;
  const _ErrorView({required this.message, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.cloud_off, size: 40),
            const SizedBox(height: 12),
            const Text(
              'Could not reach the backend.',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 6),
            Text(message, textAlign: TextAlign.center, style: const TextStyle(fontSize: 12)),
            const SizedBox(height: 8),
            Text(
              'Is the API running at $apiBase ?',
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 12),
            ),
            const SizedBox(height: 14),
            FilledButton.icon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh),
              label: const Text('Retry'),
            ),
          ],
        ),
      ),
    );
  }
}
