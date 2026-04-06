import 'dart:convert';
import 'dart:io';

import '../models/evidence_models.dart';

class EvidenceBackendService {
  static const String _baseHost = 'app-master.officialsite.kr';

  static Future<void> logPdfAction({
    required EvidenceRecord record,
    required String action,
    String? fileName,
    int? fileSizeBytes,
    String? locale,
  }) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
    try {
      final request = await client.postUrl(Uri.https(_baseHost, '/api/admin/evidence-note/pdf-exports'));
      request.headers.contentType = ContentType.json;
      request.add(
        utf8.encode(
          jsonEncode({
            'record_id': record.id,
            'proof_id': record.proofId,
            'record_title': record.title,
            'counterparty_name': record.counterpartyName,
            'action': action,
            'file_name': fileName,
            'file_size_bytes': fileSizeBytes,
            'amount': record.amount,
            'status': record.status.name,
            'device_summary': record.deviceSummary,
            'platform': Platform.operatingSystem,
            'locale': locale,
          }),
        ),
      );
      final response = await request.close();
      await response.drain<void>();
    } catch (_) {
      // Keep export/share local-first even if logging fails.
    } finally {
      client.close(force: true);
    }
  }
}
