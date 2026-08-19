import 'dart:convert';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:http/http.dart' as http;

/// Base URL of the FastAPI backend.
///
/// The default differs by platform on purpose:
///  - Flutter **web** (Chrome on your machine) can reach the local server directly.
///  - The Android **emulator** can't see the host's `localhost`; it maps the host
///    machine to the special address `10.0.2.2`.
/// Override it for a deployed backend with:
///   flutter run --dart-define=API_BASE=https://your-host
const String apiBase = String.fromEnvironment(
  'API_BASE',
  defaultValue: kIsWeb ? 'http://127.0.0.1:8000' : 'http://10.0.2.2:8000',
);

/// One checklist line (e.g. ROCE) with its computed value and verdict.
class Check {
  final String key;
  final String label;
  final String section; // "§1" or "§2"
  final String verdict; // pass | fail | na
  final String note;
  final double? value; // null when the check is N/A

  Check.fromJson(Map<String, dynamic> j)
      : key = j['key'] as String,
        label = j['label'] as String,
        section = j['section'] as String,
        verdict = j['verdict'] as String,
        note = (j['note'] ?? '') as String,
        value = (j['value'] as num?)?.toDouble();
}

/// A screened stock and its bucket.
class Stock {
  final String ticker;
  final String name;
  final String sector;
  final String currency;
  final String bucket; // eligible | near-miss | rejected | insufficient
  final int fails;
  final int applicable;
  final List<Check> checks;

  Stock.fromJson(Map<String, dynamic> j)
      : ticker = j['ticker'] as String,
        name = j['name'] as String,
        sector = (j['sector'] ?? '') as String,
        currency = (j['currency'] ?? '') as String,
        bucket = j['bucket'] as String,
        fails = j['fails'] as int,
        applicable = j['applicable'] as int,
        checks = (j['checks'] as List)
            .map((c) => Check.fromJson(c as Map<String, dynamic>))
            .toList();
}

/// Calls GET /screen. Pass [tickers] (comma-separated) to screen a custom list,
/// or leave it null to use the backend's watchlist.txt.
Future<List<Stock>> fetchScreen({String? tickers}) async {
  final hasTickers = tickers != null && tickers.trim().isNotEmpty;
  final uri = Uri.parse('$apiBase/screen').replace(
    queryParameters: hasTickers ? {'tickers': tickers.trim()} : null,
  );

  // Fundamentals fetches can be slow on a cold cache, so allow a generous timeout.
  final res = await http.get(uri).timeout(const Duration(seconds: 90));
  if (res.statusCode != 200) {
    throw Exception('Backend returned ${res.statusCode}: ${res.body}');
  }

  final data = jsonDecode(res.body) as Map<String, dynamic>;
  return (data['results'] as List)
      .map((e) => Stock.fromJson(e as Map<String, dynamic>))
      .toList();
}

/// Full scorecard for a single ticker (the Check tab).
Future<Stock> fetchStock(String ticker) async {
  final uri = Uri.parse('$apiBase/stock/${Uri.encodeComponent(ticker.trim())}');
  final res = await http.get(uri).timeout(const Duration(seconds: 90));
  if (res.statusCode != 200) {
    throw Exception('Backend returned ${res.statusCode}: ${res.body}');
  }
  return Stock.fromJson(jsonDecode(res.body) as Map<String, dynamic>);
}

/// Full scorecards for every saved stock (the My Watchlist tab).
Future<List<Stock>> fetchWatchlist() async {
  final res = await http
      .get(Uri.parse('$apiBase/watchlist'))
      .timeout(const Duration(seconds: 120));
  if (res.statusCode != 200) {
    throw Exception('Backend returned ${res.statusCode}: ${res.body}');
  }
  final data = jsonDecode(res.body) as Map<String, dynamic>;
  return (data['results'] as List)
      .map((e) => Stock.fromJson(e as Map<String, dynamic>))
      .toList();
}

/// Just the saved tickers — used to show the right Add/Remove state on a scorecard.
Future<Set<String>> fetchWatchlistTickers() async {
  final res = await http
      .get(Uri.parse('$apiBase/watchlist/tickers'))
      .timeout(const Duration(seconds: 30));
  if (res.statusCode != 200) {
    throw Exception('Backend returned ${res.statusCode}: ${res.body}');
  }
  final data = jsonDecode(res.body) as Map<String, dynamic>;
  return (data['tickers'] as List).map((e) => e as String).toSet();
}

