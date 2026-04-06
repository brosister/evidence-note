import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_contacts/flutter_contacts.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';
import 'package:record/record.dart';
import 'package:share_plus/share_plus.dart';
import 'package:signature/signature.dart';
import 'package:uuid/uuid.dart';

import 'models/evidence_models.dart';
import 'services/evidence_repository.dart';
import 'services/reminder_service.dart';
import 'utils/app_formatters.dart';

const _uuid = Uuid();

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
  await ReminderService.instance.init();

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
      supportedLocales: const [
        Locale('en'),
        Locale('ko'),
        Locale('ja'),
        Locale('zh', 'Hans'),
      ],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      theme: ThemeData(
        useMaterial3: true,
        fontFamily: 'Pretendard',
        scaffoldBackgroundColor: const Color(0xFFF4F7FF),
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF4E6BFF)),
        appBarTheme: const AppBarTheme(
          backgroundColor: Color(0xFFF4F7FF),
          surfaceTintColor: Colors.transparent,
          elevation: 0,
          scrolledUnderElevation: 0,
          systemOverlayStyle: SystemUiOverlayStyle(
            statusBarColor: Colors.transparent,
            statusBarIconBrightness: Brightness.dark,
            statusBarBrightness: Brightness.dark,
          ),
        ),
        cardTheme: CardTheme(
          color: Colors.white,
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
  int _tabIndex = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final records = await widget.repository.loadRecords();
    if (!mounted) return;
    setState(() => _records = records);
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

  Future<void> _openEditor({EvidenceRecord? existing}) async {
    final changed = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => EvidenceEditorPage(
          repository: widget.repository,
          existing: existing,
        ),
      ),
    );
    if (changed == true) {
      await _load();
    }
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

  @override
  Widget build(BuildContext context) {
    final records = _filteredRecords;
    final unresolvedAmount = _records
        .where((record) => record.status != PromiseStatus.completed)
        .fold<double>(0, (sum, item) => sum + (item.amount ?? 0));
    final unresolvedCount = _records.where((record) => record.status == PromiseStatus.unresolved).length;

    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: const [
            Text(
              '증거노트',
              style: TextStyle(fontWeight: FontWeight.w900, color: Color(0xFF17203A)),
            ),
            Text(
              '약속·거래 기록과 증거를 한 번에 정리',
              style: TextStyle(fontSize: 12, color: Color(0xFF66718F)),
            ),
          ],
        ),
        toolbarHeight: 72,
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _openEditor,
        icon: const Icon(Icons.add_rounded),
        label: const Text('새 기록'),
      ),
      body: SafeArea(
        top: false,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 10),
              child: Column(
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: _summaryTile(
                          '미회수 금액',
                          formatAmount(unresolvedAmount),
                          const Color(0xFFEAF0FF),
                          const Color(0xFF3457F1),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: _summaryTile(
                          '미해결 건수',
                          '$unresolvedCount건',
                          const Color(0xFFFFF0EC),
                          const Color(0xFFD14D1F),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    onChanged: (value) => setState(() => _searchQuery = value),
                    decoration: InputDecoration(
                      hintText: '제목, 상대, 메모 검색',
                      prefixIcon: const Icon(Icons.search_rounded),
                      filled: true,
                      fillColor: Colors.white,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(20),
                        borderSide: BorderSide.none,
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      children: [
                        _filterChip('전체', _statusFilter == null, () => setState(() => _statusFilter = null)),
                        const SizedBox(width: 8),
                        ...PromiseStatus.values.map(
                          (status) => Padding(
                            padding: const EdgeInsets.only(right: 8),
                            child: _filterChip(
                              status.label,
                              _statusFilter == status,
                              () => setState(() => _statusFilter = status),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),
                  SegmentedButton<int>(
                    segments: const [
                      ButtonSegment(value: 0, label: Text('내 약속')),
                      ButtonSegment(value: 1, label: Text('타임라인')),
                    ],
                    selected: {_tabIndex},
                    onSelectionChanged: (value) => setState(() => _tabIndex = value.first),
                  ),
                ],
              ),
            ),
            Expanded(
              child: _tabIndex == 0
                  ? _PromiseListTab(records: records, onOpen: _openEditor, onDelete: _deleteRecord)
                  : _TimelineTab(records: records, onOpen: _openEditor),
            ),
          ],
        ),
      ),
    );
  }

  Widget _summaryTile(String title, String value, Color bg, Color fg) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(22)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: TextStyle(color: fg, fontWeight: FontWeight.w700)),
          const SizedBox(height: 6),
          Text(value, style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 20)),
        ],
      ),
    );
  }

  Widget _filterChip(String label, bool selected, VoidCallback onTap) {
    return ChoiceChip(
      label: Text(label),
      selected: selected,
      onSelected: (_) => onTap(),
      labelStyle: TextStyle(fontWeight: FontWeight.w700, color: selected ? Colors.white : const Color(0xFF44506C)),
      selectedColor: const Color(0xFF4E6BFF),
      backgroundColor: Colors.white,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(999), side: BorderSide.none),
      showCheckmark: false,
    );
  }
}

