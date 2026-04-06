import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'dart:ui';

import 'package:crypto/crypto.dart';
import 'package:cross_file/cross_file.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_contacts/flutter_contacts.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:google_mobile_ads/google_mobile_ads.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:record/record.dart';
import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:signature/signature.dart';
import 'package:table_calendar/table_calendar.dart';
import 'package:uuid/uuid.dart';

import 'models/evidence_models.dart';
import 'photo_picker_page.dart';
import 'services/evidence_api_service.dart';
import 'services/evidence_backend_service.dart';
import 'services/evidence_repository.dart';
import 'services/reminder_service.dart';
import 'utils/app_formatters.dart';

const _uuid = Uuid();
Future<pw.Font>? _pdfRegularFontLoader;
Future<pw.Font>? _pdfBoldFontLoader;

Future<pw.Font> _loadPdfRegularFont() {
  return _pdfRegularFontLoader ??= rootBundle.load('assets/fonts/Pretendard-Regular.otf').then(
        (data) => pw.Font.ttf(data),
      );
}

Future<pw.Font> _loadPdfBoldFont() {
  return _pdfBoldFontLoader ??= rootBundle.load('assets/fonts/Pretendard-Bold.otf').then(
        (data) => pw.Font.ttf(data),
      );
}

String _pdfSafeName(String source) {
  final normalized = source.trim().replaceAll(RegExp(r'[\\/:*?"<>|]'), '_').replaceAll(RegExp(r'\s+'), '_');
  return normalized.isEmpty ? 'evidence_note' : normalized;
}

String _attachmentUploadKey(AttachmentType type) => '${type.name}_${const Uuid().v4()}';

Future<Map<String, dynamic>?> _fetchEvidenceNoteAdSettings() async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
  try {
    final request = await client.getUrl(Uri.https('app-master.officialsite.kr', '/api/evidence-note/ad-settings'));
    final response = await request.close();
    if (response.statusCode < 200 || response.statusCode >= 300) {
      return null;
    }
    final body = await response.transform(utf8.decoder).join();
    final decoded = jsonDecode(body) as Map<String, dynamic>;
    final data = decoded['data'];
    return data is Map<String, dynamic> ? data : null;
  } catch (_) {
    return null;
  } finally {
    client.close(force: true);
  }
}

class EvidenceInterstitialAdService {
  EvidenceInterstitialAdService._();

  static final EvidenceInterstitialAdService instance = EvidenceInterstitialAdService._();
  static const _saveCounterKey = 'evidence_note_interstitial_save_counter';
  static const _lastShownAtKey = 'evidence_note_interstitial_last_shown_at';

  InterstitialAd? _interstitialAd;
  bool _loading = false;

  String get _fallbackUnitId {
    if (Platform.isAndroid) return 'ca-app-pub-3940256099942544/1033173712';
    if (Platform.isIOS) return 'ca-app-pub-3940256099942544/4411468910';
    return '';
  }

  Future<String> _resolveUnitId() async {
    if (!Platform.isAndroid && !Platform.isIOS) return '';
    final data = await _fetchEvidenceNoteAdSettings();
    if (data == null) return _fallbackUnitId;
    if (Platform.isAndroid) {
      return (data['android_interstitial_ad_id'] as String?)?.trim().isNotEmpty == true
          ? data['android_interstitial_ad_id'] as String
          : _fallbackUnitId;
    }
    return (data['ios_interstitial_ad_id'] as String?)?.trim().isNotEmpty == true
        ? data['ios_interstitial_ad_id'] as String
        : _fallbackUnitId;
  }

  Future<void> preload() async {
    if (_loading || _interstitialAd != null) return;
    final unitId = await _resolveUnitId();
    if (unitId.isEmpty) return;
    _loading = true;
    InterstitialAd.load(
      adUnitId: unitId,
      request: const AdRequest(),
      adLoadCallback: InterstitialAdLoadCallback(
        onAdLoaded: (ad) {
          _interstitialAd = ad;
          _loading = false;
        },
        onAdFailedToLoad: (_) {
          _interstitialAd = null;
          _loading = false;
        },
      ),
    );
  }

  Future<void> onRecordSaved() async {
    final prefs = await SharedPreferences.getInstance();
    final currentCount = prefs.getInt(_saveCounterKey) ?? 0;
    final nextCount = currentCount + 1;
    await prefs.setInt(_saveCounterKey, nextCount);

    final lastShownRaw = prefs.getString(_lastShownAtKey);
    final lastShownAt = lastShownRaw == null ? null : DateTime.tryParse(lastShownRaw);
    final withinCooldown = lastShownAt != null && DateTime.now().difference(lastShownAt) < const Duration(seconds: 90);

    if (nextCount < 2 || withinCooldown) {
      await preload();
      return;
    }

    if (_interstitialAd == null) {
      await preload();
      return;
    }

    final ad = _interstitialAd!;
    _interstitialAd = null;
    final completer = Completer<void>();
    ad.fullScreenContentCallback = FullScreenContentCallback(
      onAdDismissedFullScreenContent: (ad) async {
        ad.dispose();
        await prefs.setInt(_saveCounterKey, 0);
        await prefs.setString(_lastShownAtKey, DateTime.now().toIso8601String());
        await preload();
        if (!completer.isCompleted) completer.complete();
      },
      onAdFailedToShowFullScreenContent: (ad, _) async {
        ad.dispose();
        await preload();
        if (!completer.isCompleted) completer.complete();
      },
    );
    ad.show();
    await completer.future;
  }
}

String? _photoAssetIdFromAttachment(AttachmentItem item) {
  if ((item.localAssetId ?? '').isNotEmpty) {
    return item.localAssetId;
  }
  final fileName = item.path.split(Platform.pathSeparator).last;
  final match = RegExp(r'^photo_\d+_(.+)\.[^.]+$').firstMatch(fileName);
  return match?.group(1);
}

Future<Uint8List> _buildRecordPdfBytes(EvidenceRecord record, String languageCode) async {
  final isKo = languageCode == 'ko';
  final pdf = pw.Document();
  final regularFont = await _loadPdfRegularFont();
  final boldFont = await _loadPdfBoldFont();
  final photoCount = record.attachments.where((item) => item.type == AttachmentType.photo).length;
  final audioCount = record.attachments.where((item) => item.type == AttachmentType.audio).length;
  final signatureCount = record.attachments.where((item) => item.type == AttachmentType.signature).length;

  pdf.addPage(
    pw.MultiPage(
      theme: pw.ThemeData.withFont(
        base: regularFont,
        bold: boldFont,
      ),
      build: (_) => [
        pw.Text(isKo ? '증거노트 요약' : 'Evidence Note Summary', style: pw.TextStyle(fontSize: 24, fontWeight: pw.FontWeight.bold)),
        pw.SizedBox(height: 16),
        pw.Text('${isKo ? '제목' : 'Title'}: ${record.title}'),
        pw.Text('${isKo ? '상대' : 'Counterparty'}: ${record.counterpartyName.isEmpty ? '-' : record.counterpartyName}'),
        pw.Text('${isKo ? '금액' : 'Amount'}: ${record.amount == null ? '-' : formatAmount(record.amount!)}'),
        pw.Text('${isKo ? '기록 시각' : 'Recorded At'}: ${formatDateTime(record.eventAt)}'),
        pw.Text('${isKo ? '만기' : 'Due'}: ${record.dueAt == null ? '-' : formatDateTime(record.dueAt!)}'),
        pw.Text('${isKo ? '알림' : 'Reminder'}: ${record.reminderAt == null ? '-' : formatDateTime(record.reminderAt!)}'),
        pw.Text('${isKo ? '상태' : 'Status'}: ${record.status.localizedLabel(languageCode)}'),
        pw.Text('${isKo ? '고유 ID' : 'Proof ID'}: ${record.proofId}'),
        pw.Text('${isKo ? '해시' : 'Hash'}: ${record.proofHash}'),
        pw.Text('${isKo ? '기기 정보' : 'Device'}: ${record.deviceSummary.isEmpty ? '-' : record.deviceSummary}'),
        pw.SizedBox(height: 16),
        pw.Text(isKo ? '메모' : 'Memo', style: pw.TextStyle(fontWeight: pw.FontWeight.bold)),
        pw.SizedBox(height: 6),
        pw.Text(record.memo.trim().isEmpty ? '-' : record.memo.trim()),
        pw.SizedBox(height: 16),
        pw.Text(isKo ? '첨부 요약' : 'Attachment Summary', style: pw.TextStyle(fontWeight: pw.FontWeight.bold)),
        pw.Bullet(text: '${isKo ? '사진' : 'Photos'} $photoCount${isKo ? '건' : ''}'),
        pw.Bullet(text: '${isKo ? '음성' : 'Audio'} $audioCount${isKo ? '건' : ''}'),
        pw.Bullet(text: '${isKo ? '서명' : 'Signatures'} $signatureCount${isKo ? '건' : ''}'),
      ],
    ),
  );
  return pdf.save();
}

Future<File> _writeRecordPdfFile(EvidenceRecord record, String languageCode) async {
  final bytes = await _buildRecordPdfBytes(record, languageCode);
  final dir = await getTemporaryDirectory();
  final exportDir = Directory('${dir.path}/evidence_note_exports');
  if (!await exportDir.exists()) {
    await exportDir.create(recursive: true);
  }
  final file = File('${exportDir.path}/${_pdfSafeName(record.title)}_${record.id}.pdf');
  await file.writeAsBytes(bytes, flush: true);
  return file;
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    statusBarIconBrightness: Brightness.dark,
    statusBarBrightness: Brightness.dark,
    systemNavigationBarColor: Color(0xFFF4F7FF),
    systemNavigationBarIconBrightness: Brightness.dark,
  ));

  final repository = EvidenceRepository();
  await repository.init();
  await EvidenceApiService.instance.init();
  await ReminderService.instance.init();
  await MobileAds.instance.initialize();

  runApp(EvidenceNoteApp(repository: repository));
}

class EvidenceNoteApp extends StatelessWidget {
  const EvidenceNoteApp({super.key, required this.repository});

  final EvidenceRepository repository;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Evidence Note',
      localeResolutionCallback: (locale, supportedLocales) {
        if (locale?.languageCode == 'ko') {
          return const Locale('ko');
        }
        return const Locale('en');
      },
      supportedLocales: const [
        Locale('ko'),
        Locale('en'),
      ],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      theme: ThemeData(
        useMaterial3: true,
        fontFamily: 'Pretendard',
        scaffoldBackgroundColor: const Color(0xFFF4F7FF),
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF4E6BFF)),
        textTheme: const TextTheme(
          headlineLarge: TextStyle(fontFamily: 'Pretendard', fontWeight: FontWeight.w700, height: 1.22, letterSpacing: -0.4),
          headlineMedium: TextStyle(fontFamily: 'Pretendard', fontWeight: FontWeight.w700, height: 1.24, letterSpacing: -0.3),
          headlineSmall: TextStyle(fontFamily: 'Pretendard', fontWeight: FontWeight.w700, height: 1.26, letterSpacing: -0.2),
          titleLarge: TextStyle(fontFamily: 'Pretendard', fontWeight: FontWeight.w600, height: 1.3, letterSpacing: -0.2),
          titleMedium: TextStyle(fontFamily: 'Pretendard', fontWeight: FontWeight.w600, height: 1.32, letterSpacing: -0.1),
          titleSmall: TextStyle(fontFamily: 'Pretendard', fontWeight: FontWeight.w600, height: 1.34),
          bodyLarge: TextStyle(fontFamily: 'Pretendard', fontWeight: FontWeight.w400, height: 1.5),
          bodyMedium: TextStyle(fontFamily: 'Pretendard', fontWeight: FontWeight.w400, height: 1.48),
          bodySmall: TextStyle(fontFamily: 'Pretendard', fontWeight: FontWeight.w400, height: 1.42),
          labelLarge: TextStyle(fontFamily: 'Pretendard', fontWeight: FontWeight.w600, height: 1.18),
          labelMedium: TextStyle(fontFamily: 'Pretendard', fontWeight: FontWeight.w500, height: 1.16),
          labelSmall: TextStyle(fontFamily: 'Pretendard', fontWeight: FontWeight.w500, height: 1.14),
        ),
        appBarTheme: const AppBarTheme(
          backgroundColor: Color(0xFFF4F7FF),
          surfaceTintColor: Colors.transparent,
          elevation: 0,
          scrolledUnderElevation: 0,
          titleTextStyle: TextStyle(
            fontFamily: 'Pretendard',
            fontSize: 20,
            fontWeight: FontWeight.w700,
            height: 1.2,
            color: Color(0xFF17203A),
          ),
          toolbarTextStyle: TextStyle(
            fontFamily: 'Pretendard',
            fontSize: 15,
            fontWeight: FontWeight.w500,
            color: Color(0xFF17203A),
          ),
          systemOverlayStyle: SystemUiOverlayStyle(
            statusBarColor: Colors.transparent,
            statusBarIconBrightness: Brightness.dark,
            statusBarBrightness: Brightness.dark,
          ),
        ),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: const Color(0xFFF7F9FF),
          contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
          labelStyle: const TextStyle(fontFamily: 'Pretendard', fontWeight: FontWeight.w500, color: Color(0xFF66718F)),
          hintStyle: const TextStyle(fontFamily: 'Pretendard', fontWeight: FontWeight.w400, color: Color(0xFF98A2B3)),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(18),
            borderSide: BorderSide.none,
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(18),
            borderSide: BorderSide.none,
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(18),
            borderSide: const BorderSide(color: Color(0xFF4E6BFF), width: 1.4),
          ),
        ),
        filledButtonTheme: FilledButtonThemeData(
          style: FilledButton.styleFrom(
            backgroundColor: const Color(0xFF183B56),
            foregroundColor: Colors.white,
            elevation: 0,
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
            textStyle: const TextStyle(fontFamily: 'Pretendard', fontWeight: FontWeight.w600, fontSize: 15),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
          ),
        ),
        outlinedButtonTheme: OutlinedButtonThemeData(
          style: OutlinedButton.styleFrom(
            backgroundColor: Colors.white.withValues(alpha: 0.72),
            foregroundColor: const Color(0xFF183B56),
            side: const BorderSide(color: Color(0xFFD6DFEA)),
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
            textStyle: const TextStyle(fontFamily: 'Pretendard', fontWeight: FontWeight.w600, fontSize: 15),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
          ),
        ),
        textButtonTheme: TextButtonThemeData(
          style: TextButton.styleFrom(
            foregroundColor: const Color(0xFF3457F1),
            textStyle: const TextStyle(fontFamily: 'Pretendard', fontWeight: FontWeight.w600, fontSize: 15),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          ),
        ),
        segmentedButtonTheme: SegmentedButtonThemeData(
          style: ButtonStyle(
            textStyle: const WidgetStatePropertyAll(
              TextStyle(fontFamily: 'Pretendard', fontWeight: FontWeight.w600, fontSize: 14),
            ),
          ),
        ),
        chipTheme: ChipThemeData(
          backgroundColor: Colors.white,
          selectedColor: const Color(0xFF4E6BFF),
          disabledColor: const Color(0xFFE5EAF7),
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          labelStyle: const TextStyle(fontFamily: 'Pretendard', fontWeight: FontWeight.w600, color: Color(0xFF44506C)),
          secondaryLabelStyle: const TextStyle(fontFamily: 'Pretendard', fontWeight: FontWeight.w600, color: Colors.white),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(999), side: BorderSide.none),
        ),
        dialogTheme: DialogThemeData(
          backgroundColor: Colors.white,
          surfaceTintColor: Colors.white,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
          titleTextStyle: const TextStyle(fontFamily: 'Pretendard', fontWeight: FontWeight.w700, fontSize: 20, color: Color(0xFF17203A)),
          contentTextStyle: const TextStyle(fontFamily: 'Pretendard', fontWeight: FontWeight.w400, fontSize: 14, height: 1.5, color: Color(0xFF44506C)),
        ),
        bottomSheetTheme: const BottomSheetThemeData(
          backgroundColor: Color(0xFFF7FAFD),
          surfaceTintColor: Color(0xFFF7FAFD),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
          ),
        ),
        cardTheme: CardThemeData(
          color: Color(0xF2FFFFFF),
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(24),
          ),
        ),
      ),
      home: EvidenceHomePage(repository: repository),
    );
  }
}

