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