class _PromiseListTab extends StatelessWidget {
  const _PromiseListTab({required this.records, required this.onOpen, required this.onDelete});

  final List<EvidenceRecord> records;
  final Future<void> Function({EvidenceRecord? existing}) onOpen;
  final Future<void> Function(EvidenceRecord record) onDelete;

  @override
  Widget build(BuildContext context) {
    if (records.isEmpty) {
      return const _EmptyState(
        title: '아직 기록이 없습니다',
        body: '새 기록을 만들면 거래/약속/증거가 타임라인으로 정리됩니다.',
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 120),
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
                          } else if (value == 'delete') {
                            onDelete(record);
                          }
                        },
                        itemBuilder: (_) => const [
                          PopupMenuItem(value: 'edit', child: Text('수정')),
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
                        Text('타임스탬프 ${formatDateTime(record.createdAt)}'),
                        Text('고유 ID ${record.proofId}'),
                        Text('해시 ${record.proofHash.substring(0, min(16, record.proofHash.length))}...'),
                        Text('기기 ${record.deviceSummary}'),
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
  const EvidenceEditorPage({super.key, required this.repository, this.existing});

  final EvidenceRepository repository;
  final EvidenceRecord? existing;

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
    final date = await showDatePicker(
      context: context,
      initialDate: _eventAt,
      firstDate: DateTime(2020),
      lastDate: DateTime(2100),
    );
    if (date == null || !mounted) return;
    final time = await showTimePicker(context: context, initialTime: TimeOfDay.fromDateTime(_eventAt));
    if (time == null) return;
    setState(() {
      _eventAt = DateTime(date.year, date.month, date.day, time.hour, time.minute);
    });
  }