class EvidenceHomePage extends StatefulWidget {
  const EvidenceHomePage({super.key, required this.repository});

  final EvidenceRepository repository;

  @override
  State<EvidenceHomePage> createState() => _EvidenceHomePageState();
}

class _EvidenceHomePageState extends State<EvidenceHomePage> {
  List<EvidenceRecord> _records = const [];
  PromiseStatus? _statusFilter;
  String _searchQuery = '';
  int _selectedPage = 0;
  int _editorReturnPage = 0;
  EvidenceRecord? _editingRecord;
  bool _embeddedEditorSaving = false;
  GlobalKey<_EvidenceEditorPageState> _embeddedEditorKey = GlobalKey<_EvidenceEditorPageState>();

  @override
  void initState() {
    super.initState();
    _load();
    unawaited(EvidenceInterstitialAdService.instance.preload());
  }

  Future<void> _load() async {
    try {
      final records = await widget.repository.loadRecords();
      if (!mounted) return;
      setState(() => _records = records);
    } catch (_) {
      if (!mounted) return;
      setState(() => _records = const []);
      await showAppToast('데이터를 불러오지 못했습니다. 인터넷 연결을 확인해 주세요.');
    }
  }

  List<EvidenceRecord> get _filteredRecords {
    final query = _searchQuery.trim().toLowerCase();
    return _records.where((record) {
      final matchesStatus = _statusFilter == null || record.status == _statusFilter;
      final matchesQuery = query.isEmpty ||
          record.title.toLowerCase().contains(query) ||
          record.counterpartyName.toLowerCase().contains(query) ||
          record.memo.toLowerCase().contains(query);
      return matchesStatus && matchesQuery;
    }).toList()
      ..sort((a, b) => b.eventAt.compareTo(a.eventAt));
  }

  List<EvidenceRecord> get _sortedRecords => List<EvidenceRecord>.of(_records)
    ..sort((a, b) => b.eventAt.compareTo(a.eventAt));

  Future<void> _openEditor({EvidenceRecord? existing}) async {
    setState(() {
      _editorReturnPage = _selectedPage == 4 ? 0 : _selectedPage;
      _editingRecord = existing;
      _embeddedEditorKey = GlobalKey<_EvidenceEditorPageState>();
      _selectedPage = 4;
    });
  }

  Future<void> _openComposerInPlace() async {
    setState(() {
      _editorReturnPage = _selectedPage == 4 ? 0 : _selectedPage;
      _editingRecord = null;
      _embeddedEditorKey = GlobalKey<_EvidenceEditorPageState>();
      _selectedPage = 4;
    });
  }

