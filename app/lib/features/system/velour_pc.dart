// Velour › PC panel: the PC side of listening. Velour's volume and the system volume, the audio output, the equalizer,
// the sleep timer (and what the PC does when it ends), screen off, Velour to the front, and the phone's own controls.
// Sound changes need no control session; screen off and "show on PC" open one (they change the desktop).
part of 'velour_screen.dart';

class VelourPcView extends ConsumerStatefulWidget {
  const VelourPcView({super.key, required this.hostId});
  final String hostId;
  @override
  ConsumerState<VelourPcView> createState() => _VelourPcViewState();
}

class _VelourPcViewState extends ConsumerState<VelourPcView> {
  double? _velourVol;
  double? _systemVol;

  String get _host => widget.hostId;

  Future<void> _system(Map<String, Object?> body) async {
    final l = AppLocalizations.of(context);
    try {
      await agentCall(ref, _host, 'PUT', '/v1/media/volume', body);
    } catch (e) {
      if (mounted) toast(context, agentErrorText(l, e));
    }
    if (mounted) ref.invalidate(pcVolumeProvider(_host));
  }

  Future<void> _output(AudioOutput o) async {
    final l = AppLocalizations.of(context);
    unawaited(HapticFeedback.selectionClick());
    try {
      await agentCall(ref, _host, 'PUT', '/v1/media/output', {'id': o.id});
      if (mounted) toast(context, l.velourOutputSet(o.name));
    } catch (e) {
      if (mounted) toast(context, agentErrorText(l, e));
    }
    if (mounted) {
      ref.invalidate(pcOutputsProvider(_host));
      ref.invalidate(pcVolumeProvider(_host));
    }
  }

