import 'package:flutter/material.dart';

class EvidenceRecord {
  const EvidenceRecord({
    required this.id,
    required this.proofId,
    required this.title,
    required this.amount,
    required this.eventAt,
    required this.memo,
    required this.counterpartyName,
    required this.contactId,
    required this.contactLabel,
    required this.createdAt,
    required this.updatedAt,
    required this.status,
    required this.proofHash,
    required this.deviceSummary,
    required this.attachments,
    required this.timeline,
    required this.dailyLossRate,
    required this.dueAt,
    required this.reminderAt,
    required this.notificationId,
  });

  final String id;
  final String proofId;
  final String title;
  final double? amount;
  final DateTime eventAt;
  final String memo;
  final String counterpartyName;
  final String? contactId;
  final String contactLabel;
  final DateTime createdAt;
  final DateTime updatedAt;
  final PromiseStatus status;
  final String proofHash;
  final String deviceSummary;
  final List<AttachmentItem> attachments;
  final List<TimelineEvent> timeline;
  final double dailyLossRate;
  final DateTime? dueAt;
  final DateTime? reminderAt;
  final int notificationId;

  factory EvidenceRecord.preview({required double amount, required DateTime eventAt, required double dailyLossRate}) {
    return EvidenceRecord(
      id: 'preview',
      proofId: 'preview',
      title: 'preview',
      amount: amount,
      eventAt: eventAt,
      memo: '',
      counterpartyName: '',
      contactId: null,
      contactLabel: '',
      createdAt: DateTime.now(),
      updatedAt: DateTime.now(),
      status: PromiseStatus.inProgress,
      proofHash: '',
      deviceSummary: '',
      attachments: const [],
      timeline: const [],
      dailyLossRate: dailyLossRate,
      dueAt: null,
      reminderAt: null,
      notificationId: 0,
    );
  }

  factory EvidenceRecord.fromJson(Map<String, dynamic> json) => EvidenceRecord(
        id: json['id'] as String,
        proofId: json['proofId'] as String,
        title: json['title'] as String,
        amount: (json['amount'] as num?)?.toDouble(),
        eventAt: DateTime.parse(json['eventAt'] as String),
        memo: json['memo'] as String? ?? '',
        counterpartyName: json['counterpartyName'] as String? ?? '',
        contactId: json['contactId'] as String?,
        contactLabel: json['contactLabel'] as String? ?? '',
        createdAt: DateTime.parse(json['createdAt'] as String),
        updatedAt: DateTime.parse(json['updatedAt'] as String),
        status: PromiseStatus.values.byName(json['status'] as String),
        proofHash: json['proofHash'] as String? ?? '',
        deviceSummary: json['deviceSummary'] as String? ?? '',
        attachments: (json['attachments'] as List? ?? const [])
            .map((item) => AttachmentItem.fromJson(Map<String, dynamic>.from(item as Map)))
            .toList(),
        timeline: (json['timeline'] as List? ?? const [])
            .map((item) => TimelineEvent.fromJson(Map<String, dynamic>.from(item as Map)))
            .toList(),
        dailyLossRate: (json['dailyLossRate'] as num?)?.toDouble() ?? 0.0008,
        dueAt: json['dueAt'] == null ? null : DateTime.parse(json['dueAt'] as String),
        reminderAt: json['reminderAt'] == null ? null : DateTime.parse(json['reminderAt'] as String),
        notificationId: json['notificationId'] as int? ?? 0,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'proofId': proofId,
        'title': title,
        'amount': amount,
        'eventAt': eventAt.toIso8601String(),
        'memo': memo,
        'counterpartyName': counterpartyName,
        'contactId': contactId,
        'contactLabel': contactLabel,
        'createdAt': createdAt.toIso8601String(),
        'updatedAt': updatedAt.toIso8601String(),
        'status': status.name,
        'proofHash': proofHash,
        'deviceSummary': deviceSummary,
        'attachments': attachments.map((e) => e.toJson()).toList(),
        'timeline': timeline.map((e) => e.toJson()).toList(),
        'dailyLossRate': dailyLossRate,
        'dueAt': dueAt?.toIso8601String(),
        'reminderAt': reminderAt?.toIso8601String(),
        'notificationId': notificationId,
      };
}

enum PromiseStatus {
  inProgress('진행중', Color(0xFF3457F1)),
  completed('완료됨', Color(0xFF16865A)),
  unresolved('미해결', Color(0xFFD14D1F));

  const PromiseStatus(this.label, this.color);
  final String label;
  final Color color;
}

enum AttachmentType {
  photo('사진', Icons.photo_rounded),
  audio('음성', Icons.mic_rounded),
  signature('서명', Icons.draw_rounded);

  const AttachmentType(this.label, this.icon);
  final String label;
  final IconData icon;
}

class AttachmentItem {
  const AttachmentItem({required this.type, required this.path});

  factory AttachmentItem.photo(String path) => AttachmentItem(type: AttachmentType.photo, path: path);
  factory AttachmentItem.audio(String path) => AttachmentItem(type: AttachmentType.audio, path: path);
  factory AttachmentItem.signature(String path) => AttachmentItem(type: AttachmentType.signature, path: path);

  final AttachmentType type;
  final String path;

  String get label => type.label;

  factory AttachmentItem.fromJson(Map<String, dynamic> json) => AttachmentItem(
        type: AttachmentType.values.byName(json['type'] as String),
        path: json['path'] as String,
      );

  Map<String, dynamic> toJson() => {
        'type': type.name,
        'path': path,
      };
}

enum TimelineEventType {
  created('생성', Icons.add_task_rounded),
  edited('수정', Icons.edit_rounded),
  attachmentAdded('증거 첨부', Icons.attachment_rounded),
  statusChanged('상태 변경', Icons.flag_rounded),
  reminderAnswered('알림 응답', Icons.notifications_active_rounded);

  const TimelineEventType(this.label, this.icon);
  final String label;
  final IconData icon;
}

class TimelineEvent {
  const TimelineEvent({required this.type, required this.description, required this.createdAt});

  final TimelineEventType type;
  final String description;
  final DateTime createdAt;

  factory TimelineEvent.create(TimelineEventType type, String description, DateTime createdAt) {
    return TimelineEvent(type: type, description: description, createdAt: createdAt);
  }

  factory TimelineEvent.fromJson(Map<String, dynamic> json) => TimelineEvent(
        type: TimelineEventType.values.byName(json['type'] as String),
        description: json['description'] as String,
        createdAt: DateTime.parse(json['createdAt'] as String),
      );

  Map<String, dynamic> toJson() => {
        'type': type.name,
        'description': description,
        'createdAt': createdAt.toIso8601String(),
      };
}

class LossEstimate {
  const LossEstimate({required this.days, required this.amount, required this.message});

  final int days;
  final double amount;
  final String message;
}