  Future<void> _deleteRecord(EvidenceRecord record) async {
    final confirmed = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('기록 삭제'),
            content: Text('"${record.title}" 기록을 삭제할까요? 첨부/타임라인도 함께 제거됩니다.'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('취소'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('삭제'),
              ),
            ],
          ),
        ) ??
        false;
    if (!confirmed) return;
    await widget.repository.deleteRecord(record.id);
    await ReminderService.instance.cancel(record.notificationId);
    await _load();
    await showAppToast('기록을 삭제했습니다.');
  }

  Future<void> _exportRecordPdf(EvidenceRecord record) async {
    final languageCode = Localizations.localeOf(context).languageCode;
    final bytes = await _buildRecordPdfBytes(record, languageCode);
    await Printing.layoutPdf(onLayout: (_) async => bytes);
    unawaited(
      EvidenceBackendService.logPdfAction(
        record: record,
        action: 'export',
        fileName: '${_pdfSafeName(record.title)}_${record.id}.pdf',
        fileSizeBytes: bytes.length,
        locale: languageCode,
      ),
    );
  }

  Future<void> _shareRecordPdf(EvidenceRecord record) async {
    final languageCode = Localizations.localeOf(context).languageCode;
    final file = await _writeRecordPdfFile(record, languageCode);
    await SharePlus.instance.share(
      ShareParams(
        text: record.title,
        files: [XFile(file.path)],
      ),
    );
    final fileSize = await file.length();
    unawaited(
      EvidenceBackendService.logPdfAction(
        record: record,
        action: 'share',
        fileName: file.path.split(Platform.pathSeparator).last,
        fileSizeBytes: fileSize,
        locale: languageCode,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final filteredRecords = _filteredRecords;
    final sortedRecords = _sortedRecords;
    final unresolvedAmount = _records
        .where((record) => record.status != PromiseStatus.completed)
        .fold<double>(0, (sum, item) => sum + (item.amount ?? 0));
    final inProgressCount = _records.where((record) => record.status == PromiseStatus.inProgress).length;
    final unresolvedCount = _records.where((record) => record.status == PromiseStatus.unresolved).length;
    final completedCount = _records.where((record) => record.status == PromiseStatus.completed).length;
    final pages = [
      _OverviewPage(
        records: sortedRecords,
        unresolvedAmount: unresolvedAmount,
        inProgressCount: inProgressCount,
        unresolvedCount: unresolvedCount,
        completedCount: completedCount,
        onOpen: _openEditor,
      ),
      _RecordsPage(
        records: filteredRecords,
        statusFilter: _statusFilter,
        searchQuery: _searchQuery,
        unresolvedAmount: unresolvedAmount,
        inProgressCount: inProgressCount,
        unresolvedCount: unresolvedCount,
        completedCount: completedCount,
        onSearchChanged: (value) => setState(() => _searchQuery = value),
        onFilterChanged: (status) => setState(() => _statusFilter = status),
        onOpen: _openEditor,
        onDelete: _deleteRecord,
        onExportPdf: _exportRecordPdf,
        onSharePdf: _shareRecordPdf,
      ),
      _CalendarPage(
        records: sortedRecords,
        onOpen: _openEditor,
      ),
      _ActivityPage(
        records: sortedRecords,
        onOpen: _openEditor,
      ),
      EvidenceEditorPage(
        key: _embeddedEditorKey,
        repository: widget.repository,
        existing: _editingRecord,
        embedded: true,
        onSaved: () async {
          await _load();
          if (!mounted) return;
          setState(() {
            final targetPage = _editingRecord == null ? 1 : _editorReturnPage;
            _editingRecord = null;
            _embeddedEditorSaving = false;
            _selectedPage = targetPage;
          });
        },
        onCancel: () {
          if (!mounted) return;
          setState(() {
            _editingRecord = null;
            _embeddedEditorSaving = false;
            _selectedPage = _editorReturnPage;
          });
        },
        onSavingChanged: (saving) {
          if (!mounted) return;
          setState(() => _embeddedEditorSaving = saving);
        },
      ),
    ];

    return Scaffold(
      backgroundColor: const Color(0xFFF4F7FB),
      appBar: AppBar(
        toolbarHeight: 92,
        backgroundColor: const Color(0xFFF4F7FB),
        surfaceTintColor: Colors.transparent,
        scrolledUnderElevation: 0,
        elevation: 0,
        titleSpacing: 20,
        leading: _selectedPage == 4
            ? IconButton(
                onPressed: () => setState(() {
                  _editingRecord = null;
                  _selectedPage = _editorReturnPage;
                }),
                icon: const Icon(Icons.close_rounded),
              )
            : null,
        title: _HomeAppBarTitle(selectedPage: _selectedPage),
        actions: _selectedPage == 4
            ? [
                Padding(
                  padding: const EdgeInsets.only(right: 12),
                  child: FilledButton(
                    onPressed: _embeddedEditorSaving ? null : () => _embeddedEditorKey.currentState?.triggerSave(),
                    style: FilledButton.styleFrom(
                      backgroundColor: _embeddedEditorSaving ? const Color(0xFFBCC5D1) : const Color(0xFF183B56),
                      disabledBackgroundColor: const Color(0xFFBCC5D1),
                      foregroundColor: Colors.white,
                      disabledForegroundColor: Colors.white,
                      minimumSize: const Size(0, 42),
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 0),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (_embeddedEditorSaving) ...[
                          const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(
                              strokeWidth: 2.2,
                              valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                            ),
                          ),
                          const SizedBox(width: 8),
                        ],
                        Text(_embeddedEditorSaving ? tr(context, ko: '저장 중', en: 'Saving') : tr(context, ko: '저장', en: 'Save')),
                      ],
                    ),
                  ),
                ),
              ]
            : null,
      ),
      body: Stack(
        children: [
          const _EvidenceBackdrop(),
          SafeArea(
            top: true,
            bottom: false,
            child: IndexedStack(
              index: _selectedPage,
              children: pages,
            ),
          ),
          Align(
            alignment: Alignment.bottomCenter,
            child: Material(
              color: Colors.transparent,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _EvidenceBottomNav(
                    selectedIndex: _selectedPage,
                    onAdd: _openComposerInPlace,
                    onSelected: (index) => setState(() => _selectedPage = index),
                    items: const [
                      _EvidenceNavItemData(label: 'home', icon: Icons.home_rounded, color: Color(0xFF183B56)),
                      _EvidenceNavItemData(label: 'records', icon: Icons.sticky_note_2_rounded, color: Color(0xFF183B56)),
                      _EvidenceNavItemData(label: 'calendar', icon: Icons.calendar_month_rounded, color: Color(0xFF183B56)),
                      _EvidenceNavItemData(label: 'timeline', icon: Icons.timeline_rounded, color: Color(0xFF183B56)),
                    ],
                  ),
                  const SizedBox(height: 10),
                  const _AdMobBannerBar(),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _EvidenceBackdrop extends StatelessWidget {
  const _EvidenceBackdrop();

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            Color(0xFFF7F9FC),
            Color(0xFFEEF4FB),
            Color(0xFFF8FBFF),
          ],
        ),
      ),
      child: Stack(
        children: [
          Positioned(
            top: -90,
            left: -30,
            child: Container(
              width: 240,
              height: 240,
              decoration: const BoxDecoration(
                shape: BoxShape.circle,
                gradient: RadialGradient(
                  colors: [Color(0x66BFD6FF), Color(0x00BFD6FF)],
                ),
              ),
            ),
          ),
          Positioned(
            top: 140,
            right: -50,
            child: Container(
              width: 220,
              height: 220,
              decoration: const BoxDecoration(
                shape: BoxShape.circle,
                gradient: RadialGradient(
                  colors: [Color(0x55D5F1E8), Color(0x00D5F1E8)],
                ),
              ),
            ),
          ),
          Positioned(
            bottom: -100,
            left: 20,
            child: Container(
              width: 280,
              height: 280,
              decoration: const BoxDecoration(
                shape: BoxShape.circle,
                gradient: RadialGradient(
                  colors: [Color(0x44FFE6C9), Color(0x00FFE6C9)],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _HomeAppBarTitle extends StatelessWidget {
  const _HomeAppBarTitle({required this.selectedPage});

  final int selectedPage;

  @override
  Widget build(BuildContext context) {
    final (title, subtitle) = switch (selectedPage) {
      0 => (
          tr(context, ko: '증거노트', en: 'Evidence Note'),
          tr(context, ko: '약속과 거래 기록을 더 정돈된 증거 흐름으로 관리', en: 'Keep promises and transactions in a more structured evidence flow'),
        ),
      1 => (
          tr(context, ko: '기록 관리', en: 'Records'),
          tr(context, ko: '저장된 약속과 거래를 빠르게 탐색', en: 'Browse saved promises and transactions quickly'),
        ),
      2 => (
          tr(context, ko: '달력 보기', en: 'Calendar'),
          tr(context, ko: '기록일과 만기 일정을 달력에서 함께 확인', en: 'See record dates and due dates together on the calendar'),
        ),
      3 => (
          tr(context, ko: '타임라인', en: 'Timeline'),
          tr(context, ko: '생성부터 첨부까지 흐름을 한눈에 확인', en: 'Track the flow from creation to attachments at a glance'),
        ),
      _ => (
          tr(context, ko: '새 기록 만들기', en: 'New Record'),
          tr(context, ko: '하단 네비는 유지한 채 기록 작성 화면으로 전환됩니다.', en: 'Create a record while keeping the bottom navigation fixed'),
        ),
    };
    final isHomePage = selectedPage == 0;
    final showSubtitle = selectedPage != 4;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Text(
          title,
          style: TextStyle(
            fontFamily: 'Pretendard',
            fontSize: isHomePage ? 27 : 26,
            fontWeight: FontWeight.w800,
            color: const Color(0xFF17203A),
            letterSpacing: isHomePage ? -0.8 : -0.5,
          ),
        ),
        if (showSubtitle) ...[
          const SizedBox(height: 4),
          Text(
            subtitle,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontFamily: 'Pretendard',
              fontSize: isHomePage ? 13.5 : 13,
              fontWeight: FontWeight.w500,
              color: const Color(0xFF66718F),
              height: 1.28,
            ),
          ),
        ],
      ],
    );
  }
}

class _OverviewPage extends StatelessWidget {
  const _OverviewPage({
    required this.records,
    required this.unresolvedAmount,
    required this.inProgressCount,
    required this.unresolvedCount,
    required this.completedCount,
    required this.onOpen,
  });

  final List<EvidenceRecord> records;
  final double unresolvedAmount;
  final int inProgressCount;
  final int unresolvedCount;
  final int completedCount;
  final Future<void> Function({EvidenceRecord? existing}) onOpen;

  @override
  Widget build(BuildContext context) {
    final latest = records.take(3).toList();
    final urgentRecord = records.where((record) => record.status != PromiseStatus.completed).cast<EvidenceRecord?>().firstWhere(
          (record) => record != null,
          orElse: () => records.isNotEmpty ? records.first : null,
        );
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 170),
      children: [
        _HeroHeaderCard(
          unresolvedAmount: unresolvedAmount,
          inProgressCount: inProgressCount,
          unresolvedCount: unresolvedCount,
          completedCount: completedCount,
        ),
        const SizedBox(height: 18),
        _SectionShell(
          title: '지금 확인할 기록',
          subtitle: urgentRecord == null ? '먼저 기록을 만들면 우선 확인할 항목이 여기에 표시됩니다.' : '지금 가장 먼저 확인하기 좋은 기록을 한 장으로 보여줍니다.',
          child: urgentRecord == null
              ? const _EmptyState(
                  title: '표시할 기록이 없습니다',
                  body: '기록을 추가하면 홈에서 우선 확인할 항목을 먼저 보여드립니다.',
                )
              : _PinnedRecordFeature(
                  record: urgentRecord,
                  onTap: () => onOpen(existing: urgentRecord),
                ),
        ),
        const SizedBox(height: 18),
        _SectionShell(
          title: '최근 기록',
          subtitle: '최근 저장한 약속과 거래를 빠르게 다시 열 수 있습니다.',
          child: latest.isEmpty
              ? const _EmptyState(
                  title: '아직 기록이 없습니다',
                  body: '첫 기록을 만들면 홈에서 핵심 현황과 최근 항목을 바로 확인할 수 있습니다.',
                )
              : Column(
                  children: latest.map((record) {
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 10),
                      child: _RecentRecordTile(
                        record: record,
                        onTap: () => onOpen(existing: record),
                      ),
                    );
                  }).toList(),
                ),
        ),
      ],
    );
  }
}

class _RecordsPage extends StatelessWidget {
  const _RecordsPage({
    required this.records,
    required this.statusFilter,
    required this.searchQuery,
    required this.unresolvedAmount,
    required this.inProgressCount,
    required this.unresolvedCount,
    required this.completedCount,
    required this.onSearchChanged,
    required this.onFilterChanged,
    required this.onOpen,
    required this.onDelete,
    required this.onExportPdf,
    required this.onSharePdf,
  });

  final List<EvidenceRecord> records;
  final PromiseStatus? statusFilter;
  final String searchQuery;
  final double unresolvedAmount;
  final int inProgressCount;
  final int unresolvedCount;
  final int completedCount;
  final ValueChanged<String> onSearchChanged;
  final ValueChanged<PromiseStatus?> onFilterChanged;
  final Future<void> Function({EvidenceRecord? existing}) onOpen;
  final Future<void> Function(EvidenceRecord record) onDelete;
  final Future<void> Function(EvidenceRecord record) onExportPdf;
  final Future<void> Function(EvidenceRecord record) onSharePdf;

  @override
  Widget build(BuildContext context) {
    final languageCode = Localizations.localeOf(context).languageCode;
    if (records.isEmpty) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 170),
        child: _EmptyState(
          title: tr(context, ko: '아직 기록이 없습니다', en: 'No records yet'),
          body: tr(context, ko: '새 기록을 만들면 거래/약속/증거가 타임라인으로 정리됩니다.', en: 'Create your first record to organize promises, transactions, and evidence in a timeline.'),
        ),
      );
    }

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: _CompactMetricChip(
                      label: tr(context, ko: '진행중', en: 'In Progress'),
                      value: languageCode == 'ko' ? '$inProgressCount건' : '$inProgressCount items',
                      accent: const Color(0xFF3457F1),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: _CompactMetricChip(
                      label: tr(context, ko: '미해결', en: 'Unresolved'),
                      value: languageCode == 'ko' ? '$unresolvedCount건' : '$unresolvedCount items',
                      accent: const Color(0xFFD97706),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: _CompactMetricChip(
                      label: tr(context, ko: '완료', en: 'Completed'),
                      value: languageCode == 'ko' ? '$completedCount건' : '$completedCount items',
                      accent: const Color(0xFF16865A),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              _CompactMetricChip(
                label: tr(context, ko: '미회수 금액', en: 'Outstanding Amount'),
                value: formatAmount(unresolvedAmount),
                accent: const Color(0xFF48617D),
              ),
              const SizedBox(height: 14),
              _GlassSearchField(
                searchQuery: searchQuery,
                onChanged: onSearchChanged,
              ),
              const SizedBox(height: 12),
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                    _ModernFilterChip(
                      label: tr(context, ko: '전체', en: 'All'),
                      selected: statusFilter == null,
                      onTap: () => onFilterChanged(null),
                    ),
                    const SizedBox(width: 8),
                    ...PromiseStatus.values.map(
                      (status) => Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: _ModernFilterChip(
                          label: status.localizedLabel(languageCode),
                          selected: statusFilter == status,
                          onTap: () => onFilterChanged(status),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: _PromiseListTab(
            records: records,
            onOpen: onOpen,
            onDelete: onDelete,
            onExportPdf: onExportPdf,
            onSharePdf: onSharePdf,
          ),
        ),
      ],
    );
  }
}

class _ActivityPage extends StatelessWidget {
  const _ActivityPage({
    required this.records,
    required this.onOpen,
  });

  final List<EvidenceRecord> records;
  final Future<void> Function({EvidenceRecord? existing}) onOpen;

  @override
  Widget build(BuildContext context) {
    final languageCode = Localizations.localeOf(context).languageCode;
    final totalEvents = records.fold<int>(0, (sum, record) => sum + record.timeline.length);
    if (totalEvents == 0) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 170),
        child: _EmptyState(
          title: tr(context, ko: '타임라인이 비어 있습니다', en: 'Timeline is empty'),
          body: tr(context, ko: '기록을 저장하면 생성·수정·증거 첨부 이력이 직설적으로 쌓입니다.', en: 'Once you save records, creation, edits, and attachments will build up here.'),
        ),
      );
    }

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
          child: Column(
            children: [
              Row(
                children: [
                  Expanded(
                    child: _CompactMetricChip(
                      label: tr(context, ko: '전체 이벤트', en: 'Events'),
                      value: languageCode == 'ko' ? '$totalEvents건' : '$totalEvents items',
                      accent: const Color(0xFF0F766E),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: _CompactMetricChip(
                      label: tr(context, ko: '기록 수', en: 'Records'),
                      value: languageCode == 'ko' ? '${records.length}건' : '${records.length} items',
                      accent: const Color(0xFF3457F1),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
        Expanded(
          child: _TimelineTab(records: records, onOpen: onOpen),
        ),
      ],
    );
  }
}

class _CalendarPage extends StatefulWidget {
  const _CalendarPage({
    required this.records,
    required this.onOpen,
  });

  final List<EvidenceRecord> records;
  final Future<void> Function({EvidenceRecord? existing}) onOpen;

  @override
  State<_CalendarPage> createState() => _CalendarPageState();
}

class _CalendarPageState extends State<_CalendarPage> {
  DateTime _focusedDay = DateTime.now();
  DateTime? _selectedDay;

  List<EvidenceRecord> _eventsForDay(DateTime day) {
    final normalized = DateTime(day.year, day.month, day.day);
    return widget.records.where((record) {
      final eventDay = DateTime(record.eventAt.year, record.eventAt.month, record.eventAt.day);
      final dueDay = record.dueAt == null
          ? null
          : DateTime(record.dueAt!.year, record.dueAt!.month, record.dueAt!.day);
      return eventDay == normalized || dueDay == normalized;
    }).toList();
  }

  @override
  Widget build(BuildContext context) {
    final languageCode = Localizations.localeOf(context).languageCode;
    final selectedDay = _selectedDay ?? _focusedDay;
    final selectedRecords = _eventsForDay(selectedDay);
    final upcomingDue = widget.records
        .where((record) => record.dueAt != null && record.status != PromiseStatus.completed)
        .toList()
      ..sort((a, b) => a.dueAt!.compareTo(b.dueAt!));

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 10),
          child: Row(
            children: [
              Expanded(
                child: _CompactMetricChip(
                  label: tr(context, ko: '이번 달 기록', en: 'This Month'),
                  value: languageCode == 'ko'
                      ? '${widget.records.where((record) => record.eventAt.year == _focusedDay.year && record.eventAt.month == _focusedDay.month).length}건'
                      : '${widget.records.where((record) => record.eventAt.year == _focusedDay.year && record.eventAt.month == _focusedDay.month).length} items',
                  accent: const Color(0xFF3457F1),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _CompactMetricChip(
                  label: tr(context, ko: '예정 만기', en: 'Upcoming Due'),
                  value: languageCode == 'ko'
                      ? '${upcomingDue.where((record) => record.dueAt!.isAfter(DateTime.now().subtract(const Duration(days: 1)))).length}건'
                      : '${upcomingDue.where((record) => record.dueAt!.isAfter(DateTime.now().subtract(const Duration(days: 1)))).length} items',
                  accent: const Color(0xFF7C3AED),
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 170),
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(28),
                child: BackdropFilter(
                  filter: ImageFilter.blur(sigmaX: 8, sigmaY: 8),
                  child: Container(
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.7),
                      borderRadius: BorderRadius.circular(28),
                      border: Border.all(color: Colors.white.withValues(alpha: 0.92)),
                    ),
                    child: TableCalendar<EvidenceRecord>(
                      locale: useKorean(context) ? 'ko_KR' : 'en_US',
                      firstDay: DateTime.utc(2020, 1, 1),
                      lastDay: DateTime.utc(2100, 12, 31),
                      focusedDay: _focusedDay,
                      selectedDayPredicate: (day) => isSameDay(_selectedDay, day),
                      eventLoader: _eventsForDay,
                      calendarFormat: CalendarFormat.month,
                      startingDayOfWeek: StartingDayOfWeek.monday,
                      headerStyle: const HeaderStyle(
                        titleCentered: true,
                        formatButtonVisible: false,
                        titleTextStyle: TextStyle(fontSize: 20, fontWeight: FontWeight.w800, color: Color(0xFF17203A)),
                      ),
                      calendarStyle: CalendarStyle(
                        outsideDaysVisible: false,
                        todayDecoration: BoxDecoration(
                          color: const Color(0xFFDBE8FF),
                          borderRadius: BorderRadius.circular(16),
                        ),
                        selectedDecoration: BoxDecoration(
                          color: const Color(0xFF183B56),
                          borderRadius: BorderRadius.circular(16),
                        ),
                        selectedTextStyle: const TextStyle(
                          color: Color(0xFF17203A),
                          fontWeight: FontWeight.w700,
                        ),
                        markerDecoration: const BoxDecoration(
                          color: Color(0xFF7C3AED),
                          shape: BoxShape.circle,
                        ),
                        defaultTextStyle: const TextStyle(fontWeight: FontWeight.w600),
                        weekendTextStyle: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                      onDaySelected: (selectedDay, focusedDay) {
                        setState(() {
                          _selectedDay = selectedDay;
                          _focusedDay = focusedDay;
                        });
                      },
                      onPageChanged: (focusedDay) {
                        setState(() => _focusedDay = focusedDay);
                      },
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 14),
              _SectionShell(
                title: tr(context, ko: '선택한 날짜', en: 'Selected Date'),
                subtitle: tr(context, ko: '${formatDate(selectedDay)} 기준 기록일과 만기 일정이 함께 표시됩니다.', en: 'Record dates and due dates for ${formatDate(selectedDay)} are shown together.'),
                child: selectedRecords.isEmpty
                    ? Text(
                        tr(context, ko: '선택한 날짜에 연결된 기록이 없습니다.', en: 'There are no records linked to the selected date.'),
                        style: TextStyle(color: Color(0xFF66718F), height: 1.45),
                      )
                    : Column(
                        children: selectedRecords
                            .map(
                              (record) => _CalendarRecordTile(
                                record: record,
                                selectedDay: selectedDay,
                                onTap: () => widget.onOpen(existing: record),
                              ),
                            )
                            .toList(),
                      ),
              ),
              const SizedBox(height: 14),
              _SectionShell(
                title: tr(context, ko: '다가오는 만기', en: 'Upcoming Due Dates'),
                subtitle: tr(context, ko: '완료되지 않은 기록 중 기한이 가까운 항목을 우선적으로 확인합니다.', en: 'Prioritize unfinished records with nearby due dates.'),
                child: upcomingDue.isEmpty
                    ? Text(
                        tr(context, ko: '아직 설정된 만기 일정이 없습니다.', en: 'No due dates have been set yet.'),
                        style: TextStyle(color: Color(0xFF66718F), height: 1.45),
                      )
                    : Column(
                        children: upcomingDue.take(4).map((record) {
                          final dueAt = record.dueAt!;
                          return Padding(
                            padding: const EdgeInsets.only(bottom: 10),
                            child: _CalendarRecordTile(
                              record: record,
                              selectedDay: DateTime(dueAt.year, dueAt.month, dueAt.day),
                              onTap: () => widget.onOpen(existing: record),
                            ),
                          );
                        }).toList(),
                      ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _HeroHeaderCard extends StatelessWidget {
  const _HeroHeaderCard({
    required this.unresolvedAmount,
    required this.inProgressCount,
    required this.unresolvedCount,
    required this.completedCount,
  });

  final double unresolvedAmount;
  final int inProgressCount;
  final int unresolvedCount;
  final int completedCount;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        return Container(
          padding: const EdgeInsets.all(22),
          constraints: const BoxConstraints(minHeight: 300),
          decoration: BoxDecoration(
            gradient: const LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                Color(0xFF102A43),
                Color(0xFF183B56),
                Color(0xFF2563EB),
              ],
            ),
            borderRadius: BorderRadius.circular(36),
            boxShadow: const [
              BoxShadow(
                color: Color(0x22183B56),
                blurRadius: 34,
                offset: Offset(0, 20),
              ),
            ],
          ),
          child: Stack(
            children: [
              Positioned(
                right: -34,
                top: -18,
                child: Container(
                  width: 180,
                  height: 180,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: Colors.white.withValues(alpha: 0.08),
                  ),
                  ),
                ),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    '메모가 아니라,\n정리된 증거처럼.',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 28,
                      height: 1.12,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                  const SizedBox(height: 10),
                  const Text(
                    '차용, 거래, 정산 기록을 단정한 카드와 타임라인으로 남겨 필요한 순간 바로 꺼내볼 수 있게 합니다.',
                    maxLines: 4,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: Color(0xDCEAF2FF),
                      height: 1.5,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  const SizedBox(height: 18),
                  Row(
                    children: [
                      Expanded(child: _HeroStatPill(label: '진행중', value: '$inProgressCount건')),
                      const SizedBox(width: 10),
                      Expanded(child: _HeroStatPill(label: '미해결', value: '$unresolvedCount건')),
                      const SizedBox(width: 10),
                      Expanded(child: _HeroStatPill(label: '완료', value: '$completedCount건')),
                    ],
                  ),
                  const SizedBox(height: 18),
                  Align(
                    alignment: Alignment.topCenter,
                    child: _HeroAmountOrb(amount: unresolvedAmount),
                  ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }
}

class _PageTitleBlock extends StatelessWidget {
  const _PageTitleBlock({
    required this.title,
    required this.subtitle,
  });

  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: const TextStyle(
            color: Color(0xFF17203A),
            fontSize: 28,
            fontWeight: FontWeight.w900,
            height: 1.15,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          subtitle,
          style: const TextStyle(
            color: Color(0xFF66718F),
            height: 1.5,
          ),
        ),
      ],
    );
  }
}

class _StatCard extends StatelessWidget {
  const _StatCard({
    required this.title,
    required this.value,
    required this.caption,
    required this.tint,
    required this.accent,
  });

  final String title;
  final String value;
  final String caption;
  final Color tint;
  final Color accent;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: tint.withValues(alpha: 0.82),
        borderRadius: BorderRadius.circular(26),
        border: Border.all(color: Colors.white.withValues(alpha: 0.9)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: TextStyle(color: accent, fontWeight: FontWeight.w700)),
          const SizedBox(height: 10),
          Text(
            value,
            style: const TextStyle(
              color: Color(0xFF17203A),
              fontSize: 22,
              fontWeight: FontWeight.w900,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            caption,
            style: const TextStyle(color: Color(0xFF66718F), height: 1.45),
          ),
        ],
      ),
    );
  }
}

class _ActionCard extends StatelessWidget {
  const _ActionCard({required this.onTap});

  final Future<void> Function({EvidenceRecord? existing}) onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(26),
      child: Container(
        padding: const EdgeInsets.all(18),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.7),
          borderRadius: BorderRadius.circular(26),
          border: Border.all(color: Colors.white.withValues(alpha: 0.95)),
        ),
        child: const Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.add_circle_outline_rounded, color: Color(0xFF183B56), size: 28),
            SizedBox(height: 12),
            Text(
              '새 기록 추가',
              style: TextStyle(
                color: Color(0xFF17203A),
                fontWeight: FontWeight.w800,
              ),
            ),
            SizedBox(height: 6),
            Text(
              '증거와 메모를 새 페이지에서 차분히 입력합니다.',
              style: TextStyle(color: Color(0xFF66718F), height: 1.45),
            ),
          ],
        ),
      ),
    );
  }
}