  Future<void> _eq(String preset) async {
    if (await velourAct(ref, context, _host, {'op': 'set-eq', 'preset': preset}) && mounted) ref.invalidate(velourEqProvider(_host));
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final t = context.tokens;
    final s = ref.watch(velourStateProvider(_host)).value;
    final sys = ref.watch(pcVolumeProvider(_host));
    final outputs = ref.watch(pcOutputsProvider(_host));
    final eq = ref.watch(velourEqProvider(_host));
    final phone = ref.watch(velourMediaProvider.select((m) => m.enabled));

    Widget volume({required IconData icon, required String label, required double value, required bool muted, required ValueChanged<double> onChanged, required ValueChanged<double> onEnd, required VoidCallback onMute}) =>
        Row(children: [
          IconButton(
            tooltip: muted ? l.mediaUnmute : l.mediaMute,
            isSelected: muted,
            icon: Icon(muted ? LucideIcons.volumeX : icon, color: muted ? t.danger : t.text),
            onPressed: onMute,
          ),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Padding(
                padding: const EdgeInsets.only(left: 8),
                child: Row(children: [
                  Expanded(child: Text(label, style: TextStyle(fontWeight: FontWeight.w700, color: t.text))),
                  Text(muted ? l.mediaMuted : '%${value.round()}', style: TextStyle(color: t.textSecondary, fontWeight: FontWeight.w600, fontSize: 13)),
                ]),
              ),
              Slider(
                value: value.clamp(0, 100).toDouble(),
                max: 100,
                divisions: 20,
                semanticFormatterCallback: (v) => '$label %${v.round()}',
                onChanged: onChanged,
                onChangeEnd: onEnd,
              ),
            ]),
          ),
        ]);

    return ListView(padding: const EdgeInsets.fromLTRB(TiphysTokens.gutter, 8, TiphysTokens.gutter, 40), children: [
      // ---- sound ----
      TCard(
        padding: const EdgeInsets.fromLTRB(4, 8, 14, 4),
        child: Column(children: [
          if (s != null)
            volume(
              icon: LucideIcons.music2,
              label: l.velourVolumeVelour,
              value: _velourVol ?? s.volume,
              muted: s.muted,
              onChanged: (v) => setState(() => _velourVol = v),
              onEnd: (v) async {
                await velourAct(ref, context, _host, {'op': 'volume', 'percent': v.roundToDouble()}, optimistic: (s, now) => s.copyWith(now, volume: v.roundToDouble(), muted: false));
                if (mounted) setState(() => _velourVol = null);
              },
              onMute: () => velourAct(ref, context, _host, {'op': 'mute', 'on': !s.muted}, optimistic: (x, now) => x.copyWith(now, muted: !s.muted)),
            ),
          ...sys.when(
            loading: () => const [SizedBox(height: 56)],
            error: (e, _) => [ListTile(leading: Icon(LucideIcons.circleAlert, color: t.danger), title: Text(agentErrorText(l, e)))],
            data: (v) => [
              volume(
                icon: LucideIcons.volume2,
                label: l.velourVolumeSystem,
                value: _systemVol ?? v.$1.toDouble(),
                muted: v.$2,
                onChanged: (x) => setState(() => _systemVol = x),
                onEnd: (x) async {
                  await _system({'percent': x.round()});
                  if (mounted) setState(() => _systemVol = null);
                },
                onMute: () => _system({'muted': !v.$2}),
              ),
            ],
          ),
        ]),
      ),
      // ---- audio output ----
      SectionLabel(l.velourOutput),
      TCard(
        padding: EdgeInsets.zero,
        radius: TiphysTokens.radiusList,
        child: outputs.when(
          loading: () => const Padding(padding: EdgeInsets.all(20), child: Center(child: CircularProgressIndicator())),
          error: (e, _) => ListTile(leading: Icon(LucideIcons.circleAlert, color: t.danger), title: Text(agentErrorText(l, e))),
          data: (list) => list.isEmpty
              ? ListTile(leading: const Icon(LucideIcons.speaker), title: Text(l.velourOutputNone))
              : Column(children: [
                  for (final o in list)
                    Semantics(
                      selected: o.isDefault,
                      child: ListTile(
                        leading: Icon(_outputIcon(o.name), color: o.isDefault ? t.accent : t.textSecondary),
                        title: Text(o.name, maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(fontWeight: o.isDefault ? FontWeight.w700 : null)),
                        trailing: o.isDefault ? Icon(LucideIcons.circleCheck, color: t.accent) : null,
                        onTap: o.isDefault ? null : () => _output(o),
                      ),
                    ),
                ]),
        ),
      ),
      // ---- equalizer ----
      SectionLabel(l.velourEq),
      eq.when(
        loading: () => const SizedBox(height: 48),
        error: (_, _) => Text(l.velourNeedsUpdate, style: TextStyle(color: t.textSecondary)),
        data: (e) => Wrap(spacing: 8, runSpacing: 8, children: [
          for (final p in e.$2)
            ChoiceChip(
              label: Text(p),
              selected: (s?.eq ?? e.$1) == p,
              showCheckmark: false,
              onSelected: (_) => _eq(p),
            ),
        ]),
      ),
      // ---- sleep timer ----
      SectionLabel(l.velourSleep),
      VelourSleepSection(hostId: _host),
      // ---- the PC itself ----
      const SizedBox(height: 14),
      TCard(
        padding: EdgeInsets.zero,
        radius: TiphysTokens.radiusList,
        child: Column(children: [
          ListTile(
            leading: const Icon(LucideIcons.monitorOff),
            title: Text(l.velourScreenOff),
            subtitle: Text(l.velourScreenOffHint),
            onTap: () => desktopAction(context, ref, _host, '/v1/desktop/dpms/off', done: l.velourScreenOffDone),
          ),
          Divider(height: 1, indent: 56, color: t.separator),
          ListTile(
            leading: const Icon(LucideIcons.appWindow),
            title: Text(l.velourShowOnPc),
            onTap: () => desktopAction(context, ref, _host, '/v1/velour/show', done: l.velourShowOnPcDone),
          ),
          Divider(height: 1, indent: 56, color: t.separator),
          SwitchListTile(
            secondary: const Icon(LucideIcons.smartphone),
            title: Text(l.velourPhoneControls),
            subtitle: Text(l.velourPhoneControlsHint),
            value: phone,
            onChanged: (v) => ref.read(velourMediaProvider.notifier).setEnabled(v),
          ),
        ]),
      ),
    ]);
  }
}

IconData _outputIcon(String name) {
  final n = name.toLowerCase();
  if (RegExp(r'head|kulak|buds|wh-|airpods|bluez|bluetooth').hasMatch(n)) return LucideIcons.headphones;
  if (RegExp(r'hdmi|displayport|monitor|tv').hasMatch(n)) return LucideIcons.monitor;
  return LucideIcons.speaker;
}

/// The sleep timer on its own (the moon button in the player).
Future<void> showVelourSleepSheet(BuildContext context, String hostId) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    backgroundColor: const Color(0xFF15151A),
    builder: (sheet) => Theme(
      data: _playerTheme(),
      child: Builder(
        builder: (context) => SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(TiphysTokens.gutter, 0, TiphysTokens.gutter, 28),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Padding(
              padding: const EdgeInsets.only(left: 4, bottom: 10),
              child: Text(AppLocalizations.of(context).velourSleep, style: Theme.of(context).textTheme.titleLarge),
            ),
            VelourSleepSection(hostId: hostId),
          ]),
        ),
      ),
    ),
  );
}

