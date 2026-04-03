import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import '../app_constants.dart';
import '../models/evidence_models.dart';

class ReminderService {
  ReminderService._();

  static final ReminderService instance = ReminderService._();
  final FlutterLocalNotificationsPlugin _plugin = FlutterLocalNotificationsPlugin();

  Future<void> init() async {
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
    await _plugin.show(
      record.notificationId,
      '오늘 약속 지켜졌나요?',
      record.amount != null && record.amount! > 0 ? '돈 받으셨나요? ${record.title}' : '진행 상태를 확인해 주세요. ${record.title}',
      const NotificationDetails(
        android: AndroidNotificationDetails(kNotificationChannelId, kNotificationChannelName, importance: Importance.high),
        iOS: DarwinNotificationDetails(),
      ),
    );
  }

  Future<void> cancel(int id) => _plugin.cancel(id);
}
