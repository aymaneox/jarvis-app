import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:android_intent_plus/android_intent.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:flutter_voice_processor/flutter_voice_processor.dart';
import 'package:http/http.dart' as http;
import 'package:permission_handler/permission_handler.dart';
import 'package:porcupine_flutter/porcupine.dart';
import 'package:porcupine_flutter/porcupine_error.dart';
import 'package:porcupine_flutter/porcupine_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

void main() => runApp(const JarvisApp());

class JarvisApp extends StatelessWidget {
  const JarvisApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Jarvis',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark(useMaterial3: true).copyWith(
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.cyan,
          brightness: Brightness.dark,
        ),
      ),
      home: const ChatPage(),
    );
  }
}

class Msg {
  final String role; // 'user' or 'model'
  final String text;
  Msg(this.role, this.text);
}

class Reply {
  final String heard;
  final String say;
  final List<Map<String, dynamic>> actions;
  final bool error;
  final bool end;
  Reply(
    this.say, {
    this.heard = '',
    this.actions = const [],
    this.error = false,
    this.end = false,
  });
}

class ChatPage extends StatefulWidget {
  const ChatPage({super.key});

  @override
  State<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends State<ChatPage> {
  static const model = 'gemini-3.5-flash-lite';
  static const _native = MethodChannel('jarvis/native');

  final _msgs = <Msg>[];
  final _input = TextEditingController();
  final _scroll = ScrollController();
  final _tts = FlutterTts();

  String _key = '';
  String _pvKey = '';
  String _state = 'off'; // off, idle, listening, thinking, speaking
  bool _active = false;
  bool _inCall = false;
  bool _busy = false;
  bool _ownMic = false;
  bool _listenerAdded = false;
  PorcupineManager? _pm;
  List<Map<String, String>> _apps = [];

  // audio capture
  bool _capturing = false;
  final List<List<int>> _pre = [];
  List<int> _buf = [];
  Completer<Uint8List?>? _cap;
  int _loud = 0;
  int _silent = 0;
  int _frames = 0;
  int _maxWait = 0;
  bool _heardSpeech = false;
  double _noise = 150;

  // watchdog / health
  Timer? _watchdog;
  DateTime _lastFrame = DateTime.now();
  DateTime _lastProgress = DateTime.now();
  DateTime _lastRestart = DateTime.fromMillisecondsSinceEpoch(0);
  int _zeroFrames = 0;
  double _lastRms = 0;
  String _wakeError = '';
  DateTime _lastWakeTry = DateTime.fromMillisecondsSinceEpoch(0);
  String _voiceName = '';
  double _pitch = 0.7;
  double _rate = 0.45;
  final http.Client _http = http.Client();
  bool _notifOn = true;
  Map<String, dynamic>? _pendingNotif;
  final List<Map<String, dynamic>> _notifQueue = [];
  bool _draining = false;
  String? _lastLaunchPkg;
  String _endReason = '';
  List<String> _memories = [];
  bool _capRecovering = false;
  bool _restarting = false;

  @override
  void initState() {
    super.initState();
    _native.setMethodCallHandler(_onNative);
    _setupVoice();
    _loadPrefs();
  }

  // ---------------- helpers ----------------

  void _toast(String m) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));
  }

  void _addMsg(String role, String text) {
    if (!mounted) return;
    setState(() => _msgs.add(Msg(role, text)));
    _scrollDown();
  }

  Future<void> _orb(String state) async {
    try {
      await _native.invokeMethod('setOrb', {'state': state});
    } catch (_) {}
  }

  void _mode(String s) {
    if (mounted) {
      setState(() => _state = s);
    } else {
      _state = s;
    }
    _orb(s == 'off' ? 'idle' : s);
  }

  void _scrollDown() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.animateTo(
          _scroll.position.maxScrollExtent,
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeOut,
        );
      }
    });
  }

  // ---------------- voice (British butler) ----------------

  Future<void> _setupVoice() async {
    try {
      final p = await SharedPreferences.getInstance();
      _pitch = p.getDouble('voice_pitch') ?? 0.7;
      _rate = p.getDouble('voice_rate') ?? 0.45;
      final savedName = p.getString('voice_name') ?? '';
      final savedLocale = p.getString('voice_locale') ?? '';
      await _tts.awaitSpeakCompletion(true);
      await _tts.setLanguage('en-GB');
      await _tts.setPitch(_pitch);
      await _tts.setSpeechRate(_rate);
      if (savedName.isNotEmpty) {
        _voiceName = savedName;
        await _tts.setVoice(
            <String, String>{'name': savedName, 'locale': savedLocale});
        return;
      }
      final voices = await _tts.getVoices;
      if (voices is List) {
        final gb = voices.whereType<Map>().where((v) {
          final loc =
              (v['locale'] ?? '').toString().toLowerCase().replaceAll('_', '-');
          return loc == 'en-gb';
        }).toList();
        Map? pick;
        for (final key in ['rjs', 'gbd', 'gbb']) {
          for (final v in gb) {
            if ((v['name'] ?? '').toString().toLowerCase().contains(key)) {
              pick = v;
              break;
            }
          }
          if (pick != null) break;
        }
        pick ??= gb.isNotEmpty ? gb.first : null;
        if (pick != null) {
          await _tts.setVoice(<String, String>{
            'name': pick['name'].toString(),
            'locale': pick['locale'].toString(),
          });
        }
      }
    } catch (_) {}
  }

  Future<void> _pickVoice() async {
    final list = <Map<String, String>>[];
    try {
      final v = await _tts.getVoices;
      if (v is List) {
        for (final e in v.whereType<Map>()) {
          final loc = (e['locale'] ?? '').toString();
          if (loc.toLowerCase().startsWith('en')) {
            list.add({'name': e['name'].toString(), 'locale': loc});
          }
        }
      }
    } catch (_) {}
    list.sort((a, b) {
      final c = a['locale']!.compareTo(b['locale']!);
      return c != 0 ? c : a['name']!.compareTo(b['name']!);
    });
    if (!mounted) return;
    if (list.isEmpty) {
      _toast('No English voices found. Install "Speech Services by Google" and its English (UK) voice.');
      return;
    }

    var pitch = _pitch;
    var rate = _rate;
    var chosen = _voiceName;
    var chosenLocale = '';

    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) => AlertDialog(
          title: const Text('Choose Jarvis voice'),
          content: SizedBox(
            width: double.maxFinite,
            height: 420,
            child: Column(
              children: [
                Row(children: [
                  const Text('Deep'),
                  Expanded(
                    child: Slider(
                      min: 0.4,
                      max: 1.4,
                      value: pitch,
                      onChanged: (x) => setD(() => pitch = x),
                    ),
                  ),
                  const Text('High'),
                ]),
                Row(children: [
                  const Text('Slow'),
                  Expanded(
                    child: Slider(
                      min: 0.25,
                      max: 0.8,
                      value: rate,
                      onChanged: (x) => setD(() => rate = x),
                    ),
                  ),
                  const Text('Fast'),
                ]),
                const Text('Tap a voice to hear it',
                    style: TextStyle(fontSize: 12)),
                Expanded(
                  child: ListView.builder(
                    itemCount: list.length,
                    itemBuilder: (_, i) {
                      final v = list[i];
                      final sel = v['name'] == chosen;
                      return ListTile(
                        dense: true,
                        selected: sel,
                        title: Text(v['name']!),
                        subtitle: Text(v['locale']!),
                        trailing: sel ? const Icon(Icons.check) : null,
                        onTap: () async {
                          setD(() {
                            chosen = v['name']!;
                            chosenLocale = v['locale']!;
                          });
                          try {
                            await _tts.setVoice(<String, String>{
                              'name': v['name']!,
                              'locale': v['locale']!,
                            });
                            await _tts.setPitch(pitch);
                            await _tts.setSpeechRate(rate);
                            await _tts.speak(
                                'Good evening, sir. How may I assist you?');
                          } catch (_) {}
                        },
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () async {
                try {
                  await _tts.setPitch(pitch);
                  await _tts.setSpeechRate(rate);
                  await _tts.speak('Good evening, sir.');
                } catch (_) {}
              },
              child: const Text('Test'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    );

    // save (also applies the sliders even if no new voice was tapped)
    _pitch = pitch;
    _rate = rate;
    final p = await SharedPreferences.getInstance();
    await p.setDouble('voice_pitch', pitch);
    await p.setDouble('voice_rate', rate);
    try {
      await _tts.setPitch(pitch);
      await _tts.setSpeechRate(rate);
    } catch (_) {}
    if (chosen.isNotEmpty && chosenLocale.isNotEmpty) {
      _voiceName = chosen;
      await p.setString('voice_name', chosen);
      await p.setString('voice_locale', chosenLocale);
    }
  }

  Future<void> _speak(String text) async {
    final t = text.replaceAll(RegExp(r'[*_#`]'), '').trim();
    if (t.isEmpty) return;
    try {
      await _tts.speak(t).timeout(const Duration(seconds: 25), onTimeout: () => null);
    } catch (_) {}
  }

  // ---------------- keys ----------------

  Future<void> _loadPrefs() async {
    final p = await SharedPreferences.getInstance();
    setState(() {
      _key = p.getString('gemini_key') ?? '';
      _pvKey = p.getString('picovoice_key') ?? '';
      _notifOn = p.getBool('notif_on') ?? true;
      _memories = p.getStringList('memories') ?? [];
    });
    if (_key.isEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _askKeys());
    } else if (p.getBool('active') ?? false) {
      await _activate();
      await _backIfBgLaunch();
    }
  }

  Future<void> _askKeys() async {
    final c1 = TextEditingController(text: _key);
    final c2 = TextEditingController(text: _pvKey);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Keys'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: c1,
              obscureText: true,
              decoration: const InputDecoration(
                  labelText: 'Gemini API key (AIza...)'),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: c2,
              obscureText: true,
              decoration: const InputDecoration(
                  labelText: 'Picovoice AccessKey (for "Jarvis")'),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (ok == true) {
      final p = await SharedPreferences.getInstance();
      await p.setString('gemini_key', c1.text.trim());
      await p.setString('picovoice_key', c2.text.trim());
      setState(() {
        _key = c1.text.trim();
        _pvKey = c2.text.trim();
      });
      if (_active && _pm == null && _pvKey.isNotEmpty) {
        await _startWakeWord();
      }
    }
  }

  // ---------------- activate / deactivate ----------------

  Future<void> _activate() async {
    final mic = await Permission.microphone.request();
    if (!mic.isGranted) {
      _toast('Microphone permission is required');
      return;
    }
    await Permission.notification.request();
    await Permission.contacts.request();
    if (!(await Permission.systemAlertWindow.isGranted)) {
      _toast('Please allow "Display over other apps" for Jarvis');
      await Permission.systemAlertWindow.request();
    }
    if (!(await Permission.ignoreBatteryOptimizations.isGranted)) {
      await Permission.ignoreBatteryOptimizations.request();
    }
    try {
      await _native.invokeMethod('startService');
    } catch (_) {}
    await _loadApps();
    await _startWakeWord();
    final p = await SharedPreferences.getInstance();
    await p.setBool('active', true);
    if (!mounted) return;
    setState(() => _active = true);
    _mode('idle');
    _startWatchdog();

    // ask once to enable the accessibility service (scroll, tap, screenshot)
    try {
      final on = await _native.invokeMethod<bool>('a11yEnabled') ?? false;
      if (!on && !(p.getBool('a11y_asked') ?? false)) {
        await p.setBool('a11y_asked', true);
        _toast('Turn on "Jarvis control" in Accessibility so I can scroll, tap and take screenshots');
        await _native.invokeMethod('openA11ySettings');
      }
    } catch (_) {}
    await _checkNotifAccess();
  }

  Future<void> _deactivate() async {
    _watchdog?.cancel();
    _inCall = false;
    _finishCapture(false);
    try {
      await _pm?.stop();
      await _pm?.delete();
    } catch (_) {}
    _pm = null;
    if (_listenerAdded) {
      VoiceProcessor.instance?.removeFrameListener(_onFrame);
      _listenerAdded = false;
    }
    try {
      await _native.invokeMethod('stopService');
    } catch (_) {}
    final p = await SharedPreferences.getInstance();
    await p.setBool('active', false);
    if (!mounted) return;
    setState(() => _active = false);
    _mode('off');
  }

  Future<void> _loadApps() async {
    try {
      final r = await _native.invokeMethod<List<dynamic>>('listApps');
      final list = (r ?? [])
          .map((e) => Map<String, String>.from(e as Map))
          .toList();
      list.sort((a, b) =>
          (a['name'] ?? '').toLowerCase().compareTo((b['name'] ?? '').toLowerCase()));
      _apps = list;
    } catch (_) {}
  }

  Future<void> _startWakeWord() async {
    if (_pm != null) return;
    _lastWakeTry = DateTime.now();
    if (_pvKey.isEmpty) {
      _wakeError = 'no Picovoice key. Tap the key icon and paste your Picovoice AccessKey';
      _toast('Add your Picovoice key (key icon) to enable the "Jarvis" wake word');
      if (mounted) setState(() {});
      return;
    }
    try {
      final pm = await PorcupineManager.fromBuiltInKeywords(
        _pvKey,
        [BuiltInKeyword.JARVIS],
        _onWake,
        sensitivities: [0.75],
        errorCallback: (e) => _toast('Wake word error: $e'),
      );
      await pm.start();
      _pm = pm;
      _wakeError = '';
      _attachFrames();
    } on PorcupineException catch (e) {
      _wakeError = '${e.message}';
      _toast('Wake word failed: ${e.message}');
    } catch (e) {
      _wakeError = '$e';
      _toast('Wake word failed: $e');
    }
    if (mounted) setState(() {});
  }

  void _attachFrames() {
    if (_listenerAdded) return;
    VoiceProcessor.instance?.addFrameListener(_onFrame);
    _listenerAdded = true;
  }

  void _onWake(int index) {
    if (_inCall || !_active) return;
    HapticFeedback.mediumImpact();
    _conversation(afterWake: true);
  }

  // ---------------- watchdog (keeps the wake word alive) ----------------

  void _startWatchdog() {
    _watchdog?.cancel();
    _lastFrame = DateTime.now();
    _watchdog = Timer.periodic(const Duration(seconds: 2), (_) => _tick());
  }

  void _tick() {
    if (!_active) return;
    _beat();
    final now = DateTime.now();

    // a call that is stuck for too long is reset
    if (_inCall && now.difference(_lastProgress).inSeconds > 75) {
      _inCall = false;
      _capturing = false;
      _finishCapture(false);
      _mode('idle');
    }

    // microphone stopped or silenced: restart the wake word engine
    if (!_inCall && _pm != null && !_restarting) {
      final quietFor = now.difference(_lastFrame).inSeconds;
      final sinceRestart = now.difference(_lastRestart).inSeconds;
      if ((quietFor > 6 || _zeroFrames > 250) && sinceRestart > 15) {
        _zeroFrames = 0;
        _lastFrame = now;
        _lastRestart = now;
        _restartWake();
      }
    }
    // wake word is off (for example the key was added later): try again
    if (_pm == null &&
        _pvKey.isNotEmpty &&
        !_restarting &&
        !_inCall &&
        now.difference(_lastWakeTry).inSeconds > 20) {
      _startWakeWord();
    }
    if (mounted) setState(() {});
  }

  Future<void> _restartWake() async {
    if (_restarting) return;
    _restarting = true;
    try {
      try {
        await _pm?.stop();
        await _pm?.delete();
      } catch (_) {}
      _pm = null;
      if (_listenerAdded) {
        VoiceProcessor.instance?.removeFrameListener(_onFrame);
        _listenerAdded = false;
      }
      await Future.delayed(const Duration(milliseconds: 400));
      await _startWakeWord();
    } finally {
      _restarting = false;
    }
  }

  // ---------------- audio capture ----------------

  void _onFrame(List<int> frame) {
    double sum = 0;
    for (final s in frame) {
      sum += s * s;
    }
    final rms = math.sqrt(sum / frame.length);
    _lastRms = rms;
    _lastFrame = DateTime.now();
    if (rms < 1) {
      _zeroFrames++;
    } else {
      _zeroFrames = 0;
    }
    if (!_capturing) {
      _pre.add(frame);
      if (_pre.length > 10) _pre.removeAt(0);
      return;
    }
    _buf.addAll(frame);
    _frames++;
    // the phone silenced the microphone (zeros): grab it again
    if (_zeroFrames > 40 && !_capRecovering && !_restarting) {
      _capRecovering = true;
      _restartWake().whenComplete(() => _capRecovering = false);
    }
    // start of speech: needs a clear level; end of speech: lower level (hysteresis),
    // so quiet word endings and short pauses do not cut you off
    final startTh = math.max(400.0, _noise * 2.6);
    final keepTh = math.max(260.0, _noise * 1.7);
    if (rms > startTh) {
      _loud++;
      _silent = 0;
      if (_loud >= 3) _heardSpeech = true;
    } else if (_heardSpeech && rms > keepTh) {
      _silent = 0;
    } else {
      _loud = 0;
      _silent++;
      if (!_heardSpeech) _noise = _noise * 0.95 + rms * 0.05;
    }
    // about 1.3 seconds of real silence ends your sentence (32 ms per frame)
    if (_heardSpeech && _silent > 32) {
      _finishCapture(true);
    } else if (!_heardSpeech && _frames > _maxWait) {
      _finishCapture(false);
    } else if (_frames > 750) {
      _finishCapture(_heardSpeech);
    }
  }

  void _finishCapture(bool ok) {
    _capturing = false;
    final c = _cap;
    _cap = null;
    if (c == null || c.isCompleted) return;
    c.complete(ok && _buf.length > 8000 ? _wav(_buf) : null);
  }

  Future<Uint8List?> _recordUtterance(
      {required int waitSeconds, bool usePre = false}) {
    _buf = usePre ? [for (final f in _pre) ...f] : <int>[];
    _pre.clear();
    _loud = 0;
    _silent = 0;
    _frames = 0;
    _heardSpeech = false;
    _maxWait = (waitSeconds * 16000 / 512).round();
    final c = Completer<Uint8List?>();
    _cap = c;
    _capturing = true;
    return c.future.timeout(
      Duration(seconds: waitSeconds + 25),
      onTimeout: () {
        _capturing = false;
        return null;
      },
    );
  }

  Uint8List _wav(List<int> samples) {
    final n = samples.length;
    final out = ByteData(44 + n * 2);
    void tag(int off, String t) {
      for (var i = 0; i < 4; i++) {
        out.setUint8(off + i, t.codeUnitAt(i));
      }
    }

    tag(0, 'RIFF');
    out.setUint32(4, 36 + n * 2, Endian.little);
    tag(8, 'WAVE');
    tag(12, 'fmt ');
    out.setUint32(16, 16, Endian.little);
    out.setUint16(20, 1, Endian.little);
    out.setUint16(22, 1, Endian.little);
    out.setUint32(24, 16000, Endian.little);
    out.setUint32(28, 32000, Endian.little);
    out.setUint16(32, 2, Endian.little);
    out.setUint16(34, 16, Endian.little);
    tag(36, 'data');
    out.setUint32(40, n * 2, Endian.little);
    for (var i = 0; i < n; i++) {
      out.setInt16(44 + i * 2, samples[i], Endian.little);
    }
    return out.buffer.asUint8List();
  }

  // ---------------- call-style conversation ----------------

  Future<void> _conversation({required bool afterWake}) async {
    if (_inCall) return;
    _inCall = true;
    _loadApps();
    _lastProgress = DateTime.now();
    var first = afterWake;
    var quiet = 0;
    try {
      while (_inCall) {
        _mode('listening');
        _lastProgress = DateTime.now();

        // if you only say "Jarvis" and wait, he answers "Yes?"
        Timer? ack;
        if (first) {
          ack = Timer(const Duration(milliseconds: 1100), () async {
            if (_capturing && !_heardSpeech && _inCall) {
              _capturing = false;
              _mode('speaking');
              await _speak('Yes?');
              await Future.delayed(const Duration(milliseconds: 250));
              _pre.clear();
              _buf = <int>[];
              _loud = 0;
              _silent = 0;
              _frames = 0;
              _heardSpeech = false;
              _mode('listening');
              _lastProgress = DateTime.now();
              _capturing = true;
            }
          });
        }
        if (!first) await _beep(); // a short beep: "I am listening again"
        final audio = await _recordUtterance(
            waitSeconds: first ? 7 : 12, usePre: first);
        ack?.cancel();
        first = false;
        _lastProgress = DateTime.now();
        if (audio == null || !_inCall) {
          _endReason = 'no speech reached me (mic level ${_lastRms.round()})';
          break;
        }

        _mode('thinking');
        Reply r;
        try {
          r = await _askGemini(audio: audio);
        } catch (e) {
          r = Reply('Error: $e', error: true);
        }

        if (r.error) {
          _addMsg('model', r.say);
          _endReason = r.say;
          break;
        }
        if (r.heard.isEmpty && r.say.isEmpty && r.actions.isEmpty) {
          quiet++;
          if (quiet >= 3) {
            _endReason = 'I only heard noise three times';
            break;
          }
          continue;
        }
        quiet = 0;
        if (r.heard.isNotEmpty) _addMsg('user', r.heard);
        final done = await _handleReply(r, r.heard);
        _lastProgress = DateTime.now();
        if (done.end) {
          _endReason = 'you said goodbye';
          break;
        }
        await Future.delayed(const Duration(milliseconds: 350));
        _pre.clear();
      }
    } catch (e) {
      _endReason = 'problem: $e';
    } finally {
      _inCall = false;
      _capturing = false;
      if (_ownMic) {
        try {
          await VoiceProcessor.instance?.stop();
        } catch (_) {}
        if (_listenerAdded && _pm == null) {
          VoiceProcessor.instance?.removeFrameListener(_onFrame);
          _listenerAdded = false;
        }
        _ownMic = false;
      }
      _mode(_active ? 'idle' : 'off');
    }
  }

  Future<void> _manualCall() async {
    if (_inCall) {
      _inCall = false;
      _finishCapture(false);
      return;
    }
    final mic = await Permission.microphone.request();
    if (!mic.isGranted) {
      _toast('Microphone permission is required');
      return;
    }
    if (_key.isEmpty) {
      await _askKeys();
      return;
    }
    if (_pm == null) {
      try {
        await VoiceProcessor.instance?.start(512, 16000);
        _ownMic = true;
        _attachFrames();
      } catch (e) {
        _toast('Cannot start microphone: $e');
        return;
      }
    }
    await _conversation(afterWake: false);
  }

  // ---------------- Gemini ----------------

  String _systemPrompt() {
    final n = DateTime.now();
    const days = [
      'Monday',
      'Tuesday',
      'Wednesday',
      'Thursday',
      'Friday',
      'Saturday',
      'Sunday'
    ];
    String two(int x) => x.toString().padLeft(2, '0');
    final t = '${n.year}-${two(n.month)}-${two(n.day)} '
        '${two(n.hour)}:${two(n.minute)} (${days[n.weekday - 1]})';
    final apps = _apps.take(150).map((a) => a['name']).join(', ');
    var memLine = '';
    if (_memories.isNotEmpty) {
      memLine = 'Things the user taught you (use them when relevant):\n- ${_memories.join('\n- ')}\n';
    }
    var notifLine = '';
    final pn = _pendingNotif;
    if (pn != null) {
      notifLine =
          'PENDING NOTIFICATION: app "${pn['app']}", from "${pn['title']}", text "${pn['text']}". Direct reply possible: ${pn['canReply']}.\n'
          'If the user wants to reply, use {"type":"reply","text":"<the exact words the user dictates>"}. If a direct reply is not possible, use {"type":"open_notification"} then type and click Send. If the user refuses or ignores it, do nothing and set "end" to true.\n';
    }

    return '''
You are Jarvis, a fast, witty and polite voice assistant on the user's phone, in the style of a calm British butler.
The user talks to you by voice (audio) or text, in Arabic or English. ALWAYS answer in English, even if the user speaks Arabic.
This is a live voice call: keep "say" very short (max 2 sentences), natural, with no markdown.
Current local time: $t.
Installed apps on the phone: $apps.
$notifLine$memLine
Reply ONLY with one JSON object:
{"heard":"<what the user said, in the user's language; empty if there was no clear speech>","actions":[ ... ],"say":"<spoken reply>","end":false}
- If the audio has no clear speech, return heard "", say "", actions [], end false.
- Ignore the wake word "Jarvis" at the start of the audio.
- Set "end" to true ONLY when the user clearly dismisses you: goodbye, thanks that is all, stop, never mind, go away, leave me. Commands such as "go to settings", "go back" or "stop the music" are NOT dismissals: keep "end" false.
- Use "actions": [] when the user only wants to talk.

Action formats (use only these):
{"type":"open_app","name":"<exact app name from the installed apps list>"}
{"type":"alarm","hour":0-23,"minute":0-59,"message":"..."}  reminder at a clock time (rings like an alarm)
{"type":"timer","seconds":300,"message":"..."}  reminder after a duration
{"type":"call","number":"+212600000000"}  opens the dialer with the number
{"type":"whatsapp","number":"digits with country code","text":"..."}  opens a WhatsApp chat with the text typed in
{"type":"sms","number":"...","text":"..."}  opens a text message
{"type":"search","query":"..."}
{"type":"youtube","query":"..."}
{"type":"url","url":"https://..."}
{"type":"scroll","direction":"up|down|left|right"}  scrolls the current screen (direction "down" shows content further down the page)
{"type":"screenshot"}  takes a screenshot
{"type":"screen_record"}  starts or stops the phone screen recording
{"type":"system","action":"back|home|recents|notifications|quick_settings|lock"}
{"type":"click","text":"<visible text or label of a button on screen>"}
{"type":"type","text":"..."}  types text into the text box that is currently selected on screen
{"type":"tap_at","x":0-1000,"y":0-1000}  taps a point on the screen (0,0 is top-left, 1000,1000 is bottom-right); use it when click by text is not possible
{"type":"look"}  captures the phone screen; you then receive a screenshot plus the list of visible elements and continue the task
{"type":"settings","page":"accessibility|wifi|bluetooth|display|sound|battery|battery_optimization|apps|all_apps|location|date|language|keyboard|storage|airplane|nfc|vpn|privacy|security|about|developer|data_usage|wireless|overlay|app_details","app":"<app name, only for app_details>"}  opens that exact Android settings page directly
{"type":"web_answer","query":"<precise search query>"}  answers questions that need fresh or factual information (weather, news, scores, prices, who/what/when) using Google Search; do not guess such facts
{"type":"remember","text":"<note>"}  saves something the user teaches you (a fact, a nickname, or a routine such as: When the user says \"movie time\": open Netflix, then volume 30). Saved notes are shown to you in every later request
{"type":"forget","text":"<words of the note to delete>"}
{"type":"intent","action":"android.intent.action.VIEW","data":"geo:0,0?q=pizza","package":"","mime":"","extras":{}}  runs any Android intent (maps, navigation with google.navigation:q=PLACE, sharing with action android.intent.action.SEND, mime text/plain and extras {"android.intent.extra.TEXT":"..."}, calendar event with action android.intent.action.INSERT, data content://com.android.calendar/events and extras {"title":"...","beginTime":<epoch milliseconds>,"endTime":<epoch milliseconds>})
{"type":"reply","text":"..."}  replies directly to the pending notification (only when a notification is pending)
{"type":"open_notification"}  opens the chat of the pending notification
{"type":"volume","mode":"up|down|set|mute","level":0-100}
{"type":"media","action":"play_pause|next|previous"}
{"type":"torch","on":true}
{"type":"swipe","x1":0-1000,"y1":0-1000,"x2":0-1000,"y2":0-1000}
{"type":"long_press","x":0-1000,"y":0-1000}
The call, whatsapp and sms actions accept "name" (the contact name as the user said it) when you do not have a number.

Rules:
- To open a phone settings page, use the "settings" action: it goes to the exact page.
- If you say in "say" that you will do something, the SAME reply must contain the matching action. Never say "opening X" or "done" without the action.
- You can talk about anything: answer general questions, explain, calculate, translate, tell jokes, give advice, plan, and brainstorm directly in "say" (max 3 sentences). For anything that needs fresh facts use web_answer. If a request matches no listed action, try the closest chain of actions (open_app, look, tap, type, intent) before saying you cannot.
- When the user teaches you something ("remember that...", "from now on when I say X do Y"), use the remember action and confirm briefly.
- If a notification is pending and the user says to open the app or the chat so they can reply themselves, use only {"type":"open_notification"}.
- DICTATION: when the user dictates text to type, send or reply, copy their EXACT words from what you heard into "text". Do NOT include command words (type, write, message, say, send, tell) and do NOT rephrase, translate, correct or expand anything (keep "I'm" as "I'm"). Example: heard "type message hello I'm Jarvis I love you" gives {"type":"type","text":"hello I'm Jarvis I love you"}. Example: heard "tell Ahmed on WhatsApp I will be late" gives a whatsapp action with name "Ahmed" and text "I will be late".
- BE FAST: for commands, "say" must be 5 words or fewer (for example "Done, sir." or "Opening WhatsApp."). Chain all the needed actions in one reply.
- For tasks that need several steps on screen (menus, finding a button, forms): do one or two actions, then add {"type":"look"} as the LAST action to check the result. Repeat until the task is done, then confirm in "say" with no look action. Use at most 8 look steps.
- When the user asks what is on the screen or what to do next, use a look action first, then answer in "say".
- Never tap or type for payments, passwords, deleting data or sending money without asking the user to confirm first.
- The phone is a Xiaomi with HyperOS, so settings menus may differ from stock Android: trust the screenshot.
- For "in N minutes" reminders use a timer. For a clock time use an alarm.
- To write in another app: first open the app or chat, then use a type action, then a click action with the visible text of the send button.
- Actions run in order, so you can chain them (open_app, type, click).
- If you have neither a phone number nor a contact name, ask for it in "say" and use no action.
- In "say", briefly tell what you did. Never claim a message was sent: the user must press send.
- If the user only calls your name ("Jarvis"), reply say "Yes, sir?" with no actions.
- Never type passwords, codes or card numbers, and ask the user to confirm before payments, deleting things or sending money.
- The scroll, screenshot, screen_record, system, click and type actions need the phone accessibility permission: if the user complains they do nothing, tell them to turn on "Jarvis control" in Accessibility settings.
''';
  }

  Future<Reply> _askGemini({
    Uint8List? audio,
    Uint8List? screen,
    String? screenText,
    String? goal,
    String? log,
    String? event,
  }) async {
    var recent = _msgs.length > 10
        ? _msgs.sublist(_msgs.length - 10)
        : List<Msg>.from(_msgs);
    recent = recent.skipWhile((m) => m.role != 'user').toList();

    final contents = <Map<String, dynamic>>[
      for (final m in recent)
        {
          'role': m.role,
          'parts': [
            {'text': m.text}
          ]
        },
    ];
    if (audio != null) {
      contents.add({
        'role': 'user',
        'parts': [
          {
            'inlineData': {
              'mimeType': 'audio/wav',
              'data': base64Encode(audio),
            }
          },
          {'text': 'Respond to what I just said.'},
        ],
      });
    }
    if (event != null) {
      contents.add({
        'role': 'user',
        'parts': [
          {'text': event}
        ],
      });
    }
    if (screen != null || screenText != null) {
      final parts = <Map<String, dynamic>>[];
      if (screen != null) {
        parts.add({
          'inlineData': {'mimeType': 'image/jpeg', 'data': base64Encode(screen)}
        });
      }
      parts.add({
        'text': 'This is the phone screen right now.\nVisible elements:\n${screenText ?? ''}\nTask: ${goal ?? ''}\nActions already done: ${log ?? ''}\nContinue the task with the next action(s). If it is finished or impossible, tell the user in "say" and do NOT use a look action.'
      });
      contents.add({'role': 'user', 'parts': parts});
    }

    final res = await _http.post(
      Uri.parse(
          'https://generativelanguage.googleapis.com/v1beta/models/$model:generateContent'),
      headers: {
        'Content-Type': 'application/json',
        'x-goog-api-key': _key,
      },
      body: jsonEncode({
        'systemInstruction': {
          'parts': [
            {'text': _systemPrompt()}
          ]
        },
        'contents': contents,
        'generationConfig': {
          'responseMimeType': 'application/json',
          'temperature': 0.1,
        },
      }),
    ).timeout(const Duration(seconds: 25));

    if (res.statusCode != 200) {
      final b = res.body.length > 200 ? res.body.substring(0, 200) : res.body;
      return Reply('Error ${res.statusCode}: $b', error: true);
    }

    final data = jsonDecode(res.body);
    final parts = data['candidates'][0]['content']['parts'] as List;
    final raw = parts
        .where((p) => p['thought'] != true)
        .map((p) => (p['text'] ?? '').toString())
        .join()
        .trim();
    final clean = raw.replaceAll('```json', '').replaceAll('```', '').trim();

    try {
      final j = jsonDecode(clean);
      if (j is Map) {
        final actions = <Map<String, dynamic>>[];
        if (j['actions'] is List) {
          for (final a in (j['actions'] as List)) {
            if (a is Map) actions.add(Map<String, dynamic>.from(a));
          }
        }
        return Reply(
          (j['say'] ?? '').toString().trim(),
          heard: (j['heard'] ?? '').toString().trim(),
          actions: actions,
          end: j['end'] == true,
        );
      }
    } catch (_) {}
    return Reply(clean);
  }

  // ---------------- phone actions ----------------

  int _int(dynamic v) => v is num ? v.toInt() : int.tryParse('$v') ?? 0;

  String _norm(String s) => s.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');

  static const _aliases = <String, String>{
    'claude': 'com.anthropic.claude',
    'chatgpt': 'com.openai.chatgpt',
    'gemini': 'com.google.android.apps.bard',
    'whatsapp': 'com.whatsapp',
    'instagram': 'com.instagram.android',
    'facebook': 'com.facebook.katana',
    'messenger': 'com.facebook.orca',
    'telegram': 'org.telegram.messenger',
    'tiktok': 'com.zhiliaoapp.musically',
    'youtube': 'com.google.android.youtube',
    'spotify': 'com.spotify.music',
    'chrome': 'com.android.chrome',
    'netflix': 'com.netflix.mediaclient',
    'snapchat': 'com.snapchat.android',
    'twitter': 'com.twitter.android',
    'x': 'com.twitter.android',
    'discord': 'com.discord',
    'gmail': 'com.google.android.gm',
    'maps': 'com.google.android.apps.maps',
    'googlemaps': 'com.google.android.apps.maps',
    'playstore': 'com.android.vending',
    'settings': 'com.android.settings',
    'camera': 'com.android.camera',
  };

  static const _settingsPages = <String, String>{
    'accessibility': 'android.settings.ACCESSIBILITY_SETTINGS',
    'wifi': 'android.settings.WIFI_SETTINGS',
    'bluetooth': 'android.settings.BLUETOOTH_SETTINGS',
    'display': 'android.settings.DISPLAY_SETTINGS',
    'sound': 'android.settings.SOUND_SETTINGS',
    'battery': 'android.settings.BATTERY_SAVER_SETTINGS',
    'battery_optimization': 'android.settings.IGNORE_BATTERY_OPTIMIZATION_SETTINGS',
    'apps': 'android.settings.APPLICATION_SETTINGS',
    'all_apps': 'android.settings.MANAGE_ALL_APPLICATIONS_SETTINGS',
    'location': 'android.settings.LOCATION_SOURCE_SETTINGS',
    'date': 'android.settings.DATE_SETTINGS',
    'language': 'android.settings.LOCALE_SETTINGS',
    'keyboard': 'android.settings.INPUT_METHOD_SETTINGS',
    'storage': 'android.settings.INTERNAL_STORAGE_SETTINGS',
    'airplane': 'android.settings.AIRPLANE_MODE_SETTINGS',
    'nfc': 'android.settings.NFC_SETTINGS',
    'vpn': 'android.settings.VPN_SETTINGS',
    'privacy': 'android.settings.PRIVACY_SETTINGS',
    'security': 'android.settings.SECURITY_SETTINGS',
    'about': 'android.settings.DEVICE_INFO_SETTINGS',
    'developer': 'android.settings.APPLICATION_DEVELOPMENT_SETTINGS',
    'data_usage': 'android.settings.DATA_USAGE_SETTINGS',
    'wireless': 'android.settings.WIRELESS_SETTINGS',
    'overlay': 'android.settings.action.MANAGE_OVERLAY_PERMISSION',
  };

  Future<void> _beep() async {
    try {
      await _native.invokeMethod('beep');
    } catch (_) {}
    await Future.delayed(const Duration(milliseconds: 260));
    _pre.clear();
  }

  static const _blockedIntents = <String>[
    'DELETE', 'UNINSTALL', 'REBOOT', 'SHUTDOWN', 'FACTORY', 'MASTER_CLEAR', 'CALL_PRIVILEGED'
  ];

  // Answers questions that need fresh information, using Google Search.
  Future<String> _webAnswer(String query) async {
    try {
      final res = await _http
          .post(
            Uri.parse(
                'https://generativelanguage.googleapis.com/v1beta/models/$model:generateContent'),
            headers: {
              'Content-Type': 'application/json',
              'x-goog-api-key': _key,
            },
            body: jsonEncode({
              'systemInstruction': {
                'parts': [
                  {
                    'text':
                        'You answer voice questions for a phone assistant. Use Google Search for current facts. Reply in English in at most 3 short spoken sentences. No markdown, no lists, no links.'
                  }
                ]
              },
              'contents': [
                {
                  'role': 'user',
                  'parts': [
                    {'text': query}
                  ]
                }
              ],
              'tools': [
                {'google_search': {}}
              ],
              'generationConfig': {'temperature': 0.2},
            }),
          )
          .timeout(const Duration(seconds: 25));
      if (res.statusCode != 200) return 'I could not search the web right now.';
      final data = jsonDecode(res.body);
      final parts = data['candidates'][0]['content']['parts'] as List;
      final t = parts
          .where((p) => p['thought'] != true)
          .map((p) => (p['text'] ?? '').toString())
          .join()
          .trim();
      return t.isEmpty ? 'I found nothing useful.' : t;
    } catch (_) {
      return 'I could not search the web right now.';
    }
  }

  Future<void> _beat() async {
    try {
      await _native.invokeMethod('heartbeat');
    } catch (_) {}
  }

  Future<void> _backIfBgLaunch() async {
    try {
      final bg = await _native.invokeMethod<bool>('launchedInBackground') ?? false;
      if (bg) await _native.invokeMethod('moveToBack');
    } catch (_) {}
  }

  double _d(dynamic v, double def) => v is num ? v.toDouble() : def;

  Future<String> _numberFor(Map<String, dynamic> a) async {
    final direct = (a['number'] ?? '').toString().trim();
    if (direct.isNotEmpty) return direct;
    final name = (a['name'] ?? '').toString().trim();
    if (name.isEmpty) return '';
    try {
      if (!(await Permission.contacts.isGranted)) {
        await Permission.contacts.request();
      }
      return (await _native.invokeMethod<String>('contactNumber', {'name': name})) ?? '';
    } catch (_) {
      return '';
    }
  }

  // ---------------- notifications ----------------

  Future<dynamic> _onNative(MethodCall call) async {
    if (call.method == 'notification') {
      try {
        _onNotification(Map<String, dynamic>.from(call.arguments as Map));
      } catch (_) {}
    }
    return null;
  }

  void _onNotification(Map<String, dynamic> n) {
    if (!_notifOn || !_active || _key.isEmpty) return;
    if (_notifQueue.length < 5) _notifQueue.add(n);
    _drainNotifications();
  }

  Future<void> _drainNotifications() async {
    if (_draining) return;
    _draining = true;
    try {
      while (_notifQueue.isNotEmpty) {
        var waited = 0;
        while (_inCall && waited < 20) {
          await Future.delayed(const Duration(seconds: 2));
          waited++;
        }
        if (_inCall) {
          _notifQueue.clear();
          break;
        }
        final n = _notifQueue.removeAt(0);
        _pendingNotif = n;
        Reply r;
        try {
          r = await _askGemini(
              event:
                  'A notification just arrived. Announce it in one or two short English sentences: the app, who it is from and what it says (translate if needed). Then ask if the user wants to reply.');
        } catch (_) {
          r = Reply('', error: true);
        }
        if (r.error || r.say.isEmpty) {
          _pendingNotif = null;
          continue;
        }
        _addMsg('model', r.say);
        _mode('speaking');
        await _speak(r.say);
        await _conversation(afterWake: false);
        _pendingNotif = null;
      }
    } catch (_) {
      _pendingNotif = null;
    }
    _draining = false;
  }

  Future<void> _checkNotifAccess({bool force = false}) async {
    var on = false;
    try {
      on = await _native.invokeMethod<bool>('notifAccessEnabled') ?? false;
    } catch (_) {}
    if (on) return;
    final p = await SharedPreferences.getInstance();
    if (!force && (p.getBool('notif_asked') ?? false)) return;
    await p.setBool('notif_asked', true);
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Let Jarvis read notifications'),
        content: const Text(
            'To tell you who messages you and to reply for you, turn on "Jarvis notifications" in Notification access.\n\nIf the switch is greyed out: open App info for Jarvis, tap the three dots, choose "Allow restricted settings", then try again.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Later'),
          ),
          FilledButton(
            onPressed: () {
              Navigator.pop(ctx);
              _native.invokeMethod('openNotifSettings');
            },
            child: const Text('Open settings'),
          ),
        ],
      ),
    );
  }

  Future<void> _toggleNotif() async {
    final p = await SharedPreferences.getInstance();
    setState(() => _notifOn = !_notifOn);
    await p.setBool('notif_on', _notifOn);
    if (_notifOn) {
      await _checkNotifAccess(force: true);
    }
    _toast(_notifOn
        ? 'I will tell you about new notifications'
        : 'Notification announcements are off');
  }

  String _describeAction(Map<String, dynamic> a) {
    final extra = a['text'] ?? a['name'] ?? a['page'] ?? a['direction'] ?? a['action'] ?? '';
    return '${a['type']} $extra'.trim();
  }

  Future<Reply> _handleReply(Reply first, String goal) async {
    var r = first;
    final log = <String>[];
    var step = 0;
    while (true) {
      final wantLook = r.actions.any((a) => a['type'] == 'look');
      final hasWeb = r.actions.any((x) => x['type'] == 'web_answer');
      final text = (r.say.isEmpty && !wantLook) ? 'Done.' : r.say;
      Future<void>? speaking;
      if (text.isNotEmpty && !hasWeb) {
        _addMsg('model', text);
        if (!wantLook || step == 0) {
          _mode('speaking');
          speaking = _speak(text); // talk while the actions run: faster
        }
      }
      for (final a in r.actions) {
        if (a['type'] == 'look') continue;
        await _run(a);
        log.add(_describeAction(a));
      }
      if (speaking != null) await speaking;
      if (!wantLook || step >= 8) return r;
      step++;
      _mode('thinking');
      await Future.delayed(const Duration(milliseconds: 1000));
      Uint8List? shot;
      var tree = '';
      try {
        shot = await _native.invokeMethod<Uint8List>('screenshotJpeg');
      } catch (_) {}
      try {
        tree = (await _native.invokeMethod<String>('describeScreen')) ?? '';
      } catch (_) {}
      if (shot == null && tree.isEmpty) {
        _addMsg('model',
            'I cannot see the screen. Turn on "Jarvis control" in Accessibility settings.');
        return r;
      }
      try {
        r = await _askGemini(
            screen: shot, screenText: tree, goal: goal, log: log.join('; '));
      } catch (e) {
        r = Reply('Error: $e', error: true);
      }
      if (r.error) {
        _addMsg('model', r.say);
        return r;
      }
    }
  }

  String _clean(String s, {bool plus = false}) =>
      s.replaceAll(RegExp(plus ? r'[^0-9+]' : r'[^0-9]'), '');

  Future<void> _open(Uri uri) =>
      launchUrl(uri, mode: LaunchMode.externalApplication);

  Future<void> _a11y(String method, Map<String, dynamic> args) async {
    try {
      final r = await _native.invokeMethod(method, args);
      if (r == 'no_service') {
        _addMsg('model',
            'Turn on "Jarvis control" in Accessibility settings (tap the accessibility icon above).');
      } else if (r == false) {
        _addMsg('model', 'That did not work on this screen.');
      }
    } catch (e) {
      _addMsg('model', 'Action failed: $e');
    }
  }

  Future<void> _run(Map<String, dynamic> a) async {
    try {
      switch (a['type']) {
        case 'open_app':
          final raw = (a['name'] ?? '').toString();
          final target = _norm(raw);
          Map<String, String>? hit;
          for (final app in _apps) {
            if (_norm(app['name'] ?? '') == target) {
              hit = app;
              break;
            }
          }
          if (hit == null && target.isNotEmpty) {
            for (final app in _apps) {
              final nm = _norm(app['name'] ?? '');
              if (nm.isNotEmpty && (nm.contains(target) || target.contains(nm))) {
                hit = app;
                break;
              }
            }
          }
          if (hit == null && target.isNotEmpty) {
            for (final app in _apps) {
              if (_norm(app['package'] ?? '').contains(target)) {
                hit = app;
                break;
              }
            }
          }
          String? pkg = hit?['package'];
          pkg ??= _aliases[target];
          var opened = false;
          if (pkg != null) {
            opened = (await _native.invokeMethod<bool>(
                    'launchApp', {'package': pkg, 'name': hit?['name'] ?? raw})) ??
                false;
            if (opened) _lastLaunchPkg = pkg;
          }
          if (!opened) {
            _addMsg('model',
                'I could not open "$raw". Apps I can see: ${_apps.length}. If it is installed, Android may be blocking it from the background: allow "Display pop-up windows while running in the background" for Jarvis, and turn on Jarvis control in Accessibility.');
          }
          break;
        case 'settings':
          final page = (a['page'] ?? '').toString().toLowerCase();
          if (page == 'app_details') {
            final t2 = _norm((a['app'] ?? '').toString());
            String? p2;
            for (final app in _apps) {
              final nm = _norm(app['name'] ?? '');
              if (nm == t2 || (t2.isNotEmpty && nm.contains(t2))) {
                p2 = app['package'];
                break;
              }
            }
            p2 ??= _aliases[t2];
            if (p2 != null) {
              await AndroidIntent(
                action: 'android.settings.APPLICATION_DETAILS_SETTINGS',
                data: 'package:$p2',
              ).launch();
            } else {
              _addMsg('model', 'I could not find that app to open its settings.');
            }
          } else {
            final act = _settingsPages[page] ?? 'android.settings.SETTINGS';
            await AndroidIntent(action: act).launch();
          }
          break;
        case 'tap_at':
          await _a11y('tapAt', {
            'x': (a['x'] is num ? (a['x'] as num).toDouble() : 500.0),
            'y': (a['y'] is num ? (a['y'] as num).toDouble() : 500.0),
          });
          break;
        case 'look':
          break;
        case 'alarm':
          await AndroidIntent(
            action: 'android.intent.action.SET_ALARM',
            arguments: <String, dynamic>{
              'android.intent.extra.alarm.HOUR': _int(a['hour']),
              'android.intent.extra.alarm.MINUTES': _int(a['minute']),
              'android.intent.extra.alarm.MESSAGE':
                  (a['message'] ?? 'Jarvis reminder').toString(),
              'android.intent.extra.alarm.SKIP_UI': true,
            },
          ).launch();
          break;
        case 'timer':
          await AndroidIntent(
            action: 'android.intent.action.SET_TIMER',
            arguments: <String, dynamic>{
              'android.intent.extra.alarm.LENGTH': _int(a['seconds']),
              'android.intent.extra.alarm.MESSAGE':
                  (a['message'] ?? 'Jarvis reminder').toString(),
              'android.intent.extra.alarm.SKIP_UI': true,
            },
          ).launch();
          break;
        case 'call':
          final callNum = await _numberFor(a);
          if (callNum.isEmpty) {
            _addMsg('model', 'I could not find that phone number.');
          } else {
            await AndroidIntent(
              action: 'android.intent.action.DIAL',
              data: 'tel:${_clean(callNum, plus: true)}',
            ).launch();
          }
          break;
        case 'whatsapp':
          final waRaw = await _numberFor(a);
          if (waRaw.isEmpty) {
            _addMsg('model', 'I could not find that phone number.');
          } else {
            final waNumber = _clean(waRaw);
            final waText = Uri.encodeComponent((a['text'] ?? '').toString());
            await _open(Uri.parse('https://wa.me/$waNumber?text=$waText'));
          }
          break;
        case 'sms':
          final smsRaw = await _numberFor(a);
          if (smsRaw.isEmpty) {
            _addMsg('model', 'I could not find that phone number.');
          } else {
            final smsNumber = _clean(smsRaw, plus: true);
            final smsBody = Uri.encodeComponent((a['text'] ?? '').toString());
            await _open(Uri.parse('sms:$smsNumber?body=$smsBody'));
          }
          break;
        case 'reply':
          final nk = (_pendingNotif?['key'] ?? '').toString();
          var replied = false;
          if (nk.isNotEmpty) {
            replied = (await _native.invokeMethod<bool>('replyNotification',
                    {'key': nk, 'text': (a['text'] ?? '').toString()})) ??
                false;
          }
          if (!replied) {
            _addMsg('model',
                'I could not reply directly from the notification. I can open the chat and type it instead.');
          }
          break;
        case 'open_notification':
          final nkey = (_pendingNotif?['key'] ?? '').toString();
          final npkg = (_pendingNotif?['package'] ?? '').toString();
          final nname = (_pendingNotif?['app'] ?? '').toString();
          var nOpened = false;
          if (nkey.isNotEmpty) {
            nOpened = (await _native
                    .invokeMethod<bool>('openNotification', {'key': nkey})) ??
                false;
          }
          var inFront = false;
          if (nOpened && npkg.isNotEmpty) {
            inFront = (await _native.invokeMethod<bool>(
                    'waitForApp', {'package': npkg, 'timeoutMs': 2500})) ??
                false;
          }
          if (!inFront && npkg.isNotEmpty) {
            // the chat did not open: open the app itself
            await _native.invokeMethod<bool>(
                'launchApp', {'package': npkg, 'name': nname});
          }
          break;
        case 'web_answer':
          final ans = await _webAnswer((a['query'] ?? '').toString());
          _addMsg('model', ans);
          _mode('speaking');
          await _speak(ans);
          break;
        case 'remember':
          final note = (a['text'] ?? '').toString().trim();
          if (note.isNotEmpty) {
            _memories.add(note);
            if (_memories.length > 40) _memories.removeAt(0);
            final pr1 = await SharedPreferences.getInstance();
            await pr1.setStringList('memories', _memories);
          }
          break;
        case 'forget':
          final fq = _norm((a['text'] ?? '').toString());
          if (fq.isNotEmpty) {
            _memories.removeWhere((m) => _norm(m).contains(fq));
            final pr2 = await SharedPreferences.getInstance();
            await pr2.setStringList('memories', _memories);
          }
          break;
        case 'intent':
          final intentAction = (a['action'] ?? '').toString();
          final allowed = (intentAction.startsWith('android.intent.action.') ||
                  intentAction.startsWith('android.settings.') ||
                  intentAction.startsWith('android.media.action.')) &&
              !_blockedIntents.any((b) => intentAction.contains(b));
          if (!allowed) {
            _addMsg('model', 'I will not run that action.');
            break;
          }
          final dataStr = (a['data'] ?? '').toString();
          final pkgStr = (a['package'] ?? '').toString();
          final mimeStr = (a['mime'] ?? '').toString();
          final extras = a['extras'];
          await AndroidIntent(
            action: intentAction,
            data: dataStr.isEmpty ? null : dataStr,
            package: pkgStr.isEmpty ? null : pkgStr,
            type: mimeStr.isEmpty ? null : mimeStr,
            arguments: extras is Map ? Map<String, dynamic>.from(extras) : null,
          ).launch();
          break;
        case 'volume':
          await _native.invokeMethod('volume', {
            'mode': (a['mode'] ?? 'up').toString(),
            'level': _int(a['level']),
          });
          break;
        case 'media':
          await _native.invokeMethod(
              'media', {'action': (a['action'] ?? 'play_pause').toString()});
          break;
        case 'torch':
          await _native.invokeMethod('torch', {'on': a['on'] != false});
          break;
        case 'swipe':
          await _a11y('swipeAt', {
            'x1': _d(a['x1'], 500),
            'y1': _d(a['y1'], 700),
            'x2': _d(a['x2'], 500),
            'y2': _d(a['y2'], 300),
          });
          break;
        case 'long_press':
          await _a11y('longPressAt', {'x': _d(a['x'], 500), 'y': _d(a['y'], 500)});
          break;
        case 'scroll':
          await _a11y('scroll', {'direction': (a['direction'] ?? 'down').toString()});
          break;
        case 'screenshot':
          await _a11y('global', {'action': 'screenshot'});
          break;
        case 'screen_record':
          await _a11y('screenRecord', {});
          break;
        case 'system':
          await _a11y('global', {'action': (a['action'] ?? '').toString()});
          break;
        case 'click':
          await _a11y('clickText', {'text': (a['text'] ?? '').toString()});
          break;
        case 'type':
          await _a11y('typeText', {'text': (a['text'] ?? '').toString()});
          break;
        case 'search':
          await _open(Uri.https('www.google.com', '/search',
              {'q': (a['query'] ?? '').toString()}));
          break;
        case 'youtube':
          await _open(Uri.https('www.youtube.com', '/results',
              {'search_query': (a['query'] ?? '').toString()}));
          break;
        case 'url':
          await _open(Uri.parse((a['url'] ?? '').toString()));
          break;
      }
      // give a newly opened app time to appear before the next action (type, click...)
      const launches = <String>{'open_app', 'whatsapp', 'sms', 'search', 'youtube', 'url', 'call'};
      if (a['type'] == 'open_app' && _lastLaunchPkg != null) {
        final wp = _lastLaunchPkg;
        _lastLaunchPkg = null;
        try {
          await _native.invokeMethod<bool>(
              'waitForApp', {'package': wp, 'timeoutMs': 3500});
        } catch (_) {
          await Future.delayed(const Duration(milliseconds: 1200));
        }
      } else if (launches.contains(a['type'])) {
        await Future.delayed(const Duration(milliseconds: 1200));
      }
    } catch (e) {
      _addMsg('model', 'Action failed: $e');
    }
  }

  // ---------------- text chat ----------------

  Future<void> _send(String text) async {
    text = text.trim();
    if (text.isEmpty || _busy || _inCall) return;
    if (_key.isEmpty) {
      await _askKeys();
      return;
    }
    setState(() {
      _msgs.add(Msg('user', text));
      _busy = true;
      _input.clear();
    });
    _scrollDown();

    Reply r;
    try {
      r = await _askGemini();
    } catch (e) {
      r = Reply('Error: $e', error: true);
    }
    if (!mounted) return;
    if (r.error) {
      setState(() {
        _msgs.add(Msg('model', r.say));
        _busy = false;
      });
      _scrollDown();
      return;
    }
    await _handleReply(r, text);
    if (mounted) setState(() => _busy = false);
  }

  // ---------------- UI ----------------

  String _statusText() {
    final base = _statusBase();
    if (_state == 'idle' && _endReason.isNotEmpty) {
      return '$base\nLast call ended: $_endReason';
    }
    return base;
  }

  String _statusBase() {
    switch (_state) {
      case 'idle':
        if (_pm != null && _zeroFrames > 30) {
          return 'Another app is using the microphone (voice message, call...). I will hear you again when it stops.';
        }
        return _pm != null
            ? 'Say "Jarvis"...   (mic ${_lastRms.round()}, apps ${_apps.length})'
            : 'Wake word is OFF${_wakeError.isEmpty ? '' : ': $_wakeError'}. You can still tap the call button to talk.';
      case 'listening':
        return 'Listening...';
      case 'thinking':
        return 'Thinking...';
      case 'speaking':
        return 'Speaking...';
      default:
        return 'Jarvis is off. Tap the power button.';
    }
  }

  Color _statusColor() {
    switch (_state) {
      case 'listening':
        return Colors.greenAccent;
      case 'thinking':
        return Colors.orangeAccent;
      case 'speaking':
        return Colors.purpleAccent;
      case 'idle':
        return Colors.cyan;
      default:
        return Colors.grey;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Jarvis'),
        actions: [
          IconButton(
            icon: const Icon(Icons.power_settings_new),
            color: _active ? Colors.cyan : Colors.grey,
            onPressed: _active ? _deactivate : _activate,
          ),
          IconButton(
            icon: const Icon(Icons.accessibility_new),
            onPressed: () async {
              try {
                await _native.invokeMethod('openA11ySettings');
              } catch (_) {}
            },
          ),
          IconButton(
            icon: Icon(_notifOn
                ? Icons.notifications_active
                : Icons.notifications_off),
            color: _notifOn ? Colors.cyan : Colors.grey,
            onPressed: _toggleNotif,
          ),
          IconButton(
            icon: const Icon(Icons.record_voice_over),
            onPressed: _pickVoice,
          ),
          IconButton(icon: const Icon(Icons.key), onPressed: _askKeys),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 16),
              color: _statusColor().withOpacity(0.15),
              child: Text(
                _statusText(),
                style: TextStyle(color: _statusColor()),
              ),
            ),
            Expanded(
              child: ListView.builder(
                controller: _scroll,
                padding: const EdgeInsets.all(12),
                itemCount: _msgs.length,
                itemBuilder: (_, i) {
                  final m = _msgs[i];
                  final me = m.role == 'user';
                  return Align(
                    alignment:
                        me ? Alignment.centerRight : Alignment.centerLeft,
                    child: Container(
                      margin: const EdgeInsets.symmetric(vertical: 4),
                      padding: const EdgeInsets.all(12),
                      constraints: BoxConstraints(
                          maxWidth: MediaQuery.of(context).size.width * 0.8),
                      decoration: BoxDecoration(
                        color: me
                            ? Colors.cyan.withOpacity(0.25)
                            : Colors.white10,
                        borderRadius: BorderRadius.circular(14),
                      ),
                      child: Text(m.text),
                    ),
                  );
                },
              ),
            ),
            if (_busy) const LinearProgressIndicator(),
            Padding(
              padding: const EdgeInsets.all(8),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _input,
                      onSubmitted: _send,
                      decoration: InputDecoration(
                        hintText: 'Type a message',
                        border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(24)),
                        contentPadding: const EdgeInsets.symmetric(
                            horizontal: 16, vertical: 10),
                      ),
                    ),
                  ),
                  IconButton(
                    icon: Icon(_inCall ? Icons.call_end : Icons.call),
                    color: _inCall ? Colors.redAccent : Colors.cyan,
                    iconSize: 30,
                    onPressed: _manualCall,
                  ),
                  IconButton(
                    icon: const Icon(Icons.send),
                    onPressed: () => _send(_input.text),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
