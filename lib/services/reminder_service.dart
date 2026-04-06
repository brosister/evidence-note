import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter/services.dart';
import 'package:timezone/data/latest.dart' as tz;
import 'package:timezone/timezone.dart' as tz;

import '../app_constants.dart';
import '../models/evidence_models.dart';

class ReminderService {
  ReminderService._();

  static final ReminderService instance = ReminderService._();
  final FlutterLocalNotificationsPlugin _plugin = FlutterLocalNotificationsPlugin();

  Future<void> init() async {
    tz.initializeTimeZones();
    final timezoneName = await FlutterTimezone.getLocalTimezone();
    tz.setLocalLocation(tz.getLocation(timezoneName));

    const android = AndroidInitializationSettings('@mipmap/ic_launcher');
    const ios = DarwinInitializationSettings();
    await _plugin.initialize(const InitializationSettings(android: android, iOS: ios));

    await _plugin
        .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
        ?.createNotificationChannel(
          const AndroidNotificationChannel(
            kNotificationChannelId,
            kNotificationChannelName,
            importance: Importance.high,
          ),
        );

    await _plugin
        .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
        ?.requestNotificationsPermission();
    await _plugin
        .resolvePlatformSpecificImplementation<IOSFlutterLocalNotificationsPlugin>()
        ?.requestPermissions(alert: true, badge: true, sound: true);
  }

  Future<void> schedule(EvidenceRecord record) async {
    await _plugin.cancel(record.notificationId);
    final reminderAt = record.reminderAt;
    if (reminderAt == null) return;

    final now = DateTime.now();
    if (reminderAt.isBefore(now)) return;

    final dueLabel = record.dueAt == null ? '기한 미설정' : '만기 ${record.dueAt!.month}/${record.dueAt!.day}';
    final details = const NotificationDetails(
      android: AndroidNotificationDetails(
        kNotificationChannelId,
        kNotificationChannelName,
        importance: Importance.high,
        priority: Priority.high,
      ),
      iOS: DarwinNotificationDetails(),
    );
    final scheduledAt = tz.TZDateTime.from(reminderAt, tz.local);

    try {
      await _plugin.zonedSchedule(
        record.notificationId,
        record.amount != null && record.amount! > 0 ? '거래 리마인더' : '약속 리마인더',
        '$dueLabel · ${record.title}',
        scheduledAt,
        details,
        androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
        uiLocalNotificationDateInterpretation: UILocalNotificationDateInterpretation.absoluteTime,
      );
    } on PlatformException catch (error) {
      if (error.code != 'exact_alarms_not_permitted') rethrow;
      await _plugin.zonedSchedule(
        record.notificationId,
        record.amount != null && record.amount! > 0 ? '거래 리마인더' : '약속 리마인더',
        '$dueLabel · ${record.title}',
        scheduledAt,
        details,
        androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
        uiLocalNotificationDateInterpretation: UILocalNotificationDateInterpretation.absoluteTime,
      );
    }
  }

  Future<void> cancel(int id) => _plugin.cancel(id);
}