class _HomeSpotlightCard extends StatelessWidget {
  const _HomeSpotlightCard({
    required this.title,
    required this.headline,
    required this.body,
    required this.accent,
    required this.gradient,
    required this.icon,
    required this.onTap,
  });

  final String title;
  final String headline;
  final String body;
  final Color accent;
  final List<Color> gradient;
  final IconData icon;
  final Future<void> Function({EvidenceRecord? existing}) onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(30),
      child: Ink(
        padding: const EdgeInsets.all(18),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: gradient,
          ),
          borderRadius: BorderRadius.circular(30),
          border: Border.all(color: Colors.white.withValues(alpha: 0.95)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: accent.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Icon(icon, color: accent),
                ),
                const Spacer(),
                Text(
                  title,
                  style: TextStyle(
                    color: accent,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
            const Spacer(),
            Text(
              headline,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: Color(0xFF17203A),
                fontWeight: FontWeight.w900,
                fontSize: 22,
                height: 1.1,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              body,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: Color(0xFF66718F),
                height: 1.45,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _MiniMetricPanel extends StatelessWidget {
  const _MiniMetricPanel({
    required this.label,
    required this.value,
    required this.accent,
  });

  final String label;
  final String value;
  final Color accent;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.7),
        borderRadius: BorderRadius.circular(26),
        border: Border.all(color: Colors.white.withValues(alpha: 0.95)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: TextStyle(
              color: accent,
              fontWeight: FontWeight.w700,
            ),
          ),
          const Spacer(),
          Text(
            value,
            style: const TextStyle(
              color: Color(0xFF17203A),
              fontWeight: FontWeight.w900,
              fontSize: 18,
            ),
          ),
        ],
      ),
    );
  }
}

class _PinnedRecordFeature extends StatelessWidget {
  const _PinnedRecordFeature({
    required this.record,
    required this.onTap,
  });

  final EvidenceRecord record;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(28),
      child: Container(
        padding: const EdgeInsets.all(18),
        decoration: BoxDecoration(
          gradient: const LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              Color(0xFFFDFEFE),
              Color(0xFFF6FAFF),
            ],
          ),
          borderRadius: BorderRadius.circular(28),
          border: Border.all(color: const Color(0xFFE6EDF5)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
                  decoration: BoxDecoration(
                    color: record.status.color.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Text(
                    record.status.label,
                    style: TextStyle(
                      color: record.status.color,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                const Spacer(),
                const Icon(Icons.north_east_rounded, color: Color(0xFF8392A5)),
              ],
            ),
            const SizedBox(height: 16),
            Text(
              record.title,
              style: const TextStyle(
                color: Color(0xFF17203A),
                fontWeight: FontWeight.w900,
                fontSize: 24,
                height: 1.15,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              record.memo.trim().isEmpty ? '${record.counterpartyName} 관련 기록입니다.' : record.memo,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: Color(0xFF66718F),
                height: 1.5,
              ),
            ),
            const SizedBox(height: 18),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _PinnedMeta(label: '상대', value: record.counterpartyName),
                _PinnedMeta(label: '시점', value: formatDateTime(record.eventAt)),
                if (record.dueAt != null) _PinnedMeta(label: '만기', value: formatDate(record.dueAt!)),
                if (record.amount != null) _PinnedMeta(label: '금액', value: formatAmount(record.amount!)),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _PinnedMeta extends StatelessWidget {
  const _PinnedMeta({
    required this.label,
    required this.value,
  });

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: const Color(0xFFF3F6FA),
        borderRadius: BorderRadius.circular(16),
      ),
      child: RichText(
        text: TextSpan(
          style: const TextStyle(fontFamily: 'Pretendard'),
          children: [
            TextSpan(
              text: '$label ',
              style: const TextStyle(
                color: Color(0xFF7B8798),
                fontWeight: FontWeight.w600,
              ),
            ),
            TextSpan(
              text: value,
              style: const TextStyle(
                color: Color(0xFF17203A),
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _HeroAmountOrb extends StatelessWidget {
  const _HeroAmountOrb({required this.amount});

  final double amount;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 118,
      height: 118,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Text(
            '미회수',
            style: TextStyle(
              color: Color(0xDCEAF2FF),
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            formatAmount(amount).replaceAll('원', ''),
            textAlign: TextAlign.center,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.w900,
              fontSize: 18,
              height: 1.05,
            ),
          ),
          const SizedBox(height: 2),
          const Text(
            'KRW',
            style: TextStyle(
              color: Color(0xBFEAF2FF),
              fontWeight: FontWeight.w700,
              letterSpacing: 0.8,
            ),
          ),
        ],
      ),
    );
  }
}

class _HeroStatPill extends StatelessWidget {
  const _HeroStatPill({
    required this.label,
    required this.value,
  });

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: Colors.white.withValues(alpha: 0.12)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Text(
            label,
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: Color(0xCDEAF2FF),
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 4),
          FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(
              value,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _HeroInlineButton extends StatelessWidget {
  const _HeroInlineButton({required this.onTap});

  final Future<void> Function({EvidenceRecord? existing}) onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(999),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(999),
        ),
        child: const Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.add_rounded, color: Color(0xFF183B56), size: 18),
            SizedBox(width: 8),
            Text(
              '새 기록 열기',
              style: TextStyle(
                color: Color(0xFF183B56),
                fontWeight: FontWeight.w800,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SectionShell extends StatelessWidget {
  const _SectionShell({
    required this.title,
    required this.subtitle,
    required this.child,
  });

  final String title;
  final String subtitle;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(30),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 8, sigmaY: 8),
        child: Container(
          padding: const EdgeInsets.all(18),
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.62),
            borderRadius: BorderRadius.circular(30),
            border: Border.all(color: Colors.white.withValues(alpha: 0.9)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: const TextStyle(
                  color: Color(0xFF17203A),
                  fontWeight: FontWeight.w900,
                  fontSize: 20,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                subtitle,
                style: const TextStyle(color: Color(0xFF66718F), height: 1.45),
              ),
              const SizedBox(height: 16),
              child,
            ],
          ),
        ),
      ),
    );
  }
}

class _RecentRecordTile extends StatelessWidget {
  const _RecentRecordTile({
    required this.record,
    required this.onTap,
  });

  final EvidenceRecord record;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(24),
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.9),
          borderRadius: BorderRadius.circular(24),
        ),
        child: Row(
          children: [
            Container(
              width: 48,
              height: 48,
              decoration: BoxDecoration(
                color: record.status.color.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(16),
              ),
              child: Icon(Icons.article_outlined, color: record.status.color),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    record.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontWeight: FontWeight.w800,
                      color: Color(0xFF17203A),
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    record.dueAt == null
                        ? '${record.counterpartyName} · ${formatDateTime(record.eventAt)}'
                        : '${record.counterpartyName} · 만기 ${formatDate(record.dueAt!)}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: Color(0xFF66718F)),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
              decoration: BoxDecoration(
                color: record.status.color.withValues(alpha: 0.14),
                borderRadius: BorderRadius.circular(999),
              ),
              child: Text(
                record.status.label,
                style: TextStyle(
                  color: record.status.color,
                  fontWeight: FontWeight.w700,
                  fontSize: 12,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _CalendarRecordTile extends StatelessWidget {
  const _CalendarRecordTile({
    required this.record,
    required this.selectedDay,
    required this.onTap,
  });

  final EvidenceRecord record;
  final DateTime selectedDay;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final recordDay = DateTime(record.eventAt.year, record.eventAt.month, record.eventAt.day);
    final dueDay = record.dueAt == null ? null : DateTime(record.dueAt!.year, record.dueAt!.month, record.dueAt!.day);
    final normalizedSelectedDay = DateTime(selectedDay.year, selectedDay.month, selectedDay.day);
    final matchesRecordDay = recordDay == normalizedSelectedDay;
    final matchesDueDay = dueDay == normalizedSelectedDay;

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(24),
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.9),
          borderRadius: BorderRadius.circular(24),
          border: Border.all(color: const Color(0xFFE2E8F2)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    record.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w800, color: Color(0xFF17203A)),
                  ),
                ),
                buildPill(record.status.label, record.status.color.withValues(alpha: 0.14), record.status.color),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              record.counterpartyName,
              style: const TextStyle(color: Color(0xFF66718F), fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                if (matchesRecordDay) buildPill('기록 ${formatDateTime(record.eventAt)}', const Color(0xFFEAF0FF), const Color(0xFF3457F1)),
                if (matchesDueDay && record.dueAt != null) buildPill('만기 ${formatDateTime(record.dueAt!)}', const Color(0xFFF4EFFF), const Color(0xFF7C3AED)),
                if (record.reminderAt != null) buildPill('알림 ${formatDateTime(record.reminderAt!)}', const Color(0xFFFFF4E8), const Color(0xFFD97706)),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _CompactMetricChip extends StatelessWidget {
  const _CompactMetricChip({
    required this.label,
    required this.value,
    required this.accent,
  });

  final String label;
  final String value;
  final Color accent;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(22),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 6, sigmaY: 6),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.55),
            borderRadius: BorderRadius.circular(22),
            border: Border.all(color: Colors.white.withValues(alpha: 0.9)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label, style: TextStyle(color: accent, fontWeight: FontWeight.w700)),
              const SizedBox(height: 4),
              Text(
                value,
                style: const TextStyle(
                  color: Color(0xFF17203A),
                  fontWeight: FontWeight.w800,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _GlassSearchField extends StatefulWidget {
  const _GlassSearchField({
    required this.searchQuery,
    required this.onChanged,
  });

  final String searchQuery;
  final ValueChanged<String> onChanged;

  @override
  State<_GlassSearchField> createState() => _GlassSearchFieldState();
}

class _GlassSearchFieldState extends State<_GlassSearchField> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.searchQuery);
  }

  @override
  void didUpdateWidget(covariant _GlassSearchField oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.searchQuery != _controller.text) {
      _controller.value = TextEditingValue(
        text: widget.searchQuery,
        selection: TextSelection.collapsed(offset: widget.searchQuery.length),
      );
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: _controller,
      onChanged: widget.onChanged,
      decoration: InputDecoration(
        hintText: tr(context, ko: '제목, 상대, 메모 검색', en: 'Search title, person, memo'),
        prefixIcon: const Icon(Icons.search_rounded),
        filled: true,
        fillColor: Colors.white.withValues(alpha: 0.86),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(22),
          borderSide: BorderSide.none,
        ),
      ),
    );
  }
}

