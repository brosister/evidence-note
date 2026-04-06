import 'dart:convert';
import 'dart:io';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import '../models/evidence_models.dart';

class EvidenceApiService {
  EvidenceApiService._();

  static final EvidenceApiService instance = EvidenceApiService._();
  static const String _baseUrl = 'https://app-master.officialsite.kr/api/evidence-note';
  static const String _deviceSerialKey = 'evidence_note_device_serial';
  static const String _userIdKey = 'evidence_note_user_id';

  String? _deviceSerial;
  String? _userId;

  Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();
    _deviceSerial = prefs.getString(_deviceSerialKey);
    _userId = prefs.getString(_userIdKey);
  }

  Future<String> getDeviceSerial() async {
    if (_deviceSerial != null && _deviceSerial!.isNotEmpty) {
      return _deviceSerial!;
    }

    final prefs = await SharedPreferences.getInstance();
    final stored = prefs.getString(_deviceSerialKey);
    if (stored != null && stored.isNotEmpty) {
      _deviceSerial = stored;
      return stored;
    }

    String prefix = 'E_';
    try {
      final deviceInfo = DeviceInfoPlugin();
      if (Platform.isAndroid) {
        final info = await deviceInfo.androidInfo;
        prefix = 'A_${info.model}_';
      } else if (Platform.isIOS) {
        final info = await deviceInfo.iosInfo;
        prefix = 'I_${info.model}_';
      }
    } catch (_) {}

    _deviceSerial = '$prefix${const Uuid().v4()}';
    await prefs.setString(_deviceSerialKey, _deviceSerial!);
    return _deviceSerial!;
  }

  Future<String> ensureUserId() async {
    if (_userId != null && _userId!.isNotEmpty) {
      return _userId!;
    }

    final prefs = await SharedPreferences.getInstance();
    final stored = prefs.getString(_userIdKey);
    if (stored != null && stored.isNotEmpty) {
      _userId = stored;
      return stored;
    }

    final deviceSerial = await getDeviceSerial();
    final response = await http.post(
      Uri.parse('$_baseUrl/users/register'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'deviceSerial': deviceSerial}),
    );
    final body = jsonDecode(response.body) as Map<String, dynamic>;
    if (response.statusCode < 200 || response.statusCode >= 300 || body['success'] != true) {
      throw Exception(body['message'] ?? '사용자 등록에 실패했습니다.');
    }

    _userId = (body['data'] as Map<String, dynamic>)['id'] as String;
    await prefs.setString(_userIdKey, _userId!);
    return _userId!;
  }

  Future<AttachmentItem> uploadAttachment(AttachmentItem item) async {
    if (item.remoteUrl != null && item.remoteUrl!.isNotEmpty) {
      return item;
    }

    final userId = await ensureUserId();
    final deviceSerial = await getDeviceSerial();
    final file = File(item.path);
    if (!await file.exists()) {
      throw Exception('첨부 파일을 찾을 수 없습니다.');
    }

    final localUploadKey = item.localUploadKey ?? const Uuid().v4();
    final request = http.MultipartRequest('POST', Uri.parse('$_baseUrl/attachments/upload'))
      ..fields['userId'] = userId
      ..fields['deviceSerial'] = deviceSerial
      ..fields['attachmentType'] = item.type.name
      ..fields['localUploadKey'] = localUploadKey;

    if ((item.localAssetId ?? '').isNotEmpty) {
      request.fields['localAssetKey'] = item.localAssetId!;
    }

    request.files.add(await http.MultipartFile.fromPath(
      'file',
      file.path,
      filename: file.path.split(Platform.pathSeparator).last,
    ));
    final streamed = await request.send();
    final response = await http.Response.fromStream(streamed);
    final body = jsonDecode(response.body) as Map<String, dynamic>;

    if (response.statusCode < 200 || response.statusCode >= 300 || body['success'] != true) {
      throw Exception(body['message'] ?? '첨부 업로드에 실패했습니다.');
    }

    final data = body['data'] as Map<String, dynamic>;
    return item.copyWith(
      localUploadKey: localUploadKey,
      remoteUrl: data['cdnUrl'] as String?,
      remoteStorageKey: data['s3Key'] as String?,
      uploadedAt: DateTime.tryParse((data['uploadedAt'] as String?) ?? ''),
    );
  }

  Future<List<EvidenceRecord>> fetchRecords() async {
    final userId = await ensureUserId();
    final deviceSerial = await getDeviceSerial();
    final uri = Uri.parse('$_baseUrl/records').replace(queryParameters: {
      'userId': userId,
      'deviceSerial': deviceSerial,
    });
    final response = await http.get(uri);
    final body = jsonDecode(response.body) as Map<String, dynamic>;
    if (response.statusCode < 200 || response.statusCode >= 300 || body['success'] != true) {
      throw Exception(body['message'] ?? '기록을 불러오지 못했습니다.');
    }
    final data = (body['data'] as List? ?? const [])
        .map((item) => EvidenceRecord.fromJson(Map<String, dynamic>.from(item as Map)))
        .toList();
    data.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return data;
  }

  Future<void> saveRecord(EvidenceRecord record) async {
    final userId = await ensureUserId();
    final deviceSerial = await getDeviceSerial();
    final response = await http.put(
      Uri.parse('$_baseUrl/records/${record.id}'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'userId': userId,
        'deviceSerial': deviceSerial,
        'record': record.toJson(),
      }),
    );
    final body = jsonDecode(response.body) as Map<String, dynamic>;
    if (response.statusCode < 200 || response.statusCode >= 300 || body['success'] != true) {
      throw Exception(body['message'] ?? '기록 저장에 실패했습니다.');
    }
  }

  Future<void> deleteRecord(String recordId) async {
    final userId = await ensureUserId();
    final deviceSerial = await getDeviceSerial();
    final uri = Uri.parse('$_baseUrl/records/$recordId').replace(queryParameters: {
      'userId': userId,
      'deviceSerial': deviceSerial,
    });
    final response = await http.delete(uri);
    final body = jsonDecode(response.body) as Map<String, dynamic>;
    if (response.statusCode < 200 || response.statusCode >= 300 || body['success'] != true) {
      throw Exception(body['message'] ?? '기록 삭제에 실패했습니다.');
    }
  }
}
