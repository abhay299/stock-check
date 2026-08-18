import 'package:flutter/material.dart';

import 'api.dart';

void main() => runApp(const ScreenerApp());

class ScreenerApp extends StatelessWidget {
  const ScreenerApp({super.key});

  @override
  Widget build(BuildContext context) {
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

/// Owns the shared "which tickers are saved" set and the two tabs. Keeping the
/// saved set here (not inside a tab) is what lets the Check tab flip its
/// Add/Remove button and the My Watchlist tab stay in sync from one source.
class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  int _tab = 0;
  Set<String> _saved = {};
  // Bumped whenever the saved list changes, to force My Watchlist to refetch.
  Key _watchlistKey = UniqueKey();

  @override
  void initState() {
    super.initState();
    _loadSaved();
  }

  Future<void> _loadSaved() async {
    try {
      final tickers = await fetchWatchlistTickers();
      if (mounted) setState(() => _saved = tickers);
    } catch (_) {
      // Backend may be down; leave the set empty and let the tabs surface the error.
    }
  }

  Future<void> _add(String ticker) async {
    final tickers = await addToWatchlist(ticker);
    if (mounted) {
      setState(() {
        _saved = tickers.toSet();
        _watchlistKey = UniqueKey();
      });
    }
  }

  Future<void> _remove(String ticker) async {
    final tickers = await removeFromWatchlist(ticker);
    if (mounted) {
      setState(() {
        _saved = tickers.toSet();
        _watchlistKey = UniqueKey();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final pages = [
      CheckTab(saved: _saved, onAdd: _add, onRemove: _remove),
      MyWatchlistTab(key: _watchlistKey, onRemove: _remove),
    ];
    return Scaffold(
      appBar: AppBar(title: const Text('Stock Pre-Screen')),
      body: pages[_tab],
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tab,
        onDestinationSelected: (i) => setState(() {
          _tab = i;
          if (i == 1) _watchlistKey = UniqueKey(); // reopening the list refreshes it
        }),
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.fact_check_outlined),
            selectedIcon: Icon(Icons.fact_check),
            label: 'Check',
          ),
          NavigationDestination(
            icon: Icon(Icons.star_outline),
            selectedIcon: Icon(Icons.star),
            label: 'My Watchlist',
          ),
        ],
      ),
    );
  }
}

// ============================== Check tab ==============================

/// Search one ticker, run the checks, then add/remove it from the watchlist.
class CheckTab extends StatefulWidget {
  final Set<String> saved;
  final Future<void> Function(String) onAdd;
  final Future<void> Function(String) onRemove;
  const CheckTab({
    super.key,
    required this.saved,
    required this.onAdd,
    required this.onRemove,
  });

  @override
  State<CheckTab> createState() => _CheckTabState();
}

class _CheckTabState extends State<CheckTab> {
  final _ctrl = TextEditingController();
  Future<List<SymbolMatch>>? _searchFuture; // name/symbol lookup results
  String? _selectedTicker; // when set, show this stock's scorecard instead of the list
  Future<Stock>? _stockFuture;

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  void _search() {
    final q = _ctrl.text.trim();
    if (q.isEmpty) return;
    FocusScope.of(context).unfocus();
    setState(() {
      _searchFuture = searchSymbols(q);
      _selectedTicker = null;
      _stockFuture = null;
    });
  }

  void _select(String ticker) {
    setState(() {
      _selectedTicker = ticker;
      _stockFuture = fetchStock(ticker);
    });
  }

