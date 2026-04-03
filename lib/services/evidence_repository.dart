import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../app_constants.dart';
import '../models/evidence_models.dart';

class EvidenceRepository {
  SharedPreferences? _prefs;

  Future<void> init() async {
    _prefs = await SharedPreferences.getInstance();
  }

  Future<List<EvidenceRecord>> loadRecords() async {
    final raw = _prefs?.getString(kRecordsKey);
    if (raw == null || raw.isEmpty) return const [];
    final jsonList = (jsonDecode(raw) as List).cast<Map<String, dynamic>>();
    return jsonList.map(EvidenceRecord.fromJson).toList();
  }

  Future<void> saveRecord(EvidenceRecord record) async {
    final records = await loadRecords();
    final next = [...records.where((item) => item.id != record.id), record]
      ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    await _prefs?.setString(kRecordsKey, jsonEncode(next.map((e) => e.toJson()).toList()));
  }

  Future<void> deleteRecord(String id) async {
    final records = await loadRecords();
    final next = records.where((item) => item.id != id).toList();
    await _prefs?.setString(kRecordsKey, jsonEncode(next.map((e) => e.toJson()).toList()));
  }
}
