import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../app_constants.dart';
import '../models/evidence_models.dart';
import 'evidence_api_service.dart';

class EvidenceRepository {
  SharedPreferences? _prefs;

  Future<void> init() async {
    _prefs = await SharedPreferences.getInstance();
  }

  Future<List<EvidenceRecord>> loadRecords() async {
    final records = await EvidenceApiService.instance.fetchRecords();
    await _prefs?.setString(kRecordsKey, jsonEncode(records.map((e) => e.toJson()).toList()));
    return records;
  }

  Future<void> saveRecord(EvidenceRecord record) async {
    await EvidenceApiService.instance.saveRecord(record);
    final records = await _loadLocalRecords();
    final next = [...records.where((item) => item.id != record.id), record]
      ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    await _prefs?.setString(kRecordsKey, jsonEncode(next.map((e) => e.toJson()).toList()));
  }

  Future<void> deleteRecord(String id) async {
    await EvidenceApiService.instance.deleteRecord(id);
    final records = await _loadLocalRecords();
    final next = records.where((item) => item.id != id).toList();
    await _prefs?.setString(kRecordsKey, jsonEncode(next.map((e) => e.toJson()).toList()));
  }

  Future<List<EvidenceRecord>> _loadLocalRecords() async {
    final raw = _prefs?.getString(kRecordsKey);
    if (raw == null || raw.isEmpty) return const [];
    final jsonList = (jsonDecode(raw) as List).cast<Map<String, dynamic>>();
    return jsonList.map(EvidenceRecord.fromJson).toList();
  }
}