  void _backToResults() {
    setState(() {
      _selectedTicker = null;
      _stockFuture = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 6),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _ctrl,
                  textInputAction: TextInputAction.search,
                  onSubmitted: (_) => _search(),
                  decoration: const InputDecoration(
                    isDense: true,
                    prefixIcon: Icon(Icons.search),
                    border: OutlineInputBorder(),
                    hintText: 'Company or ticker — e.g. Reliance, Apple, TCS',
                  ),
                ),
              ),
              const SizedBox(width: 8),
              FilledButton(onPressed: _search, child: const Text('Search')),
            ],
          ),
        ),
        Expanded(child: _body()),
      ],
    );
  }

  Widget _body() {
    // A stock is picked → show its scorecard (with a way back to the results).
    if (_selectedTicker != null) return _scorecardView(_selectedTicker!);
    // A search has run → show the matches to pick from.
    if (_searchFuture != null) return _resultsView();
    // Nothing yet → first-run hint.
    return const _Hint(
      icon: Icons.search,
      title: 'Find a stock',
      message: 'Search by company name or ticker — e.g. "Reliance", "Apple" or '
          '"TCS". Pick a result to run the 7 checks, then add it to your watchlist.',
    );
  }

  Widget _resultsView() {
    return FutureBuilder<List<SymbolMatch>>(
      future: _searchFuture,
      builder: (context, snap) {
        if (snap.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator());
        }
        if (snap.hasError) {
          return _ErrorView(message: '${snap.error}', onRetry: _search);
        }
        final matches = snap.data ?? const <SymbolMatch>[];
        if (matches.isEmpty) {
          return const _Hint(
            icon: Icons.search_off,
            title: 'No matches',
            message: 'Try a different company name, or the exact ticker.',
          );
        }
        return ListView.separated(
          itemCount: matches.length,
          separatorBuilder: (_, _) => const Divider(height: 1),
          itemBuilder: (context, i) {
            final m = matches[i];
            final saved = widget.saved.contains(m.ticker);
            return ListTile(
              title: Text(m.name, maxLines: 1, overflow: TextOverflow.ellipsis),
              subtitle: Text(m.exchange.isEmpty ? m.ticker : '${m.ticker} · ${m.exchange}'),
              trailing: saved
                  ? const Icon(Icons.star, size: 18, color: Color(0xFF2E7D32))
                  : const Icon(Icons.chevron_right),
              onTap: () => _select(m.ticker),
            );
          },
        );
      },
    );
  }

  Widget _scorecardView(String ticker) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            onPressed: _backToResults,
            icon: const Icon(Icons.arrow_back, size: 18),
            label: const Text('Back to results'),
          ),
        ),
        Expanded(
          child: FutureBuilder<Stock>(
            future: _stockFuture,
            builder: (context, snap) {
              if (snap.connectionState == ConnectionState.waiting) {
                return const Center(child: CircularProgressIndicator());
              }
              if (snap.hasError) {
                return _ErrorView(
                    message: '${snap.error}', onRetry: () => _select(ticker));
              }
              final stock = snap.data!;
              final inList = widget.saved.contains(stock.ticker);
              return ListView(
                padding: const EdgeInsets.only(bottom: 24),
                children: [
                  StockCard(stock: stock),
                  if (stock.bucket == 'insufficient')
                    const Padding(
                      padding: EdgeInsets.fromLTRB(20, 4, 20, 0),
                      child: Text(
                        'No fundamental data for this listing.',
                        style: TextStyle(fontSize: 12, fontStyle: FontStyle.italic),
                      ),
                    ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                    child: _WatchlistButton(
                      ticker: stock.ticker,
                      inList: inList,
                      onAdd: widget.onAdd,
                      onRemove: widget.onRemove,
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ],
    );
  }
}

/// Add/Remove button that owns its in-flight spinner; the actual saved-set update
/// happens in the parent, which then flips [inList] and rebuilds this button.
class _WatchlistButton extends StatefulWidget {
  final String ticker;
  final bool inList;
  final Future<void> Function(String) onAdd;
  final Future<void> Function(String) onRemove;
  const _WatchlistButton({
    required this.ticker,
    required this.inList,
    required this.onAdd,
    required this.onRemove,
  });

  @override
  State<_WatchlistButton> createState() => _WatchlistButtonState();
}

class _WatchlistButtonState extends State<_WatchlistButton> {
  bool _busy = false;

  Future<void> _toggle() async {
    setState(() => _busy = true);
    try {
      if (widget.inList) {
        await widget.onRemove(widget.ticker);
      } else {
        await widget.onAdd(widget.ticker);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Failed: $e')));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final Widget icon = _busy
        ? const SizedBox(
            width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
        : Icon(widget.inList ? Icons.check : Icons.add);
    final label =
        Text(widget.inList ? 'In watchlist — tap to remove' : 'Add to watchlist');
    final onPressed = _busy ? null : _toggle;

    return SizedBox(
      width: double.infinity,
      child: widget.inList
          ? OutlinedButton.icon(onPressed: onPressed, icon: icon, label: label)
          : FilledButton.icon(onPressed: onPressed, icon: icon, label: label),
    );
  }
}

// =========================== My Watchlist tab ===========================

/// Shows every saved stock, re-checked, grouped by bucket, each removable.
class MyWatchlistTab extends StatefulWidget {
  final Future<void> Function(String) onRemove;
  const MyWatchlistTab({super.key, required this.onRemove});

  @override
  State<MyWatchlistTab> createState() => _MyWatchlistTabState();
}

class _MyWatchlistTabState extends State<MyWatchlistTab> {
  late Future<List<Stock>> _future;

  @override
  void initState() {
    super.initState();
    _future = fetchWatchlist();
  }

  void _reload() => setState(() => _future = fetchWatchlist());

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<Stock>>(
      future: _future,
      builder: (context, snap) {
        if (snap.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator());
        }
        if (snap.hasError) {
          return _ErrorView(message: '${snap.error}', onRetry: _reload);
        }
        final stocks = snap.data ?? const <Stock>[];
        if (stocks.isEmpty) {
          return const _Hint(
            icon: Icons.star_outline,
            title: 'Your watchlist is empty',
            message: 'Go to the Check tab, vet a stock, and add it here.',
          );
        }
        return RefreshIndicator(
          onRefresh: () async => _reload(),
          child: _ResultsList(stocks: stocks, onRemove: widget.onRemove),
        );
      },
    );
  }
}

// ============================ Shared widgets ============================

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
  final Future<void> Function(String)? onRemove;
  const _ResultsList({required this.stocks, this.onRemove});

  @override
  Widget build(BuildContext context) {
    final children = <Widget>[];
    for (final bucket in _bucketOrder) {
      final group = stocks.where((s) => s.bucket == bucket).toList();
      if (group.isEmpty) continue;
      children.add(_SectionHeader(
        title: _bucketTitle[bucket]!,
        count: group.length,
        color: _bucketColor(bucket),
      ));
      children.addAll(group.map((s) => StockCard(stock: s, onRemove: onRemove)));
    }
    return ListView(
      // Always scrollable so pull-to-refresh works even with a short list.
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.only(bottom: 24),
      children: children,
    );
  }
}

class _SectionHeader extends StatelessWidget {
  final String title;
  final int count;
  final Color color;
  const _SectionHeader({required this.title, required this.count, required this.color});

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
          Text(title,
              style: Theme.of(context)
                  .textTheme
                  .titleSmall
                  ?.copyWith(fontWeight: FontWeight.bold)),
          const SizedBox(width: 6),
          Text('($count)', style: Theme.of(context).textTheme.titleSmall),
        ],
      ),
    );
  }
}

