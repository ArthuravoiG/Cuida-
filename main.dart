import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'models/medication.dart';
import 'screens/detail_screen.dart';
import 'screens/history_screen.dart';
import 'screens/notification_screen.dart';
import 'screens/onboarding_screen.dart';
import 'screens/wizard_screen.dart';
import 'services/database_service.dart';
import 'services/notification_service.dart';
import 'theme.dart';
import 'widgets/common_widgets.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await AppDatabase.instance.database;
  await NotificationService.instance.initialize();
  runApp(const CuidaMaisApp());
}

class CuidaMaisApp extends StatelessWidget {
  const CuidaMaisApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Cuida+',
      debugShowCheckedModeBanner: false,
      theme: buildAppTheme(),
      locale: const Locale('pt', 'BR'),
      supportedLocales: const [Locale('pt', 'BR')],
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      home: const RootShell(),
    );
  }
}

class RootShell extends StatefulWidget {
  const RootShell({super.key});

  @override
  State<RootShell> createState() => _RootShellState();
}

class _RootShellState extends State<RootShell> with WidgetsBindingObserver {
  bool _loading = true;
  bool _showOnboarding = false;
  int _tab = 0; // 0 = Início, 1 = Histórico
  List<Medication> _meds = [];
  List<DoseLog> _logs = [];
  Timer? _minuteTimer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    NotificationService.instance.onDataChanged = _reload;
    NotificationService.instance.onOpenDoseReminder = _handleOpenReminderPayload;
    _bootstrap();
    _minuteTimer = Timer.periodic(const Duration(seconds: 45), (_) => _reload());
  }

  @override
  void dispose() {
    _minuteTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _reload();
    }
  }

  Future<void> _bootstrap() async {
    final seen = await AppDatabase.instance.getSetting('onboarding_done');
    await AppDatabase.instance.markMissedDoses();
    final meds = await AppDatabase.instance.getMedications();
    final logs = await AppDatabase.instance.getDoseLogs();
    await NotificationService.instance.rescheduleAll(meds, logs);
    if (!mounted) return;
    setState(() {
      _showOnboarding = seen != '1';
      _meds = meds;
      _logs = logs;
      _loading = false;
    });
  }

  Future<void> _reload() async {
    await AppDatabase.instance.markMissedDoses();
    final meds = await AppDatabase.instance.getMedications();
    final logs = await AppDatabase.instance.getDoseLogs();
    await NotificationService.instance.rescheduleAll(meds, logs);
    if (!mounted) return;
    setState(() {
      _meds = meds;
      _logs = logs;
    });
  }

  Future<void> _finishOnboarding() async {
    await AppDatabase.instance.setSetting('onboarding_done', '1');
    if (!mounted) return;
    setState(() => _showOnboarding = false);
  }

  ScheduledDose? _computeNextDose() {
    final now = DateTime.now();
    final hoje = dateOnly(now);
    final todayIso = toIsoDate(hoje);
    final tomorrowIso = toIsoDate(hoje.add(const Duration(days: 1)));

    ScheduledDose? best;
    for (final m in _meds.where((x) => x.isAtivo(now))) {
      for (final h in m.horarios) {
        final todayDt = combineDateAndTime(todayIso, h);
        final takenToday = _logs.any(
          (e) =>
              e.medId == m.id &&
              e.data == todayIso &&
              e.hora == h &&
              (e.status == DoseStatus.tomada || e.status == DoseStatus.esquecida),
        );

        DateTime candidateDt;
        String candidateIso;
        if (!takenToday &&
            todayDt.isAfter(now.subtract(const Duration(minutes: 60))) &&
            m.ocorreNaData(hoje)) {
          candidateDt = todayDt;
          candidateIso = todayIso;
        } else {
          final amanha = hoje.add(const Duration(days: 1));
          if (!m.ocorreNaData(amanha)) continue;
          candidateDt = combineDateAndTime(tomorrowIso, h);
          candidateIso = tomorrowIso;
        }

        final lastSnooze = _logs
            .where((e) =>
                e.medId == m.id &&
                e.data == candidateIso &&
                e.hora == h &&
                e.status == DoseStatus.adiada)
            .firstOrNull;

        if (best == null || candidateDt.isBefore(best.dateTime)) {
          best = ScheduledDose(
            med: m,
            data: candidateIso,
            hora: h,
            dateTime: candidateDt,
            snoozedUntil: lastSnooze?.horarioAdiado,
          );
        }
      }
    }
    return best;
  }

  void _handleOpenReminderPayload(DoseNotificationPayload payload) {
    final med = _meds.where((m) => m.id == payload.medId).firstOrNull;
    if (med == null || !mounted) return;
    _openReminderScreen(med: med, data: payload.data, hora: payload.hora);
  }

  Future<void> _openReminderScreen({
    required Medication med,
    required String data,
    required String hora,
  }) async {
    final lows = _meds.where((m) => m.isEstoqueBaixo()).toList();
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => DoseNotificationScreen(
          med: med,
          data: data,
          hora: hora,
          lowStockMeds: lows,
          onTake: () async {
            final updated = await AppDatabase.instance.recordDoseTaken(
              medId: med.id!,
              data: data,
              hora: hora,
            );
            if (updated != null && updated.isEstoqueBaixo()) {
              await NotificationService.instance.showLowStockNotification(updated);
            }
            await _reload();
            return updated;
          },
          onSnooze: (min) async {
            final log = await AppDatabase.instance.recordDoseSnoozed(
              medId: med.id!,
              data: data,
              hora: hora,
              minutes: min,
            );
            await NotificationService.instance.scheduleSnoozeNotification(
              med: med,
              data: data,
              horaOriginal: hora,
              minutes: min,
            );
            await _reload();
            return log.horarioAdiado ?? hora;
          },
        ),
      ),
    );
  }

  Future<void> _openNewMedication() async {
    final created = await Navigator.push<Medication>(
      context,
      MaterialPageRoute(builder: (_) => const MedicationWizardScreen()),
    );
    if (created == null) return;
    final saved = await AppDatabase.instance.insertMedication(created);
    await _reload();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('${saved.nome} cadastrado')),
    );
  }

  Future<void> _openMedicationDetail(Medication med) async {
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (detailCtx) {
          final current = _meds.where((m) => m.id == med.id).firstOrNull ?? med;
          return MedicationDetailScreen(
            med: current,
            logs: _logs,
            onEdit: (step) async {
              final edited = await Navigator.push<Medication>(
                detailCtx,
                MaterialPageRoute(
                  builder: (_) => MedicationWizardScreen(
                    initialMedication: current,
                    initialStep: step,
                  ),
                ),
              );
              if (edited == null) return;
              await AppDatabase.instance.updateMedication(edited);
              await _reload();
              if (!detailCtx.mounted) return;
              Navigator.pop(detailCtx);
              if (!mounted) return;
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Alterações salvas')),
              );
              final refreshed = _meds.where((m) => m.id == edited.id).firstOrNull;
              if (refreshed != null) {
                _openMedicationDetail(refreshed);
              }
            },
            onDelete: () async {
              final nome = current.nome;
              await AppDatabase.instance.deleteMedication(current.id!);
              await _reload();
              if (!detailCtx.mounted) return;
              Navigator.pop(detailCtx);
              if (!mounted) return;
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text('$nome excluído')),
              );
            },
            onViewAllHistory: () {
              Navigator.pop(detailCtx);
              setState(() => _tab = 1);
            },
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator(color: AppColors.primary)),
      );
    }

    if (_showOnboarding) {
      return OnboardingScreen(onFinished: _finishOnboarding);
    }

    return Scaffold(
      body: SafeArea(
        child: _tab == 0 ? _buildHome() : HistoryView(meds: _meds, logs: _logs),
      ),
      bottomNavigationBar: _buildBottomNav(),
    );
  }

  Widget _buildHome() {
    final now = DateTime.now();
    final ativos = _meds.where((m) => m.isAtivo(now)).toList();
    final encerrados = _meds.where((m) => !m.isAtivo(now)).toList();
    final lows = ativos.where((m) => m.isEstoqueBaixo(now)).toList();
    final next = _computeNextDose();

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 28),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            formatLongDatePt(now),
            style: const TextStyle(color: AppColors.muted, fontSize: 14),
          ),
          const SizedBox(height: 2),
          const Text(
            'Meus remédios',
            style: TextStyle(fontSize: 28, fontWeight: FontWeight.w800, letterSpacing: -0.5),
          ),
          const SizedBox(height: 16),
          if (next != null) ...[
            _buildNextDoseCard(next, now),
            const SizedBox(height: 12),
          ],
          ...lows.map((m) => Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: _buildLowStockBanner(m),
              )),
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text(
                'Em tratamento',
                style: TextStyle(fontSize: 19, fontWeight: FontWeight.w800),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                decoration: BoxDecoration(
                  color: AppColors.secondary,
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text(
                  '${ativos.length}',
                  style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          if (ativos.isEmpty)
            const AppCard(
              padding: EdgeInsets.all(24),
              child: Center(
                child: Text.rich(
                  TextSpan(
                    style: TextStyle(color: AppColors.muted, fontSize: 15, height: 1.45),
                    children: [
                      TextSpan(text: 'Nenhum remédio ativo.\nToque em '),
                      TextSpan(
                        text: 'Adicionar',
                        style: TextStyle(color: AppColors.primary, fontWeight: FontWeight.w800),
                      ),
                      TextSpan(text: ' abaixo para cadastrar.'),
                    ],
                  ),
                  textAlign: TextAlign.center,
                ),
              ),
            )
          else
            ...ativos.map(
              (m) => Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: _buildActiveMedCard(m, now),
              ),
            ),
          if (encerrados.isNotEmpty) ...[
            const SizedBox(height: 12),
            const Text(
              'Encerrados',
              style: TextStyle(fontSize: 19, fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 10),
            ...encerrados.map(
              (m) => Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: _buildEndedMedCard(m),
              ),
            ),
          ],
          const SizedBox(height: 16),
          const Center(
            child: Padding(
              padding: EdgeInsets.symmetric(horizontal: 16),
              child: Text(
                'O Cuida+ organiza horários e não substitui a orientação médica.',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 12, color: AppColors.muted),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildNextDoseCard(ScheduledDose next, DateTime now) {
    final delta = next.dateTime.difference(now);
    final isNow = delta.inMinutes <= 0;
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: AppColors.primary,
        borderRadius: BorderRadius.circular(28),
        boxShadow: [
          BoxShadow(
            color: AppColors.primary.withValues(alpha: 0.35),
            blurRadius: 24,
            offset: const Offset(0, 12),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text(
                'PRÓXIMA DOSE',
                style: TextStyle(
                  color: Colors.white70,
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.6,
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
                decoration: BoxDecoration(
                  color: isNow ? AppColors.accent : Colors.white.withValues(alpha: 0.18),
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text(
                  formatDeltaDuration(delta),
                  style: TextStyle(
                    color: isNow ? AppColors.text : Colors.white,
                    fontWeight: FontWeight.w700,
                    fontSize: 13,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Text(
                next.hora,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 44,
                  fontWeight: FontWeight.w800,
                  height: 1.0,
                  letterSpacing: -1,
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      next.med.nome,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 19,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    Text(
                      '${next.med.dosagem} · ${pluralComprimido(next.med.comprimidosPorDose)}',
                      style: const TextStyle(color: Colors.white70, fontSize: 15),
                    ),
                  ],
                ),
              ),
            ],
          ),
          if (next.snoozedUntil != null) ...[
            const SizedBox(height: 10),
            Row(
              children: [
                const Icon(Icons.snooze_rounded, color: Colors.white, size: 16),
                const SizedBox(width: 6),
                Text(
                  'Adiada · novo aviso às ${next.snoozedUntil}',
                  style: const TextStyle(color: Colors.white, fontSize: 14),
                ),
              ],
            ),
          ],
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: () => _openReminderScreen(
              med: next.med,
              data: next.data,
              hora: next.hora,
            ),
            style: FilledButton.styleFrom(
              backgroundColor: Colors.white,
              foregroundColor: AppColors.primary,
            ),
            icon: const Icon(Icons.notifications_none_rounded, size: 20),
            label: const Text('Ver lembrete'),
          ),
        ],
      ),
    );
  }

  Widget _buildLowStockBanner(Medication m) {
    final dias = m.diasDeEstoque;
    return InkWell(
      borderRadius: BorderRadius.circular(20),
      onTap: () => _openMedicationDetail(m),
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: AppColors.accentSoft,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: AppColors.accent, width: 1.5),
        ),
        child: Row(
          children: [
            const Icon(Icons.warning_amber_rounded, color: AppColors.accentDark, size: 24),
            const SizedBox(width: 12),
            Expanded(
              child: Text.rich(
                TextSpan(
                  style: const TextStyle(fontSize: 14, color: AppColors.text),
                  children: [
                    TextSpan(
                      text: '${m.nome} está acabando. ',
                      style: const TextStyle(fontWeight: FontWeight.w800),
                    ),
                    TextSpan(
                      text:
                          'Restam ${pluralComprimido(m.estoqueAtual)}, o suficiente para $dias dia${dias == 1 ? '' : 's'}.',
                    ),
                  ],
                ),
              ),
            ),
            const Icon(Icons.chevron_right_rounded, color: AppColors.accentDark),
          ],
        ),
      ),
    );
  }

  Widget _buildActiveMedCard(Medication m, DateTime now) {
    final low = m.isEstoqueBaixo(now);
    final endIso = m.dataFinal;
    final dl = m.diasRestantes(now);
    final fimLabel = m.usoContinuo
        ? 'Uso contínuo'
        : (dl == 0
            ? 'Termina hoje'
            : (dl == 1 ? 'Termina amanhã' : 'Termina ${formatBrShort(endIso!)}'));

    return AppCard(
      onTap: () => _openMedicationDetail(m),
      child: Row(
        children: [
          MedAvatar(med: m, size: 60),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text.rich(
                  TextSpan(
                    children: [
                      TextSpan(
                        text: '${m.nome} ',
                        style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
                      ),
                      TextSpan(
                        text: m.dosagem,
                        style: const TextStyle(fontSize: 15, color: AppColors.muted, fontWeight: FontWeight.w600),
                      ),
                    ],
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 6),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: m.horarios.map((h) {
                    return Container(
                      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
                      decoration: BoxDecoration(
                        color: AppColors.primarySoft,
                        borderRadius: BorderRadius.circular(999),
                      ),
                      child: Text(
                        h,
                        style: const TextStyle(
                          color: AppColors.primary,
                          fontWeight: FontWeight.w700,
                          fontSize: 13,
                        ),
                      ),
                    );
                  }).toList(),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Icon(
                      Icons.inventory_2_outlined,
                      size: 15,
                      color: low ? AppColors.accentDark : AppColors.muted,
                    ),
                    const SizedBox(width: 4),
                    Text(
                      '${m.estoqueAtual} comp.',
                      style: TextStyle(
                        fontSize: 13,
                        color: low ? AppColors.accentDark : AppColors.muted,
                        fontWeight: low ? FontWeight.w800 : FontWeight.w500,
                      ),
                    ),
                    const Text(' · ', style: TextStyle(color: AppColors.muted)),
                    Flexible(
                      child: Text(
                        fimLabel,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 13, color: AppColors.muted),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const Icon(Icons.chevron_right_rounded, color: AppColors.muted),
        ],
      ),
    );
  }

  Widget _buildEndedMedCard(Medication m) {
    return Opacity(
      opacity: 0.82,
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: () => _openMedicationDetail(m),
        child: Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: AppColors.secondary,
            borderRadius: BorderRadius.circular(20),
          ),
          child: Row(
            children: [
              MedAvatar(med: m, size: 44),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '${m.nome} ${m.dosagem}',
                      style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15),
                    ),
                    Text(
                      'Encerrado em ${formatBrDate(m.dataFinal!)}',
                      style: const TextStyle(color: AppColors.muted, fontSize: 13),
                    ),
                  ],
                ),
              ),
              const Icon(Icons.chevron_right_rounded, color: AppColors.muted, size: 20),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildBottomNav() {
    return Container(
      decoration: const BoxDecoration(
        color: Colors.white,
        border: Border(top: BorderSide(color: AppColors.line)),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 10),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: [
              _navButton(0, Icons.home_rounded, 'Início'),
              InkWell(
                borderRadius: BorderRadius.circular(999),
                onTap: _openNewMedication,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 60,
                      height: 60,
                      decoration: BoxDecoration(
                        color: AppColors.primary,
                        shape: BoxShape.circle,
                        boxShadow: [
                          BoxShadow(
                            color: AppColors.primary.withValues(alpha: 0.45),
                            blurRadius: 14,
                            offset: const Offset(0, 6),
                          ),
                        ],
                      ),
                      child: const Icon(Icons.add_rounded, color: Colors.white, size: 32),
                    ),
                    const SizedBox(height: 4),
                    const Text(
                      'Adicionar',
                      style: TextStyle(
                        color: AppColors.primary,
                        fontWeight: FontWeight.w700,
                        fontSize: 13,
                      ),
                    ),
                  ],
                ),
              ),
              _navButton(1, Icons.schedule_rounded, 'Histórico'),
            ],
          ),
        ),
      ),
    );
  }

  Widget _navButton(int index, IconData icon, String label) {
    final selected = _tab == index;
    final color = selected ? AppColors.primary : AppColors.muted;
    return InkWell(
      borderRadius: BorderRadius.circular(16),
      onTap: () => setState(() => _tab = index),
      child: SizedBox(
        width: 84,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, color: color, size: 28),
              const SizedBox(height: 2),
              Text(
                label,
                style: TextStyle(
                  color: color,
                  fontSize: 13,
                  fontWeight: selected ? FontWeight.w800 : FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