/// Adds a ticker; returns the updated saved list.
Future<List<String>> addToWatchlist(String ticker) async {
  final res = await http
      .post(Uri.parse('$apiBase/watchlist/${Uri.encodeComponent(ticker.trim())}'))
      .timeout(const Duration(seconds: 30));
  if (res.statusCode != 200) {
    throw Exception('Backend returned ${res.statusCode}: ${res.body}');
  }
  final data = jsonDecode(res.body) as Map<String, dynamic>;
  return (data['tickers'] as List).map((e) => e as String).toList();
}

/// Removes a ticker; returns the updated saved list.
Future<List<String>> removeFromWatchlist(String ticker) async {
  final res = await http
      .delete(Uri.parse('$apiBase/watchlist/${Uri.encodeComponent(ticker.trim())}'))
      .timeout(const Duration(seconds: 30));
  if (res.statusCode != 200) {
    throw Exception('Backend returned ${res.statusCode}: ${res.body}');
  }
  final data = jsonDecode(res.body) as Map<String, dynamic>;
  return (data['tickers'] as List).map((e) => e as String).toList();
}

/// One result from GET /search — a candidate stock the user can pick to check.
class SymbolMatch {
  final String ticker;
  final String name;
  final String exchange;
  final String type;

  SymbolMatch.fromJson(Map<String, dynamic> j)
      : ticker = j['ticker'] as String,
        name = (j['name'] ?? '') as String,
        exchange = (j['exchange'] ?? '') as String,
        type = (j['type'] ?? '') as String;
}

/// Looks up stocks by company name or ticker fragment (the Check tab search box).
Future<List<SymbolMatch>> searchSymbols(String query) async {
  final uri =
      Uri.parse('$apiBase/search').replace(queryParameters: {'q': query.trim()});
  final res = await http.get(uri).timeout(const Duration(seconds: 30));
  if (res.statusCode != 200) {
    throw Exception('Backend returned ${res.statusCode}: ${res.body}');
  }
  final data = jsonDecode(res.body) as Map<String, dynamic>;
  return (data['results'] as List)
      .map((e) => SymbolMatch.fromJson(e as Map<String, dynamic>))
      .toList();
}

/// Metadata for one editable threshold (from GET /settings).
class ThresholdMeta {
  final String label;
  final String unit; // "percent" | "ratio"
  ThresholdMeta.fromJson(Map<String, dynamic> j)
      : label = j['label'] as String,
        unit = j['unit'] as String;
}

/// The filter thresholds: current values, defaults, and which keys are editable.
class Thresholds {
  final Map<String, double> values;
  final Map<String, double> defaults;
  final Map<String, ThresholdMeta> editable;
  Thresholds.fromJson(Map<String, dynamic> j)
      : values = _numMap(j['thresholds']),
        defaults = _numMap(j['defaults']),
        editable = (j['editable'] as Map<String, dynamic>).map((k, v) =>
            MapEntry(k, ThresholdMeta.fromJson(v as Map<String, dynamic>)));
}

Map<String, double> _numMap(dynamic m) =>
    (m as Map<String, dynamic>).map((k, v) => MapEntry(k, (v as num).toDouble()));

/// Current filter settings (GET /settings).
Future<Thresholds> fetchSettings() async {
  final res = await http
      .get(Uri.parse('$apiBase/settings'))
      .timeout(const Duration(seconds: 30));
  if (res.statusCode != 200) {
    throw Exception('Backend returned ${res.statusCode}: ${res.body}');
  }
  return Thresholds.fromJson(jsonDecode(res.body) as Map<String, dynamic>);
}

/// Save edited thresholds (PUT /settings); returns the updated settings.
Future<Thresholds> updateSettings(Map<String, double> values) async {
  final res = await http
      .put(
        Uri.parse('$apiBase/settings'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'thresholds': values}),
      )
      .timeout(const Duration(seconds: 30));
  if (res.statusCode != 200) {
    throw Exception('Backend returned ${res.statusCode}: ${res.body}');
  }
  return Thresholds.fromJson(jsonDecode(res.body) as Map<String, dynamic>);
}