class StockCard extends StatelessWidget {
  final Stock stock;
  final Future<void> Function(String)? onRemove; // shows a trash action when provided
  const StockCard({super.key, required this.stock, this.onRemove});

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
                      Text(stock.ticker,
                          style: Theme.of(context)
                              .textTheme
                              .titleMedium
                              ?.copyWith(fontWeight: FontWeight.bold)),
                      Text(stock.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.bodySmall),
                    ],
                  ),
                ),
                if (stock.currency.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: Text(stock.currency,
                        style: Theme.of(context).textTheme.labelSmall),
                  ),
                _BucketBadge(bucket: stock.bucket),
                if (onRemove != null)
                  _RemoveButton(ticker: stock.ticker, onRemove: onRemove!),
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

/// Trash button on a watchlist card. On success the parent rebuilds the list
/// without this card, so it just disappears (no local success state needed).
class _RemoveButton extends StatefulWidget {
  final String ticker;
  final Future<void> Function(String) onRemove;
  const _RemoveButton({required this.ticker, required this.onRemove});

  @override
  State<_RemoveButton> createState() => _RemoveButtonState();
}

class _RemoveButtonState extends State<_RemoveButton> {
  bool _busy = false;

  Future<void> _remove() async {
    setState(() => _busy = true);
    try {
      await widget.onRemove(widget.ticker);
    } catch (e) {
      if (mounted) {
        setState(() => _busy = false);
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Failed: $e')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: 'Remove from watchlist',
      visualDensity: VisualDensity.compact,
      onPressed: _busy ? null : _remove,
      icon: _busy
          ? const SizedBox(
              width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
          : const Icon(Icons.delete_outline, size: 20),
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
      child: Text(_bucketTitle[bucket] ?? bucket,
          style: TextStyle(color: color, fontWeight: FontWeight.w600, fontSize: 12)),
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
          Text('${check.label} ${_formatValue(check)}',
              style: TextStyle(fontSize: 12, color: fg, fontWeight: FontWeight.w500)),
        ],
      ),
    );
  }
}

/// Formats a check's raw number the way the checklist reads it: percentages for
/// returns/growth, a bare ratio for debt/equity, and just the sign for cash flow.
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

/// Friendly full-screen message for empty/first-run states.
class _Hint extends StatelessWidget {
  final IconData icon;
  final String title;
  final String message;
  const _Hint({required this.icon, required this.title, required this.message});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 44, color: Theme.of(context).colorScheme.outline),
            const SizedBox(height: 14),
            Text(title,
                style: Theme.of(context)
                    .textTheme
                    .titleMedium
                    ?.copyWith(fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            Text(message,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodyMedium),
          ],
        ),
      ),
    );
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
            const Text('Could not reach the backend.',
                style: TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 6),
            Text(message,
                textAlign: TextAlign.center, style: const TextStyle(fontSize: 12)),
            const SizedBox(height: 8),
            Text('Is the API running at $apiBase ?',
                textAlign: TextAlign.center, style: const TextStyle(fontSize: 12)),
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