class _ModernFilterChip extends StatelessWidget {
  const _ModernFilterChip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return ChoiceChip(
      label: Text(label),
      selected: selected,
      onSelected: (_) => onTap(),
      labelStyle: TextStyle(
        fontWeight: FontWeight.w700,
        color: selected ? Colors.white : const Color(0xFF44506C),
      ),
      selectedColor: const Color(0xFF3457F1),
      backgroundColor: Colors.white.withValues(alpha: 0.86),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(999),
        side: BorderSide.none,
      ),
      showCheckmark: false,
    );
  }
}

class _EvidenceBottomNav extends StatelessWidget {
  const _EvidenceBottomNav({
    required this.items,
    required this.selectedIndex,
    required this.onSelected,
    required this.onAdd,
  });

  final List<_EvidenceNavItemData> items;
  final int selectedIndex;
  final ValueChanged<int> onSelected;
  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 8, 14, 0),
        child: SizedBox(
          height: 118,
          child: Stack(
            clipBehavior: Clip.none,
            alignment: Alignment.bottomCenter,
            children: [
              Positioned.fill(
                top: 26,
                child: ClipPath(
                  clipper: const _BottomNavGlassClipper(),
                  child: BackdropFilter(
                    filter: ImageFilter.blur(sigmaX: 8, sigmaY: 8),
                    child: Container(
                      padding: const EdgeInsets.fromLTRB(10, 12, 10, 10),
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.3),
                        borderRadius: BorderRadius.circular(30),
                        border: Border.all(color: Colors.white.withValues(alpha: 0.65)),
                        boxShadow: const [
                          BoxShadow(
                            color: Color(0x14000000),
                            blurRadius: 24,
                            offset: Offset(0, 12),
                          ),
                        ],
                      ),
                      child: Row(
                        children: [
                          Expanded(
                            child: _EvidenceBottomNavItem(
                              data: items[0],
                              isSelected: selectedIndex == 0,
                              onTap: () => onSelected(0),
                            ),
                          ),
                          Expanded(
                            child: _EvidenceBottomNavItem(
                              data: items[1],
                              isSelected: selectedIndex == 1,
                              onTap: () => onSelected(1),
                            ),
                          ),
                          const SizedBox(width: 74),
                          Expanded(
                            child: _EvidenceBottomNavItem(
                              data: items[2],
                              isSelected: selectedIndex == 2,
                              onTap: () => onSelected(2),
                            ),
                          ),
                          Expanded(
                            child: _EvidenceBottomNavItem(
                              data: items[3],
                              isSelected: selectedIndex == 3,
                              onTap: () => onSelected(3),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
              Positioned(
                top: 7,
                child: _EvidenceAddButton(
                  onTap: onAdd,
                  isSelected: selectedIndex == 4,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _EvidenceAddButton extends StatelessWidget {
  const _EvidenceAddButton({
    required this.onTap,
    required this.isSelected,
  });

  final VoidCallback onTap;
  final bool isSelected;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(28),
        child: Ink(
          width: 68,
          height: 68,
          decoration: BoxDecoration(
            color: isSelected
                ? const Color(0xFF183B56)
                : Colors.white.withValues(alpha: 1),
            borderRadius: BorderRadius.circular(28),
            border: Border.all(
              color: isSelected ? const Color(0xFF183B56) : const Color(0xFFD2DCE8),
              width: 1.8,
            ),
            boxShadow: [
              BoxShadow(
                color: isSelected
                    ? const Color(0xFF183B56).withValues(alpha: 0.10)
                    : Colors.white.withValues(alpha: 0.18),
                blurRadius: 10,
                offset: const Offset(0, 1),
              ),
            ],
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                Icons.add_rounded,
                color: isSelected ? Colors.white : const Color(0xFF183B56),
                size: 26,
              ),
              const SizedBox(height: 2),
              Text(
                '추가',
                style: TextStyle(
                  color: isSelected ? Colors.white : const Color(0xFF183B56),
                  fontSize: 11,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _EvidenceBottomNavItem extends StatelessWidget {
  const _EvidenceBottomNavItem({
    required this.data,
    required this.isSelected,
    required this.onTap,
  });

  final _EvidenceNavItemData data;
  final bool isSelected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final languageCode = Localizations.localeOf(context).languageCode;
    final localizedLabel = switch (data.label) {
      'home' => languageCode == 'ko' ? '홈' : 'Home',
      'records' => languageCode == 'ko' ? '기록' : 'Records',
      'calendar' => languageCode == 'ko' ? '달력' : 'Calendar',
      'timeline' => languageCode == 'ko' ? '타임라인' : 'Timeline',
      _ => data.label,
    };
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(24),
          onTap: onTap,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 220),
            curve: Curves.easeOutCubic,
            decoration: BoxDecoration(
              color: isSelected ? data.color.withValues(alpha: 0.16) : Colors.transparent,
              borderRadius: BorderRadius.circular(24),
            ),
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  AnimatedContainer(
                    duration: const Duration(milliseconds: 220),
                    width: isSelected ? 40 : 36,
                    height: isSelected ? 40 : 36,
                    decoration: BoxDecoration(
                      color: isSelected ? data.color : const Color(0xFFF0F4F1),
                      borderRadius: BorderRadius.circular(15),
                    ),
                    child: Icon(
                      data.icon,
                      color: isSelected ? Colors.white : const Color(0xFF5F6F65),
                      size: 20,
                    ),
                  ),
                  const SizedBox(height: 5),
                  Text(
                    localizedLabel,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 10,
                      height: 1,
                      fontWeight: FontWeight.w700,
                      color: isSelected ? data.color : const Color(0xFF5F6F65),
                    ),
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

class _EvidenceNavItemData {
  const _EvidenceNavItemData({
    required this.label,
    required this.icon,
    required this.color,
  });

  final String label;
  final IconData icon;
  final Color color;
}

class _AdMobBannerBar extends StatefulWidget {
  const _AdMobBannerBar();

  @override
  State<_AdMobBannerBar> createState() => _AdMobBannerBarState();
}

class _AdMobBannerBarState extends State<_AdMobBannerBar> {
  BannerAd? _bannerAd;
  bool _loaded = false;
  int? _loadedWidth;

  String get _fallbackAdUnitId {
    if (Platform.isAndroid) return 'ca-app-pub-3940256099942544/6300978111';
    if (Platform.isIOS) return 'ca-app-pub-3940256099942544/2934735716';
    return '';
  }

  Future<String> _resolveAdUnitId() async {
    if (!Platform.isAndroid && !Platform.isIOS) {
      return '';
    }
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
    try {
      final request = await client.getUrl(Uri.https('app-master.officialsite.kr', '/api/evidence-note/ad-settings'));
      final response = await request.close();
      if (response.statusCode < 200 || response.statusCode >= 300) {
        return _fallbackAdUnitId;
      }
      final body = await response.transform(utf8.decoder).join();
      final decoded = jsonDecode(body) as Map<String, dynamic>;
      final data = decoded['data'];
      if (data is! Map) {
        return _fallbackAdUnitId;
      }

      if (Platform.isAndroid) {
        return (data['android_banner_ad_id'] as String?)?.trim().isNotEmpty == true
            ? data['android_banner_ad_id'] as String
            : _fallbackAdUnitId;
      }
      return (data['ios_banner_ad_id'] as String?)?.trim().isNotEmpty == true
          ? data['ios_banner_ad_id'] as String
          : _fallbackAdUnitId;
    } catch (_) {
      return _fallbackAdUnitId;
    } finally {
      client.close(force: true);
    }
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadBanner());
  }

  Future<void> _loadBanner() async {
    if (!mounted) return;
    final adUnitId = await _resolveAdUnitId();
    if (!mounted || adUnitId.isEmpty) return;
    final width = MediaQuery.sizeOf(context).width.truncate();
    if (_loadedWidth == width && _bannerAd != null) return;

    final adaptiveSize = await AdSize.getCurrentOrientationAnchoredAdaptiveBannerAdSize(width);
    if (!mounted || adaptiveSize == null) return;

    await _bannerAd?.dispose();
    _loaded = false;
    _loadedWidth = width;
    _bannerAd = BannerAd(
      adUnitId: adUnitId,
      size: adaptiveSize,
      request: const AdRequest(),
      listener: BannerAdListener(
        onAdLoaded: (_) {
          if (!mounted) return;
          setState(() => _loaded = true);
        },
        onAdFailedToLoad: (ad, _) {
          ad.dispose();
          if (!mounted) return;
          setState(() {
            _bannerAd = null;
            _loaded = false;
          });
        },
      ),
    )..load();
  }

  @override
  void dispose() {
    _bannerAd?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_loadedWidth != MediaQuery.sizeOf(context).width.truncate()) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _loadBanner());
    }
    return SafeArea(
      top: false,
      minimum: EdgeInsets.zero,
      child: SizedBox(
        width: double.infinity,
        height: _loaded && _bannerAd != null ? _bannerAd!.size.height.toDouble() : 0,
        child: _loaded && _bannerAd != null ? AdWidget(ad: _bannerAd!) : const SizedBox.shrink(),
      ),
    );
  }
}

class _BottomNavGlassClipper extends CustomClipper<Path> {
  const _BottomNavGlassClipper();

  @override
  Path getClip(Size size) {
    const radius = 30.0;
    const notchRadius = 36.0;
    const notchDepth = 30.0;
    const shoulder = 26.0;
    final centerX = size.width / 2;

    final path = Path()
      ..moveTo(radius, 0)
      ..lineTo(centerX - notchRadius - shoulder, 0)
      ..cubicTo(
        centerX - notchRadius - 10,
        0,
        centerX - notchRadius - 8,
        notchDepth * 0.22,
        centerX - notchRadius,
        notchDepth * 0.54,
      )
      ..cubicTo(
        centerX - notchRadius * 0.64,
        notchDepth * 0.92,
        centerX - notchRadius * 0.28,
        notchDepth,
        centerX,
        notchDepth,
      )
      ..cubicTo(
        centerX + notchRadius * 0.28,
        notchDepth,
        centerX + notchRadius * 0.64,
        notchDepth * 0.92,
        centerX + notchRadius,
        notchDepth * 0.54,
      )
      ..cubicTo(
        centerX + notchRadius + 8,
        notchDepth * 0.22,
        centerX + notchRadius + 10,
        0,
        centerX + notchRadius + shoulder,
        0,
      )
      ..lineTo(size.width - radius, 0)
      ..quadraticBezierTo(size.width, 0, size.width, radius)
      ..lineTo(size.width, size.height - radius)
      ..quadraticBezierTo(size.width, size.height, size.width - radius, size.height)
      ..lineTo(radius, size.height)
      ..quadraticBezierTo(0, size.height, 0, size.height - radius)
      ..lineTo(0, radius)
      ..quadraticBezierTo(0, 0, radius, 0)
      ..close();

    return path;
  }

  @override
  bool shouldReclip(covariant CustomClipper<Path> oldClipper) => false;
}

class _EditorActionChip extends StatelessWidget {
  const _EditorActionChip({
    required this.onPressed,
    required this.icon,
    required this.label,
  });

  final VoidCallback onPressed;
  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onPressed,
        borderRadius: BorderRadius.circular(18),
        child: Ink(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.88),
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: const Color(0xFFD7E1EC)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 18, color: const Color(0xFF183B56)),
              const SizedBox(width: 8),
              Text(
                label,
                style: const TextStyle(
                  color: Color(0xFF183B56),
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _EditorToolCard extends StatelessWidget {
  const _EditorToolCard({
    required this.onPressed,
    required this.icon,
    required this.title,
    required this.subtitle,
    this.active = false,
  });

  final VoidCallback onPressed;
  final IconData icon;
  final String title;
  final String subtitle;
  final bool active;

  @override
  Widget build(BuildContext context) {
    final cardBackground = active ? const Color(0xFFFFF1F2) : Colors.white.withValues(alpha: 0.96);
    final cardBorder = active ? const Color(0xFFF1A7AF) : const Color(0xFFD7E1EC);
    final iconBackground = active ? const Color(0xFFFED7DC) : const Color(0xFFF3F6FA);
    final iconBorder = active ? const Color(0xFFF4B7BE) : const Color(0xFFE1E7EF);
    final iconColor = active ? const Color(0xFFC62839) : const Color(0xFF183B56);
    final titleColor = active ? const Color(0xFF9F1D2D) : const Color(0xFF17203A);
    final subtitleColor = active ? const Color(0xFFB03A48) : const Color(0xFF66718F);
    final actionColor = active ? const Color(0xFFC62839) : const Color(0xFF183B56);

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onPressed,
        borderRadius: BorderRadius.circular(24),
        child: SizedBox(
          width: double.infinity,
          child: Ink(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: cardBackground,
              borderRadius: BorderRadius.circular(24),
              border: Border.all(color: cardBorder),
              boxShadow: [
                BoxShadow(
                  color: (active ? const Color(0xFFC62839) : const Color(0xFF183B56)).withValues(alpha: 0.06),
                  blurRadius: 18,
                  offset: const Offset(0, 8),
                ),
              ],
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 42,
                  height: 42,
                  decoration: BoxDecoration(
                    color: iconBackground,
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: iconBorder),
                  ),
                  child: Icon(icon, color: iconColor, size: 20),
                ),
                const SizedBox(height: 14),
                Text(
                  title,
                  style: TextStyle(
                    color: titleColor,
                    fontWeight: FontWeight.w800,
                    fontSize: 15,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  subtitle,
                  style: TextStyle(
                    color: subtitleColor,
                    height: 1.4,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                const SizedBox(height: 14),
                Row(
                  children: [
                    Text(
                      active ? '녹음 중' : '열기',
                      style: TextStyle(
                        color: actionColor,
                        fontWeight: FontWeight.w800,
                        fontSize: 13,
                      ),
                    ),
                    const SizedBox(width: 6),
                    Icon(
                      active ? Icons.fiber_manual_record_rounded : Icons.arrow_forward_rounded,
                      size: 16,
                      color: actionColor,
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _PromiseListTab extends StatelessWidget {
  const _PromiseListTab({
    required this.records,
    required this.onOpen,
    required this.onDelete,
    required this.onExportPdf,
    required this.onSharePdf,
  });

  final List<EvidenceRecord> records;
  final Future<void> Function({EvidenceRecord? existing}) onOpen;
  final Future<void> Function(EvidenceRecord record) onDelete;
  final Future<void> Function(EvidenceRecord record) onExportPdf;
  final Future<void> Function(EvidenceRecord record) onSharePdf;

  @override
  Widget build(BuildContext context) {
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 170),
      itemCount: records.length,
      separatorBuilder: (_, __) => const SizedBox(height: 12),
      itemBuilder: (context, index) {
        final record = records[index];
        final loss = estimateLoss(record);
        return Card(
          child: InkWell(
            borderRadius: BorderRadius.circular(24),
            onTap: () => onOpen(existing: record),
            child: Padding(
              padding: const EdgeInsets.all(18),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          record.title,
                          style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 18),
                        ),
                      ),
                      PopupMenuButton<String>(
                        onSelected: (value) {
                          if (value == 'edit') {
                            onOpen(existing: record);
                          } else if (value == 'export_pdf') {
                            unawaited(onExportPdf(record));
                          } else if (value == 'share_pdf') {
                            unawaited(onSharePdf(record));
                          } else if (value == 'delete') {
                            onDelete(record);
                          }
                        },
                        itemBuilder: (_) => const [
                          PopupMenuItem(value: 'edit', child: Text('수정')),
                          PopupMenuItem(value: 'export_pdf', child: Text('PDF 내보내기')),
                          PopupMenuItem(value: 'share_pdf', child: Text('PDF 공유')),
                          PopupMenuItem(value: 'delete', child: Text('삭제')),
                        ],
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      buildPill(record.status.label, record.status.color.withValues(alpha: 0.14), record.status.color),
                      buildPill(record.counterpartyName, const Color(0xFFF0F4FF), const Color(0xFF3457F1)),
                      buildPill(formatDateTime(record.eventAt), const Color(0xFFF7F8FB), const Color(0xFF66718F)),
                      if (record.dueAt != null) buildPill('만기 ${formatDate(record.dueAt!)}', const Color(0xFFF4EFFF), const Color(0xFF7C3AED)),
                    ],
                  ),
                  if (record.amount != null) ...[
                    const SizedBox(height: 14),
                    Text('금액 ${formatAmount(record.amount!)}', style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
                  ],
                  if (record.memo.trim().isNotEmpty) ...[
                    const SizedBox(height: 10),
                    Text(record.memo, style: const TextStyle(color: Color(0xFF44506C), height: 1.45)),
                  ],
                  const SizedBox(height: 14),
                  Container(
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(color: const Color(0xFFF7F9FF), borderRadius: BorderRadius.circular(18)),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('증거 요약', style: TextStyle(fontWeight: FontWeight.w900, color: record.status.color)),
                        const SizedBox(height: 8),
                        Text('시각 ${formatDateTime(record.createdAt)}'),
                        Text('고유 ID ${record.proofId}'),
                        Text('해시 ${record.proofHash.substring(0, min(16, record.proofHash.length))}...'),
                        if ((record.amount ?? 0) > 0) ...[
                          const SizedBox(height: 10),
                          Text(
                            '손해 추정: ${loss.message}',
                            style: const TextStyle(fontWeight: FontWeight.w700, color: Color(0xFFD14D1F)),
                          ),
                        ],
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class _TimelineTab extends StatelessWidget {
  const _TimelineTab({required this.records, required this.onOpen});

  final List<EvidenceRecord> records;
  final Future<void> Function({EvidenceRecord? existing}) onOpen;

  @override
  Widget build(BuildContext context) {
    final events = records
        .expand((record) => record.timeline.map((event) => _TimelineEntry(record: record, event: event)))
        .toList()
      ..sort((a, b) => b.event.createdAt.compareTo(a.event.createdAt));

    if (events.isEmpty) {
      return const _EmptyState(
        title: '타임라인이 비어 있습니다',
        body: '기록을 저장하면 생성·수정·증거 첨부 이력이 직설적으로 쌓입니다.',
      );
    }

    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 120),
      itemCount: events.length,
      separatorBuilder: (_, __) => const SizedBox(height: 10),
      itemBuilder: (context, index) {
        final entry = events[index];
        return Card(
          child: ListTile(
            contentPadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
            onTap: () => onOpen(existing: entry.record),
            leading: CircleAvatar(
              backgroundColor: const Color(0xFFEAF0FF),
              foregroundColor: const Color(0xFF3457F1),
              child: Icon(entry.event.type.icon),
            ),
            title: Text(
              '${entry.record.counterpartyName} / ${entry.record.title}',
              style: const TextStyle(fontWeight: FontWeight.w800),
            ),
            subtitle: Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(entry.event.description),
                  const SizedBox(height: 4),
                  Text(formatDateTime(entry.event.createdAt), style: const TextStyle(color: Color(0xFF66718F))),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class _TimelineEntry {
  const _TimelineEntry({required this.record, required this.event});

  final EvidenceRecord record;
  final TimelineEvent event;
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.title, required this.body});

  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: 72,
              height: 72,
              decoration: const BoxDecoration(color: Color(0xFFEAF0FF), shape: BoxShape.circle),
              child: const Icon(Icons.folder_open_rounded, color: Color(0xFF3457F1), size: 32),
            ),
            const SizedBox(height: 18),
            Text(title, style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 20)),
            const SizedBox(height: 8),
            Text(body, textAlign: TextAlign.center, style: const TextStyle(color: Color(0xFF66718F), height: 1.45)),
          ],
        ),
      ),
    );
  }
}

class EvidenceEditorPage extends StatefulWidget {
  const EvidenceEditorPage({
    super.key,
    required this.repository,
    this.existing,
    this.embedded = false,
    this.onSaved,
    this.onCancel,
    this.onSavingChanged,
  });

  final EvidenceRepository repository;
  final EvidenceRecord? existing;
  final bool embedded;
  final Future<void> Function()? onSaved;
  final VoidCallback? onCancel;
  final ValueChanged<bool>? onSavingChanged;

  @override
  State<EvidenceEditorPage> createState() => _EvidenceEditorPageState();
}

class _EvidenceEditorPageState extends State<EvidenceEditorPage> {
  late final TextEditingController _titleController;
  late final TextEditingController _amountController;
  late final TextEditingController _memoController;
  late final TextEditingController _counterpartyController;
  late final TextEditingController _contactController;
  late final TextEditingController _deviceController;
  late final TextEditingController _lossRateController;

  bool _useCurrentTime = true;
  DateTime _eventAt = DateTime.now();
  bool _hasDueDate = false;
  DateTime _dueAt = DateTime.now().add(const Duration(days: 7));
  bool _reminderEnabled = false;
  DateTime _reminderAt = DateTime.now().add(const Duration(days: 6, hours: 21));
  PromiseStatus _status = PromiseStatus.inProgress;
  String? _contactId;
  List<AttachmentItem> _attachments = [];
  List<TimelineEvent> _timeline = [];
  Uint8List? _signatureBytes;
  bool _saving = false;
  final SignatureController _signatureController = SignatureController(penStrokeWidth: 3, penColor: const Color(0xFF17203A));
  final AudioRecorder _audioRecorder = AudioRecorder();
  String? _recordingPath;
  bool _recording = false;

  void _setSaving(bool value) {
    if (_saving == value) return;
    if (mounted) {
      setState(() => _saving = value);
    } else {
      _saving = value;
    }
    widget.onSavingChanged?.call(value);
  }

  @override
  void initState() {
    super.initState();
    final existing = widget.existing;
    _titleController = TextEditingController(text: existing?.title ?? '');
    _amountController = TextEditingController(text: existing?.amount?.toStringAsFixed(0) ?? '');
    _memoController = TextEditingController(text: existing?.memo ?? '');
    _counterpartyController = TextEditingController(text: existing?.counterpartyName ?? '');
    _contactController = TextEditingController(text: existing?.contactLabel ?? '');
    _deviceController = TextEditingController(text: existing?.deviceSummary ?? defaultDeviceSummary());
    _lossRateController = TextEditingController(text: existing?.dailyLossRate.toStringAsFixed(4) ?? '0.0008');
    _useCurrentTime = existing == null;
    _eventAt = existing?.eventAt ?? DateTime.now();
    _hasDueDate = existing?.dueAt != null;
    _dueAt = existing?.dueAt ?? DateTime.now().add(const Duration(days: 7));
    _reminderEnabled = existing?.reminderAt != null;
    _reminderAt = existing?.reminderAt ?? _dueAt.subtract(const Duration(hours: 12));
    _status = existing?.status ?? PromiseStatus.inProgress;
    _contactId = existing?.contactId;
    _attachments = List.of(existing?.attachments ?? const []);
    _timeline = List.of(existing?.timeline ?? const []);
  }

  @override
  void dispose() {
    _titleController.dispose();
    _amountController.dispose();
    _memoController.dispose();
    _counterpartyController.dispose();
    _contactController.dispose();
    _deviceController.dispose();
    _lossRateController.dispose();
    _signatureController.dispose();
    _audioRecorder.dispose();
    super.dispose();
  }

  Future<void> _pickDateTime() async {
    final picked = await _pickCombinedDateTime(_eventAt);
    if (picked == null) return;
    setState(() {
      _eventAt = picked;
    });
  }

  Future<DateTime?> _pickCombinedDateTime(DateTime initial) async {
    final date = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: DateTime(2020),
      lastDate: DateTime(2100),
    );
    if (date == null || !mounted) return null;
    final time = await showTimePicker(context: context, initialTime: TimeOfDay.fromDateTime(initial));
    if (time == null) return null;
    return DateTime(date.year, date.month, date.day, time.hour, time.minute);
  }

  Future<void> _pickDueDateTime() async {
    final picked = await _pickCombinedDateTime(_dueAt);
    if (picked == null) return;
    setState(() {
      _hasDueDate = true;
      _dueAt = picked;
      if (_reminderEnabled && _reminderAt.isAfter(_dueAt)) {
        _reminderAt = _dueAt.subtract(const Duration(hours: 12));
      }
    });
  }

  Future<void> _pickReminderDateTime() async {
    final base = _hasDueDate ? _reminderAt : DateTime.now().add(const Duration(days: 1));
    final picked = await _pickCombinedDateTime(base);
    if (picked == null) return;
    setState(() {
      _reminderEnabled = true;
      _reminderAt = picked;
    });
  }

  Future<void> _connectContact() async {
    FocusScope.of(context).unfocus(disposition: UnfocusDisposition.scope);
    final granted = await FlutterContacts.requestPermission(readonly: true);
    if (!granted) {
      await showAppToast('연락처 권한이 필요합니다. 설정에서 허용해 주세요.');
      return;
    }
    if (!mounted) {
      await showAppToast('연락처 권한이 필요합니다.');
      return;
    }
    final contacts = await FlutterContacts.getContacts(withProperties: true, withPhoto: false);
    if (!mounted) return;
    final selected = await showDialog<Contact>(
      context: context,
      builder: (context) {
        var filtered = contacts;
        return StatefulBuilder(
          builder: (context, setStateDialog) => AlertDialog(
            title: const Text('연락처에서 상대 선택'),
            content: SizedBox(
              width: double.maxFinite,
              height: 420,
              child: Column(
                children: [
                  TextField(
                    decoration: const InputDecoration(hintText: '이름 검색'),
                    onChanged: (value) {
                      final query = value.trim().toLowerCase();
                      setStateDialog(() {
                        filtered = contacts.where((c) => c.displayName.toLowerCase().contains(query)).toList();
                      });
                    },
                  ),
                  const SizedBox(height: 12),
                  Expanded(
                    child: ListView.builder(
                      itemCount: filtered.length,
                      itemBuilder: (_, index) {
                        final contact = filtered[index];
                        final subtitle = contact.phones.isNotEmpty ? contact.phones.first.number : '전화번호 없음';
                        return ListTile(
                          onTap: () => Navigator.pop(context, contact),
                          title: Text(contact.displayName),
                          subtitle: Text(subtitle),
                        );
                      },
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );

    if (selected == null) return;
    final phone = selected.phones.isNotEmpty ? selected.phones.first.number : '';
    setState(() {
      _counterpartyController.text = selected.displayName;
      _contactController.text = phone.isEmpty ? selected.displayName : '${selected.displayName} · $phone';
      _contactId = selected.id;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      FocusScope.of(context).unfocus(disposition: UnfocusDisposition.scope);
    });
  }

  Future<void> _addPhoto() async {
    final existingPhotoAttachments = _attachments.where((item) => item.type == AttachmentType.photo).toList();
    final initialSelectedIds = existingPhotoAttachments
        .map(_photoAssetIdFromAttachment)
        .whereType<String>()
        .toList();

    final selectedAssets = await Navigator.of(context).push<List<AssetEntity>>(
      MaterialPageRoute(
        builder: (_) => PhotoPickerPage(initialSelectedIds: initialSelectedIds),
      ),
    );
    if (selectedAssets == null) return;

    final selectedAssetIds = selectedAssets.map((asset) => asset.id).toSet();
    final preservedAttachments = _attachments.where((item) {
      if (item.type != AttachmentType.photo) {
        return true;
      }
      final assetId = _photoAssetIdFromAttachment(item);
      return assetId != null && selectedAssetIds.contains(assetId);
    }).toList();

    final alreadyAttachedPhotoIds = preservedAttachments
        .where((item) => item.type == AttachmentType.photo)
        .map(_photoAssetIdFromAttachment)
        .whereType<String>()
        .toSet();

    final newAttachments = <AttachmentItem>[];
    for (final asset in selectedAssets) {
      if (alreadyAttachedPhotoIds.contains(asset.id)) {
        continue;
      }
      final sourceFile = await asset.file;
      if (sourceFile == null) {
        continue;
      }
      final extension = sourceFile.path.split('.').last.toLowerCase();
      final file = await _copyAttachment(
        sourceFile,
        'photo_${DateTime.now().millisecondsSinceEpoch}_${asset.id}.$extension',
      );
      newAttachments.add(
        AttachmentItem.photo(
          file.path,
          localUploadKey: _attachmentUploadKey(AttachmentType.photo),
          localAssetId: asset.id,
        ),
      );
    }
    setState(() {
      _attachments = [
        ...preservedAttachments,
        ...newAttachments,
      ];
    });

    if (selectedAssets.isNotEmpty && newAttachments.isEmpty && alreadyAttachedPhotoIds.length != selectedAssets.length) {
      await showAppToast('일부 선택한 사진을 불러오지 못했습니다.');
    }
  }

  Future<void> _toggleRecording() async {
    if (_recording) {
      final path = await _audioRecorder.stop();
      if (path != null) {
        final file = File(path);
        final copied = await _copyAttachment(file, 'voice_${DateTime.now().millisecondsSinceEpoch}.m4a');
        setState(() {
          _attachments.add(
            AttachmentItem.audio(
              copied.path,
              localUploadKey: _attachmentUploadKey(AttachmentType.audio),
            ),
          );
          _recording = false;
          _recordingPath = null;
        });
      }
      return;
    }

    if (!await _audioRecorder.hasPermission()) {
      await showAppToast('마이크 권한이 필요합니다.');
      return;
    }
    final dir = await getTemporaryDirectory();
    final path = '${dir.path}/evidence_note_record_${DateTime.now().millisecondsSinceEpoch}.m4a';
    await _audioRecorder.start(const RecordConfig(encoder: AudioEncoder.aacLc), path: path);
    setState(() {
      _recording = true;
      _recordingPath = path;
    });
  }

  Future<void> _saveSignature() async {
    final data = await _signatureController.toPngBytes(height: 240, width: 600);
    if (data == null || data.isEmpty) {
      await showAppToast('서명을 먼저 입력해 주세요.');
      return;
    }
    final file = await _writeBytesAttachment(data, 'signature_${DateTime.now().millisecondsSinceEpoch}.png');
    setState(() {
      _signatureBytes = data;
      _attachments.add(
        AttachmentItem.signature(
          file.path,
          localUploadKey: _attachmentUploadKey(AttachmentType.signature),
        ),
      );
    });
    _signatureController.clear();
    if (!mounted) return;
    Navigator.pop(context);
  }

  Future<void> _openSignatureSheet() async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (context) {
        final mediaQuery = MediaQuery.of(context);
        return SafeArea(
          top: false,
          child: Padding(
            padding: EdgeInsets.only(
              left: 20,
              right: 20,
              top: 20,
              bottom: mediaQuery.viewInsets.bottom + mediaQuery.padding.bottom + 20,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text('간단 서명', style: TextStyle(fontWeight: FontWeight.w900, fontSize: 18)),
                const SizedBox(height: 12),
                Container(
                  decoration: BoxDecoration(color: const Color(0xFFF7F9FF), borderRadius: BorderRadius.circular(20)),
                  child: Signature(controller: _signatureController, height: 220, backgroundColor: const Color(0xFFF7F9FF)),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton(
                        onPressed: _signatureController.clear,
                        child: const Text('지우기'),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: FilledButton(
                        onPressed: _saveSignature,
                        child: const Text('서명 저장'),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Future<File> _copyAttachment(File source, String fileName) async {
    final dir = await _ensureAttachmentDirectory();
    final target = File('${dir.path}/$fileName');
    return source.copy(target.path);
  }

  Future<File> _writeBytesAttachment(Uint8List bytes, String fileName) async {
    final dir = await _ensureAttachmentDirectory();
    final target = File('${dir.path}/$fileName');
    return target.writeAsBytes(bytes, flush: true);
  }

  Future<Directory> _ensureAttachmentDirectory() async {
    final docDir = await getApplicationDocumentsDirectory();
    final dir = Directory('${docDir.path}/evidence_attachments');
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  Future<List<AttachmentItem>> _uploadAttachmentsIfNeeded() async {
    final uploaded = <AttachmentItem>[];
    for (final item in _attachments) {
      uploaded.add(await EvidenceApiService.instance.uploadAttachment(item));
    }
    return uploaded;
  }

  Future<void> _save() async {
    if (_saving) return;
    if (_titleController.text.trim().isEmpty || _counterpartyController.text.trim().isEmpty) {
      await showAppToast('제목과 상대 이름은 필수입니다.');
      return;
    }
    _setSaving(true);

    List<AttachmentItem> uploadedAttachments;
    try {
      uploadedAttachments = await _uploadAttachmentsIfNeeded();
    } catch (_) {
      _setSaving(false);
      await showAppToast('첨부 업로드에 실패했습니다. 네트워크를 확인해 주세요.');
      return;
    }

    final existing = widget.existing;
    final now = DateTime.now();
    final eventAt = _useCurrentTime ? now : _eventAt;
    final dueAt = _hasDueDate ? _dueAt : null;
    final reminderAt = _reminderEnabled ? _reminderAt : null;
    final amount = double.tryParse(_amountController.text.replaceAll(',', '').trim());
    final deviceSummary = _deviceController.text.trim().isEmpty ? defaultDeviceSummary() : _deviceController.text.trim();
    final proofId = existing?.proofId ?? 'PROOF-${now.millisecondsSinceEpoch}';
    final payload = {
      'title': _titleController.text.trim(),
      'counterpartyName': _counterpartyController.text.trim(),
      'amount': amount,
      'eventAt': eventAt.toIso8601String(),
      'memo': _memoController.text.trim(),
      'status': _status.name,
      'contactId': _contactId,
      'contactLabel': _contactController.text.trim(),
      'deviceSummary': deviceSummary,
      'attachments': uploadedAttachments.map((item) => item.toJson()).toList(),
      'dueAt': dueAt?.toIso8601String(),
      'reminderAt': reminderAt?.toIso8601String(),
      'updatedAt': now.toIso8601String(),
    };
    final proofHash = sha256.convert(utf8.encode(jsonEncode(payload))).toString();

    final timeline = List<TimelineEvent>.of(_timeline);
    if (existing == null) {
      timeline.insert(0, TimelineEvent.create(TimelineEventType.created, '약속/거래를 생성했습니다.', now));
    } else {
      timeline.insert(0, TimelineEvent.create(TimelineEventType.edited, '내용을 수정했습니다.', now));
    }
    if (uploadedAttachments.isNotEmpty) {
      timeline.insert(0, TimelineEvent.create(TimelineEventType.attachmentAdded, '증거 첨부 ${uploadedAttachments.length}건이 연결되었습니다.', now));
    }
    if (dueAt != null) {
      timeline.insert(0, TimelineEvent.create(TimelineEventType.edited, '만기 일정을 ${formatDateTime(dueAt)}로 설정했습니다.', now));
    }
    if (reminderAt != null) {
      timeline.insert(0, TimelineEvent.create(TimelineEventType.reminderAnswered, '리마인더를 ${formatDateTime(reminderAt)}에 예약했습니다.', now));
    }
    timeline.insert(0, TimelineEvent.create(TimelineEventType.statusChanged, '상태를 ${_status.label}로 기록했습니다.', now));

    final record = EvidenceRecord(
      id: existing?.id ?? _uuid.v4(),
      proofId: proofId,
      title: _titleController.text.trim(),
      amount: amount,
      eventAt: eventAt,
      memo: _memoController.text.trim(),
      counterpartyName: _counterpartyController.text.trim(),
      contactId: _contactId,
      contactLabel: _contactController.text.trim(),
      createdAt: existing?.createdAt ?? now,
      updatedAt: now,
      status: _status,
      proofHash: proofHash,
      deviceSummary: deviceSummary,
      attachments: uploadedAttachments,
      timeline: timeline.take(60).toList(),
      dailyLossRate: double.tryParse(_lossRateController.text.trim()) ?? 0.0008,
      dueAt: dueAt,
      reminderAt: reminderAt,
      notificationId: existing?.notificationId ?? _buildNotificationId(),
    );

    try {
      await widget.repository.saveRecord(record);
      _attachments = uploadedAttachments;
      await ReminderService.instance.schedule(record);
      await EvidenceInterstitialAdService.instance.onRecordSaved();
      _setSaving(false);
      await showAppToast(existing == null ? '증거 기록을 저장했습니다.' : '기록을 수정했습니다.');
      if (widget.embedded) {
        await widget.onSaved?.call();
        return;
      }
      if (!mounted) return;
      Navigator.pop(context, true);
    } catch (_) {
      _setSaving(false);
      await showAppToast('저장 중 오류가 발생했습니다. 다시 시도해 주세요.');
    }
  }

  Future<void> _shareSummary() async {
    final title = _titleController.text.trim();
    final counterparty = _counterpartyController.text.trim();
    final memo = _memoController.text.trim();

    if (title.isEmpty && counterparty.isEmpty && memo.isEmpty) {
      await showAppToast('공유할 제목이나 메모를 먼저 입력해 주세요.');
      return;
    }

    final text = [title, counterparty, memo].where((e) => e.isNotEmpty).join('\n');
    if (text.trim().isEmpty) {
      await showAppToast('공유할 내용이 아직 없습니다.');
      return;
    }

    await SharePlus.instance.share(ShareParams(text: text));
  }

  int _buildNotificationId() => widget.existing?.notificationId ?? DateTime.now().millisecondsSinceEpoch.remainder(1 << 30);

  Future<void> _exportPdf() async {
    final title = _titleController.text.trim();
    if (title.isEmpty) {
      await showAppToast('먼저 제목을 입력해 주세요.');
      return;
    }
    final regularFont = await _loadPdfRegularFont();
    final boldFont = await _loadPdfBoldFont();
    final pdf = pw.Document();
    pdf.addPage(
      pw.MultiPage(
        theme: pw.ThemeData.withFont(
          base: regularFont,
          bold: boldFont,
        ),
        build: (_) => [
          pw.Text('증거노트 요약', style: pw.TextStyle(fontSize: 24, fontWeight: pw.FontWeight.bold)),
          pw.SizedBox(height: 16),
          pw.Text('제목: ${_titleController.text.trim()}'),
          pw.Text('상대: ${_counterpartyController.text.trim()}'),
          pw.Text('금액: ${_amountController.text.trim().isEmpty ? '-' : _amountController.text.trim()}'),
          pw.Text('날짜: ${formatDateTime(_useCurrentTime ? DateTime.now() : _eventAt)}'),
          pw.Text('만기: ${_hasDueDate ? formatDateTime(_dueAt) : '-'}'),
          pw.Text('알림: ${_reminderEnabled ? formatDateTime(_reminderAt) : '-'}'),
          pw.Text('상태: ${_status.label}'),
          pw.Text('메모: ${_memoController.text.trim()}'),
          pw.Text('연락처: ${_contactController.text.trim()}'),
          pw.SizedBox(height: 16),
          pw.Text('증거 강화 요소', style: pw.TextStyle(fontWeight: pw.FontWeight.bold)),
          pw.Bullet(text: '사진 ${_attachments.where((e) => e.type == AttachmentType.photo).length}건'),
          pw.Bullet(text: '음성 ${_attachments.where((e) => e.type == AttachmentType.audio).length}건'),
          pw.Bullet(text: '서명 ${_attachments.where((e) => e.type == AttachmentType.signature).length}건'),
          pw.SizedBox(height: 16),
          pw.Text('※ 이 문서는 개인 기록 정리/공유용 요약본이며 법적 효력을 보장하지 않습니다.'),
        ],
      ),
    );
    await Printing.layoutPdf(onLayout: (_) => pdf.save());
  }

  Future<void> triggerSave() async => _save();

  @override
  Widget build(BuildContext context) {
    final isEditing = widget.existing != null;
    final attachmentPhotoCount = _attachments.where((item) => item.type == AttachmentType.photo).length;
    final attachmentAudioCount = _attachments.where((item) => item.type == AttachmentType.audio).length;
    final attachmentSignatureCount = _attachments.where((item) => item.type == AttachmentType.signature).length;

    final content = SafeArea(
      top: false,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final isWide = constraints.maxWidth >= 760;
          return ListView(
            padding: EdgeInsets.fromLTRB(20, widget.embedded ? 16 : 12, 20, widget.embedded ? 176 : 156),
            children: [
              _section(
                title: '핵심 정보',
                subtitle: '상대, 금액, 시점 같은 기본 골격을 먼저 정돈합니다.',
                accent: const Color(0xFF183B56),
                child: Column(
                  children: [
                    _textField(_titleController, '제목', hint: '예: 김OO에게 50만원을 빌려준 약속'),
                    const SizedBox(height: 12),
                    if (isWide)
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(child: _textField(_counterpartyController, '상대 이름')),
                          const SizedBox(width: 12),
                          Expanded(child: _textField(_amountController, '금액', hint: '500000', keyboardType: TextInputType.number)),
                        ],
                      )
                    else ...[
                      _textField(_counterpartyController, '상대 이름'),
                      const SizedBox(height: 12),
                      _textField(_amountController, '금액', hint: '500000', keyboardType: TextInputType.number),
                    ],
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Expanded(child: _textField(_contactController, '연동된 연락처', hint: '선택한 연락처가 여기에 표시됩니다.')),
                        const SizedBox(width: 12),
                        OutlinedButton.icon(
                          onPressed: _connectContact,
                          icon: const Icon(Icons.contacts_rounded),
                          label: const Text('연락처 불러오기'),
                          style: OutlinedButton.styleFrom(minimumSize: const Size(0, 56)),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    _timeModePanel(),
                    const SizedBox(height: 16),
                    _statusSelector(),
                    const SizedBox(height: 16),
                    _schedulePanel(),
                    const SizedBox(height: 16),
                    _textField(_memoController, '내용 메모', maxLines: 6, hint: '대화 핵심, 약속 조건, 전달 방식, 기한 등을 간결하게 남겨두세요.'),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              _section(
                title: '증거 보강',
                subtitle: '사진, 녹음, 서명을 붙여 기록의 신뢰도를 높입니다.',
                accent: const Color(0xFF183B56),
                header: Row(
                  children: [
                    Expanded(child: _infoMetric('사진', '$attachmentPhotoCount건')),
                    const SizedBox(width: 10),
                    Expanded(child: _infoMetric('음성', '$attachmentAudioCount건')),
                    const SizedBox(width: 10),
                    Expanded(child: _infoMetric('서명', '$attachmentSignatureCount건')),
                  ],
                ),
                child: Column(
                  children: [
                    LayoutBuilder(
                      builder: (context, constraints) {
                        final cardWidth = constraints.maxWidth >= 860
                            ? (constraints.maxWidth - 20) / 3
                            : constraints.maxWidth >= 680
                            ? (constraints.maxWidth - 12) / 2.15
                            : constraints.maxWidth * 0.72;

                        return SizedBox(
                          height: 188,
                          child: ListView(
                            scrollDirection: Axis.horizontal,
                            physics: const BouncingScrollPhysics(),
                            clipBehavior: Clip.none,
                            children: [
                              SizedBox(
                                width: cardWidth,
                                child: _EditorToolCard(
                                  onPressed: _addPhoto,
                                  icon: Icons.photo_library_rounded,
                                  title: '사진 첨부',
                                  subtitle: '캡처, 이체 내역, 대화 이미지를 연결',
                                ),
                              ),
                              const SizedBox(width: 10),
                              SizedBox(
                                width: cardWidth,
                                child: _EditorToolCard(
                                  onPressed: _toggleRecording,
                                  icon: _recording ? Icons.stop_circle_outlined : Icons.mic_rounded,
                                  title: _recording ? '녹음 종료' : '음성 녹음',
                                  subtitle: _recording ? '현재 녹음 중인 파일을 저장' : '상대 음성이나 현장 녹음을 추가',
                                  active: _recording,
                                ),
                              ),
                              const SizedBox(width: 10),
                              SizedBox(
                                width: cardWidth,
                                child: _EditorToolCard(
                                  onPressed: _openSignatureSheet,
                                  icon: Icons.draw_rounded,
                                  title: '서명 추가',
                                  subtitle: '간단한 확인 서명을 증거와 함께 보관',
                                ),
                              ),
                            ],
                          ),
                        );
                      },
                    ),
                    const SizedBox(height: 14),
                    if (_attachments.isEmpty)
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(18),
                        decoration: BoxDecoration(
                          color: const Color(0xFFF7F9FF),
                          borderRadius: BorderRadius.circular(22),
                          border: Border.all(color: const Color(0xFFE2E8F2)),
                        ),
                        child: const Text(
                          '아직 첨부된 증거가 없습니다. 최소 한 개 이상의 시각적 또는 음성 자료를 남기면 기록 활용도가 훨씬 좋아집니다.',
                          style: TextStyle(color: Color(0xFF66718F), height: 1.5),
                        ),
                      )
                    else
                      ..._attachments.asMap().entries.map(
                        (entry) => _attachmentTile(
                          item: entry.value,
                          onRemove: () => setState(() => _attachments.removeAt(entry.key)),
                        ),
                      ),
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );

    if (widget.embedded) {
      return Stack(
        children: [
          const _EvidenceBackdrop(),
          content,
        ],
      );
    }

    return Scaffold(
      backgroundColor: const Color(0xFFF4F7FB),
      appBar: AppBar(
        toolbarHeight: 92,
        titleSpacing: 20,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              isEditing ? '기록 수정' : '새 기록 만들기',
              style: const TextStyle(
                fontFamily: 'Pretendard',
                fontSize: 26,
                fontWeight: FontWeight.w800,
                color: Color(0xFF17203A),
                letterSpacing: -0.5,
              ),
            ),
          ],
        ),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 4),
            child: IconButton.filledTonal(
              onPressed: _exportPdf,
              style: IconButton.styleFrom(
                backgroundColor: Colors.white.withValues(alpha: 0.88),
                foregroundColor: const Color(0xFF183B56),
              ),
              icon: const Icon(Icons.picture_as_pdf_rounded),
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: FilledButton(
              onPressed: _saving ? null : _save,
              style: FilledButton.styleFrom(
                backgroundColor: _saving ? const Color(0xFFBCC5D1) : const Color(0xFF183B56),
                disabledBackgroundColor: const Color(0xFFBCC5D1),
                foregroundColor: Colors.white,
                disabledForegroundColor: Colors.white,
                minimumSize: const Size(0, 42),
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 0),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                textStyle: const TextStyle(
                  fontFamily: 'Pretendard',
                  fontWeight: FontWeight.w800,
                  fontSize: 15,
                ),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (_saving) ...[
                    const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                        strokeWidth: 2.2,
                        valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                      ),
                    ),
                    const SizedBox(width: 8),
                  ],
                  Text(_saving ? '저장 중' : '저장'),
                ],
              ),
            ),
          ),
        ],
      ),
      bottomNavigationBar: const SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(height: 10),
            _AdMobBannerBar(),
          ],
        ),
      ),
      body: content,
    );
  }

  Widget _section({
    required String title,
    required String subtitle,
    required Widget child,
    Widget? header,
    Color accent = const Color(0xFF3457F1),
  }) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(28),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 8, sigmaY: 8),
        child: Container(
          padding: const EdgeInsets.all(18),
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.74),
            borderRadius: BorderRadius.circular(28),
            border: Border.all(color: Colors.white.withValues(alpha: 0.95)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 46,
                height: 6,
                decoration: BoxDecoration(
                  color: accent,
                  borderRadius: BorderRadius.circular(999),
                ),
              ),
              const SizedBox(height: 14),
              Text(
                title,
                style: const TextStyle(
                  fontWeight: FontWeight.w900,
                  fontSize: 20,
                  color: Color(0xFF17203A),
                  letterSpacing: -0.3,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                subtitle,
                style: const TextStyle(
                  color: Color(0xFF66718F),
                  height: 1.45,
                  fontWeight: FontWeight.w500,
                ),
              ),
              if (header != null) ...[
                const SizedBox(height: 16),
                header,
              ],
              const SizedBox(height: 16),
              child,
            ],
          ),
        ),
      ),
    );
  }

  Widget _textField(
    TextEditingController controller,
    String label, {
    String? hint,
    TextInputType? keyboardType,
    int maxLines = 1,
  }) {
    return TextField(
      controller: controller,
      keyboardType: keyboardType,
      maxLines: maxLines,
      decoration: _inputDecoration(label, hint: hint),
      onChanged: (_) => setState(() {}),
    );
  }

  InputDecoration _inputDecoration(String label, {String? hint}) {
    return InputDecoration(
      labelText: label,
      hintText: hint,
      filled: true,
      fillColor: Colors.white.withValues(alpha: 0.82),
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(20), borderSide: BorderSide.none),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(20),
        borderSide: const BorderSide(color: Color(0xFFE1E8F1)),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(20),
        borderSide: const BorderSide(color: Color(0xFF3457F1), width: 1.4),
      ),
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 18),
    );
  }

  Widget _timeModePanel() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFFF7F9FF),
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: const Color(0xFFE2E8F2)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            '기록 시점',
            style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800, color: Color(0xFF17203A)),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: _modeButton(
                  label: '현재 시각',
                  selected: _useCurrentTime,
                  icon: Icons.bolt_rounded,
                  onTap: () => setState(() => _useCurrentTime = true),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _modeButton(
                  label: '직접 선택',
                  selected: !_useCurrentTime,
                  icon: Icons.schedule_rounded,
                  onTap: () => setState(() => _useCurrentTime = false),
                ),
              ),
            ],
          ),
          if (!_useCurrentTime) ...[
            const SizedBox(height: 12),
            InkWell(
              onTap: _pickDateTime,
              borderRadius: BorderRadius.circular(18),
              child: Ink(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(18),
                  border: Border.all(color: const Color(0xFFDCE4EF)),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.event_available_rounded, color: Color(0xFF3457F1)),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        formatDateTime(_eventAt),
                        style: const TextStyle(fontWeight: FontWeight.w700, color: Color(0xFF17203A)),
                      ),
                    ),
                    const Icon(Icons.chevron_right_rounded, color: Color(0xFF70819A)),
                  ],
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _modeButton({
    required String label,
    required bool selected,
    required IconData icon,
    required VoidCallback onTap,
  }) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(18),
        child: Ink(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
          decoration: BoxDecoration(
            color: selected ? const Color(0xFF183B56) : Colors.white,
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: selected ? const Color(0xFF183B56) : const Color(0xFFDCE4EF)),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, size: 18, color: selected ? Colors.white : const Color(0xFF48617D)),
              const SizedBox(width: 8),
              Text(
                label,
                style: TextStyle(color: selected ? Colors.white : const Color(0xFF183B56), fontWeight: FontWeight.w700),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _statusSelector() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          '현재 상태',
          style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800, color: Color(0xFF17203A)),
        ),
        const SizedBox(height: 12),
        Row(
          children: PromiseStatus.values
              .map(
                (status) => Expanded(
                  child: Padding(
                    padding: EdgeInsets.only(right: status == PromiseStatus.values.last ? 0 : 10),
                    child: Material(
                      color: Colors.transparent,
                      child: InkWell(
                        onTap: () => setState(() => _status = status),
                        borderRadius: BorderRadius.circular(20),
                        child: Ink(
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
                          decoration: BoxDecoration(
                            color: _status == status ? status.color.withValues(alpha: 0.16) : Colors.white,
                            borderRadius: BorderRadius.circular(20),
                            border: Border.all(
                              color: _status == status ? status.color : const Color(0xFFDCE4EF),
                              width: _status == status ? 1.4 : 1,
                            ),
                          ),
                          child: Column(
                            children: [
                              Icon(Icons.flag_rounded, color: status.color, size: 18),
                              const SizedBox(height: 8),
                              Text(
                                status.label,
                                style: TextStyle(
                                  fontSize: 13,
                                  fontWeight: FontWeight.w700,
                                  color: _status == status ? status.color : const Color(0xFF44506C),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              )
              .toList(),
        ),
      ],
    );
  }

  Widget _schedulePanel() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFFF8F5FF),
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: const Color(0xFFE8DEFF)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            '기한 및 알림',
            style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800, color: Color(0xFF17203A)),
          ),
          const SizedBox(height: 6),
          const Text(
            '돈거래나 약속 이행 예정일을 넣고, 미리 알림도 예약할 수 있습니다.',
            style: TextStyle(color: Color(0xFF66718F), height: 1.45),
          ),
          const SizedBox(height: 14),
          SwitchListTile.adaptive(
            value: _hasDueDate,
            contentPadding: EdgeInsets.zero,
            title: const Text('만기 일정 사용'),
            subtitle: Text(_hasDueDate ? formatDateTime(_dueAt) : '예정일이 필요할 때만 켜두세요.'),
            onChanged: (value) {
              setState(() {
                _hasDueDate = value;
                if (!value) {
                  _reminderEnabled = false;
                }
              });
            },
          ),
          if (_hasDueDate) ...[
            const SizedBox(height: 6),
            _scheduleTile(
              icon: Icons.event_repeat_rounded,
              title: '만기 예정일',
              value: formatDateTime(_dueAt),
              tint: const Color(0xFF7C3AED),
              onTap: _pickDueDateTime,
            ),
            const SizedBox(height: 12),
            SwitchListTile.adaptive(
              value: _reminderEnabled,
              contentPadding: EdgeInsets.zero,
              title: const Text('사전 알림 예약'),
              subtitle: Text(_reminderEnabled ? formatDateTime(_reminderAt) : '설정한 시간에 로컬 알림으로 안내합니다.'),
              onChanged: (value) {
                setState(() {
                  _reminderEnabled = value;
                  if (value && _reminderAt.isAfter(_dueAt)) {
                    _reminderAt = _dueAt.subtract(const Duration(hours: 12));
                  }
                });
              },
            ),
            if (_reminderEnabled) ...[
              const SizedBox(height: 6),
              _scheduleTile(
                icon: Icons.notifications_active_rounded,
                title: '리마인더 시각',
                value: formatDateTime(_reminderAt),
                tint: const Color(0xFFD97706),
                onTap: _pickReminderDateTime,
              ),
            ],
          ],
        ],
      ),
    );
  }

  Widget _scheduleTile({
    required IconData icon,
    required String title,
    required String value,
    required Color tint,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(18),
      child: Ink(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: tint.withValues(alpha: 0.22)),
        ),
        child: Row(
          children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: tint.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(14),
              ),
              child: Icon(icon, color: tint, size: 20),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: const TextStyle(fontWeight: FontWeight.w700, color: Color(0xFF17203A))),
                  const SizedBox(height: 4),
                  Text(value, style: const TextStyle(color: Color(0xFF66718F), fontWeight: FontWeight.w500)),
                ],
              ),
            ),
            const Icon(Icons.chevron_right_rounded, color: Color(0xFF70819A)),
          ],
        ),
      ),
    );
  }

  Widget _summaryPill(IconData icon, String label, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 16, color: color),
          const SizedBox(width: 8),
          Text(label, style: TextStyle(color: color, fontWeight: FontWeight.w700)),
        ],
      ),
    );
  }

  Widget _heroLine({
    required String title,
    required String subtitle,
    required String amountText,
  }) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [Color(0xFF183B56), Color(0xFF355C7D)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(24),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 20,
                    fontWeight: FontWeight.w800,
                    height: 1.22,
                    letterSpacing: -0.4,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  subtitle,
                  style: TextStyle(color: Colors.white.withValues(alpha: 0.82), height: 1.45, fontWeight: FontWeight.w500),
                ),
              ],
            ),
          ),
          const SizedBox(width: 14),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: Colors.white.withValues(alpha: 0.16)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  'AMOUNT',
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.62),
                    fontSize: 10,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.8,
                  ),
                ),
                const SizedBox(height: 6),
                Text(amountText, style: const TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.w800)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _infoMetric(String label, String value) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
      decoration: BoxDecoration(
        color: const Color(0xFFF7F9FF),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: const Color(0xFFE2E8F2)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: const TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w700,
              color: Color(0xFF70819A),
              letterSpacing: 0.4,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w800, color: Color(0xFF17203A)),
          ),
        ],
      ),
    );
  }

  Widget _attachmentTile({
    required AttachmentItem item,
    required VoidCallback onRemove,
  }) {
    final isPhoto = item.type == AttachmentType.photo;
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.9),
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: const Color(0xFFDDE5EF)),
      ),
      child: Row(
        children: [
          if (isPhoto)
            ClipRRect(
              borderRadius: BorderRadius.circular(14),
              child: SizedBox(
                width: 54,
                height: 54,
                child: Image.file(
                  File(item.path),
                  fit: BoxFit.cover,
                  errorBuilder: (_, __, ___) => Container(
                    color: const Color(0xFFEAF0FF),
                    alignment: Alignment.center,
                    child: const Icon(Icons.photo_rounded, color: Color(0xFF3457F1)),
                  ),
                ),
              ),
            )
          else
            Container(
              width: 42,
              height: 42,
              decoration: BoxDecoration(
                color: const Color(0xFFEAF0FF),
                borderRadius: BorderRadius.circular(14),
              ),
              child: Icon(item.type.icon, color: const Color(0xFF3457F1)),
            ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(item.label, style: const TextStyle(fontWeight: FontWeight.w800, color: Color(0xFF17203A))),
                const SizedBox(height: 4),
                Text(
                  item.path.split('/').last,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: Color(0xFF66718F), fontWeight: FontWeight.w500),
                ),
              ],
            ),
          ),
          IconButton(
            onPressed: onRemove,
            icon: const Icon(Icons.close_rounded),
            style: IconButton.styleFrom(
              backgroundColor: const Color(0xFFF4F7FB),
              foregroundColor: const Color(0xFF5F6F83),
            ),
          ),
        ],
      ),
    );
  }
}
