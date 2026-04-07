import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:fluttertoast/fluttertoast.dart';

import '../models/evidence_models.dart';

bool useKorean(BuildContext context) => Localizations.localeOf(context).languageCode == 'ko';

String tr(BuildContext context, {required String ko, required String en}) {
  return useKorean(context) ? ko : en;
}

String formatDateTime(DateTime value) {
  final mm = value.month.toString().padLeft(2, '0');
  final dd = value.day.toString().padLeft(2, '0');
  final hh = value.hour.toString().padLeft(2, '0');
  final minValue = value.minute.toString().padLeft(2, '0');
  return '${value.year}.$mm.$dd $hh:$minValue';
}

String formatDate(DateTime value) {
  final mm = value.month.toString().padLeft(2, '0');
  final dd = value.day.toString().padLeft(2, '0');
  return '${value.year}.$mm.$dd';
}

String formatAmount(double value) {
  final rounded = value.round();
  final chars = rounded.toString().split('').reversed.toList();
  final buffer = StringBuffer();
  for (var i = 0; i < chars.length; i++) {
    if (i != 0 && i % 3 == 0) buffer.write(',');
    buffer.write(chars[i]);
  }
  return '${buffer.toString().split('').reversed.join()}원';
}

LossEstimate estimateLoss(EvidenceRecord record) {
  final amount = record.amount ?? 0;
  final baseDate = record.dueAt ?? record.eventAt;
  final days = max(0, DateTime.now().difference(baseDate).inDays);
  final loss = amount * record.dailyLossRate * days;
  if (record.dueAt != null && days == 0 && DateTime.now().isBefore(record.dueAt!)) {
    return const LossEstimate(days: 0, amount: 0, message: '아직 만기 전입니다.');
  }
  return LossEstimate(days: days, amount: loss, message: '지금까지 $days일 지연 → 손해 ${formatAmount(loss)} 추정');
}

Future<void> showAppToast(String message) async {
  await Fluttertoast.cancel();
  await Fluttertoast.showToast(
    msg: message,
    toastLength: Toast.LENGTH_SHORT,
    gravity: ToastGravity.BOTTOM,
    backgroundColor: const Color(0xFF17203A),
    textColor: Colors.white,
    fontSize: 14,
  );
}

String defaultDeviceSummary() {
  if (kIsWeb) return 'Web';
  if (Platform.isIOS) return 'iPhone / iOS';
  if (Platform.isAndroid) return 'Android phone';
  return 'Unknown device';
}

Widget buildPill(String label, Color bg, Color fg) {
  return Container(
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
    decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(999)),
    child: Text(label, style: TextStyle(color: fg, fontWeight: FontWeight.w700)),
  );
}