/// Sleep timer: the running one (with Cancel), a length (15–60 min or the end of the song) and what the PC does then.
class VelourSleepSection extends ConsumerStatefulWidget {
  const VelourSleepSection({super.key, required this.hostId});
  final String hostId;
  @override
  ConsumerState<VelourSleepSection> createState() => _VelourSleepSectionState();
}

class _VelourSleepSectionState extends ConsumerState<VelourSleepSection> {
  String? _then;
  bool _busy = false;

  /// minutes == null && !endOfTrack cancels.
  Future<void> _set({int? minutes, bool endOfTrack = false}) async {
    final l = AppLocalizations.of(context);
    final cancel = minutes == null && !endOfTrack;
    final then = cancel ? 'none' : (_then ?? 'none');
    final body = <String, Object?>{'minutes': ?minutes, if (endOfTrack) 'endOfTrack': true, 'then': then};
    Map<String, String>? headers;
    if (then == 'suspend') {
      if (!await confirmDialog(context, message: l.velourSleepSuspendConfirm, confirmLabel: l.velourSleepThenSuspend)) return;
      body['confirm'] = true;
    }
    if (!mounted) return;
    final ctrl = ref.read(controlProvider.notifier);
    if (then == 'screenOff') {
      // Turning the screen off later changes the desktop: needs a control session now.
      final session = await ctrl.ensure(context, widget.hostId);
      if (session == null || !mounted) return;
      headers = {controlHeader: session.token};
    }
    final live = ProviderScope.containerOf(context, listen: false).read(velourStateProvider(widget.hostId).notifier);
    setState(() => _busy = true);
    unawaited(HapticFeedback.selectionClick());
    try {
      final r = await agentCall(ref, widget.hostId, 'POST', '/v1/velour/sleep', body, headers) as Map;
      live.apply(r['result']);
      if (mounted) toast(context, cancel ? l.velourSleepCancelled : l.velourSleepSet);
    } catch (e) {
      if (e is AgentError && e.code == 'agent.control.sessionRequired') ctrl.forget();
      if (mounted) toast(context, velourErrorText(l, e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final t = context.tokens;
    final s = ref.watch(velourStateProvider(widget.hostId)).value;
    if (s != null && s.rev == null) return Text(l.velourNeedsUpdate, style: TextStyle(color: t.textSecondary));
    final sleep = s?.sleep;
    final then = _then ?? sleep?.then ?? 'none';
    final thenLabel = {'none': l.velourSleepThenNone, 'screenOff': l.velourSleepThenScreen, 'suspend': l.velourSleepThenSuspend};
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      if (sleep != null)
        Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: TCard(
            padding: const EdgeInsets.fromLTRB(14, 10, 6, 10),
            child: Row(children: [
              Icon(LucideIcons.moon, color: t.accent, fill: 1),
              const SizedBox(width: 12),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(sleep.endsAt == null ? l.velourSleepActiveTrack : l.velourSleepActiveAt(_sleepShort(context, sleep)),
                      style: TextStyle(fontWeight: FontWeight.w700, color: t.text)),
                  if (sleep.then != 'none')
                    Text('${l.velourSleepThen}: ${thenLabel[sleep.then] ?? sleep.then}', style: TextStyle(color: t.textSecondary, fontSize: 13)),
                ]),
              ),
              TextButton(onPressed: _busy ? null : () => _set(), child: Text(l.velourSleepOff)),
            ]),
          ),
        ),
      Wrap(spacing: 8, runSpacing: 8, children: [
        for (final m in const [15, 30, 45, 60])
          ActionChip(avatar: const Icon(LucideIcons.timer, size: 16), label: Text(l.velourSleepMinutes(m)), onPressed: _busy ? null : () => _set(minutes: m)),
        ActionChip(avatar: const Icon(LucideIcons.music, size: 16), label: Text(l.velourSleepEndOfTrack), onPressed: _busy ? null : () => _set(endOfTrack: true)),
      ]),
      const SizedBox(height: 14),
      Padding(
        padding: const EdgeInsets.only(left: 4, bottom: 6),
        child: Text(l.velourSleepThen, style: TextStyle(color: t.textSecondary, fontWeight: FontWeight.w600, fontSize: 13)),
      ),
      Wrap(spacing: 8, runSpacing: 8, children: [
        for (final (value, icon) in const [('none', LucideIcons.ban), ('screenOff', LucideIcons.monitorOff), ('suspend', LucideIcons.power)])
          ChoiceChip(
            avatar: Icon(icon, size: 16),
            label: Text(thenLabel[value]!),
            selected: then == value,
            showCheckmark: false,
            onSelected: (_) => setState(() => _then = value),
          ),
      ]),
    ]);
  }
}