  Future<void> _connectContact() async {
    final granted = await FlutterContacts.requestPermission(readonly: true);
    if (!granted || !mounted) {
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
  }

  Future<void> _addPhoto() async {
    final picker = ImagePicker();
    final image = await picker.pickImage(source: ImageSource.gallery, imageQuality: 92);
    if (image == null) return;
    final file = await _copyAttachment(File(image.path), 'photo_${DateTime.now().millisecondsSinceEpoch}.jpg');
    setState(() {
      _attachments.add(AttachmentItem.photo(file.path));
    });
  }

  Future<void> _toggleRecording() async {
    if (_recording) {
      final path = await _audioRecorder.stop();
      if (path != null) {
        final file = File(path);
        final copied = await _copyAttachment(file, 'voice_${DateTime.now().millisecondsSinceEpoch}.m4a');
        setState(() {
          _attachments.add(AttachmentItem.audio(copied.path));
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
    if (data == null) return;
    final file = await _writeBytesAttachment(data, 'signature_${DateTime.now().millisecondsSinceEpoch}.png');
    setState(() {
      _signatureBytes = data;
      _attachments.add(AttachmentItem.signature(file.path));
    });
    _signatureController.clear();
    if (!mounted) return;
    Navigator.pop(context);
  }

  Future<void> _openSignatureSheet() async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (context) => Padding(
        padding: EdgeInsets.only(
          left: 20,
          right: 20,
          top: 20,
          bottom: MediaQuery.of(context).viewInsets.bottom + 20,
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

  Future<void> _save() async {
    if (_saving) return;
    if (_titleController.text.trim().isEmpty || _counterpartyController.text.trim().isEmpty) {
      await showAppToast('제목과 상대 이름은 필수입니다.');
      return;
    }
    setState(() => _saving = true);

    final existing = widget.existing;
    final now = DateTime.now();
    final eventAt = _useCurrentTime ? now : _eventAt;
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
      'attachments': _attachments.map((item) => item.toJson()).toList(),
      'updatedAt': now.toIso8601String(),
    };
    final proofHash = sha256.convert(utf8.encode(jsonEncode(payload))).toString();

    final timeline = List<TimelineEvent>.of(_timeline);
    if (existing == null) {
      timeline.insert(0, TimelineEvent.create(TimelineEventType.created, '약속/거래를 생성했습니다.', now));
    } else {
      timeline.insert(0, TimelineEvent.create(TimelineEventType.edited, '내용을 수정했습니다.', now));
    }
    if (_attachments.isNotEmpty) {
      timeline.insert(0, TimelineEvent.create(TimelineEventType.attachmentAdded, '증거 첨부 ${_attachments.length}건이 연결되었습니다.', now));
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
      attachments: _attachments,
      timeline: timeline.take(60).toList(),
      dailyLossRate: double.tryParse(_lossRateController.text.trim()) ?? 0.0008,
      notificationId: existing?.notificationId ?? _buildNotificationId(),
    );

    await widget.repository.saveRecord(record);
    await ReminderService.instance.schedule(record);
    if (!mounted) return;
    setState(() => _saving = false);
    await showAppToast(existing == null ? '증거 기록을 저장했습니다.' : '기록을 수정했습니다.');
    Navigator.pop(context, true);
  }

  int _buildNotificationId() => widget.existing?.notificationId ?? DateTime.now().millisecondsSinceEpoch.remainder(1 << 30);

  Future<void> _exportPdf() async {
    final title = _titleController.text.trim();
    if (title.isEmpty) {
      await showAppToast('먼저 제목을 입력해 주세요.');
      return;
    }
    final pdf = pw.Document();
    pdf.addPage(
      pw.MultiPage(
        build: (_) => [
          pw.Text('증거노트 요약', style: pw.TextStyle(fontSize: 24, fontWeight: pw.FontWeight.bold)),
          pw.SizedBox(height: 16),
          pw.Text('제목: ${_titleController.text.trim()}'),
          pw.Text('상대: ${_counterpartyController.text.trim()}'),
          pw.Text('금액: ${_amountController.text.trim().isEmpty ? '-' : _amountController.text.trim()}'),
          pw.Text('날짜: ${formatDateTime(_useCurrentTime ? DateTime.now() : _eventAt)}'),
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.existing == null ? '새 기록 만들기' : '기록 수정'),
        actions: [
          IconButton(onPressed: _exportPdf, icon: const Icon(Icons.picture_as_pdf_rounded)),
        ],
      ),
      body: SafeArea(
        top: false,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 32),
          children: [
            _section(
              title: '1️⃣ 약속/거래 생성',
              child: Column(
                children: [
                  _textField(_titleController, '제목', hint: '홍길동 50만원 빌려줌'),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(child: _textField(_counterpartyController, '상대 이름')),
                      const SizedBox(width: 12),
                      FilledButton.tonalIcon(
                        onPressed: _connectContact,
                        icon: const Icon(Icons.contacts_rounded),
                        label: const Text('연락처'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  _textField(_contactController, '연동된 연락처', hint: '연락처 연동 정보'),
                  const SizedBox(height: 12),
                  _textField(_amountController, '금액(옵션)', keyboardType: TextInputType.number),
                  const SizedBox(height: 12),
                  SwitchListTile.adaptive(
                    value: _useCurrentTime,
                    contentPadding: EdgeInsets.zero,
                    title: const Text('현재 시간으로 저장'),
                    subtitle: const Text('끄면 날짜/시간을 직접 입력합니다.'),
                    onChanged: (value) => setState(() => _useCurrentTime = value),
                  ),
                  if (!_useCurrentTime) ...[
                    const SizedBox(height: 8),
                    ListTile(
                      onTap: _pickDateTime,
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.schedule_rounded),
                      title: const Text('날짜/시간 직접 입력'),
                      subtitle: Text(formatDateTime(_eventAt)),
                    ),
                  ],
                  const SizedBox(height: 12),
                  DropdownButtonFormField<PromiseStatus>(
                    initialValue: _status,
                    decoration: _inputDecoration('상태'),
                    items: PromiseStatus.values
                        .map((status) => DropdownMenuItem(value: status, child: Text(status.label)))
                        .toList(),
                    onChanged: (value) => setState(() => _status = value ?? PromiseStatus.inProgress),
                  ),
                  const SizedBox(height: 12),
                  _textField(_memoController, '내용 메모', maxLines: 5, hint: '무슨 약속/거래였는지 핵심 내용을 적어두세요.'),
                ],
              ),
            ),
            const SizedBox(height: 16),
            _section(
              title: '2️⃣ 증거 자동 생성',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _textField(_deviceController, '기기 정보', hint: defaultDeviceSummary()),
                  const SizedBox(height: 12),
                  _textField(_lossRateController, '일 손해 추정 비율', keyboardType: const TextInputType.numberWithOptions(decimal: true)),
                  const SizedBox(height: 10),
                  const Text('저장 순간 타임스탬프 / 고유 ID / 해시값 / 기기 정보가 자동 갱신됩니다.', style: TextStyle(color: Color(0xFF66718F))),
                ],
              ),
            ),
            const SizedBox(height: 16),
            _section(
              title: '3️⃣ 증거 강화 기능',
              child: Column(
                children: [
                  Wrap(
                    spacing: 10,
                    runSpacing: 10,
                    children: [
                      FilledButton.tonalIcon(onPressed: _addPhoto, icon: const Icon(Icons.photo_library_rounded), label: const Text('사진 첨부')),
                      FilledButton.tonalIcon(onPressed: _toggleRecording, icon: Icon(_recording ? Icons.stop_circle_outlined : Icons.mic_rounded), label: Text(_recording ? '녹음 종료' : '음성 녹음')),
                      FilledButton.tonalIcon(onPressed: _openSignatureSheet, icon: const Icon(Icons.draw_rounded), label: const Text('간단 서명')),
                    ],
                  ),
                  const SizedBox(height: 12),
                  if (_attachments.isEmpty)
                    const Align(
                      alignment: Alignment.centerLeft,
                      child: Text('첨부된 증거가 아직 없습니다.', style: TextStyle(color: Color(0xFF66718F))),
                    )
                  else
                    ..._attachments.asMap().entries.map(
                      (entry) => ListTile(
                        contentPadding: EdgeInsets.zero,
                        leading: CircleAvatar(
                          backgroundColor: const Color(0xFFEAF0FF),
                          child: Icon(entry.value.type.icon, color: const Color(0xFF3457F1)),
                        ),
                        title: Text(entry.value.label),
                        subtitle: Text(entry.value.path.split('/').last),
                        trailing: IconButton(
                          onPressed: () => setState(() => _attachments.removeAt(entry.key)),
                          icon: const Icon(Icons.close_rounded),
                        ),
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            _section(
              title: '4️⃣ 상태 / 5️⃣ 알림 / 6️⃣ 손해 계산 / 7️⃣ 공유',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('저장 후 상태 기반 후속 알림이 예약됩니다. 예: “오늘 약속 지켜졌나요?” / “돈 받으셨나요?”', style: TextStyle(color: Color(0xFF44506C), height: 1.45)),
                  const SizedBox(height: 12),
                  if (_amountController.text.trim().isNotEmpty)
                    Text(
                      estimateLoss(
                        EvidenceRecord.preview(
                          amount: double.tryParse(_amountController.text.trim()) ?? 0,
                          eventAt: _useCurrentTime ? DateTime.now() : _eventAt,
                          dailyLossRate: double.tryParse(_lossRateController.text.trim()) ?? 0.0008,
                        ),
                      ).message,
                      style: const TextStyle(fontWeight: FontWeight.w800, color: Color(0xFFD14D1F)),
                    ),
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 10,
                    runSpacing: 10,
                    children: [
                      OutlinedButton.icon(onPressed: _exportPdf, icon: const Icon(Icons.picture_as_pdf_rounded), label: const Text('PDF 생성')),
                      OutlinedButton.icon(
                        onPressed: () async {
                          final text = [
                            _titleController.text.trim(),
                            _counterpartyController.text.trim(),
                            _memoController.text.trim(),
                          ].where((e) => e.isNotEmpty).join('\n');
                          await SharePlus.instance.share(ShareParams(text: text));
                        },
                        icon: const Icon(Icons.ios_share_rounded),
                        label: const Text('카톡/공유'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: _saving ? null : _save,
              icon: const Icon(Icons.save_rounded),
              label: Text(_saving ? '저장 중...' : '기록 저장'),
              style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(56)),
            ),
          ],
        ),
      ),
    );
  }

  Widget _section({required String title, required Widget child}) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 18)),
            const SizedBox(height: 14),
            child,
          ],
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
      fillColor: const Color(0xFFF7F9FF),
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(18), borderSide: BorderSide.none),
    );
  }
}
