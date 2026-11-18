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
  bool _restarting = false;

  @override
  void initState() {
    super.initState();
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
      await _tts.awaitSpeakCompletion(true);
      await _tts.setLanguage('en-GB');
      await _tts.setPitch(0.7);
      await _tts.setSpeechRate(0.45);
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
    });
    if (_key.isEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _askKeys());
    } else if (p.getBool('active') ?? false) {
      _activate();
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
    if (_pvKey.isEmpty) {
      _toast('Add your Picovoice key (key icon) to enable the "Jarvis" wake word');
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
      _attachFrames();
    } on PorcupineException catch (e) {
      _toast('Wake word failed: ${e.message}');
    } catch (e) {
      _toast('Wake word failed: $e');
    }
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
    if (_heardSpeech && _silent > 40) {
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
        final audio = await _recordUtterance(
            waitSeconds: first ? 7 : 9, usePre: first);
        ack?.cancel();
        first = false;
        _lastProgress = DateTime.now();
        if (audio == null || !_inCall) break;

        _mode('thinking');
        Reply r;
        try {
          r = await _askGemini(audio: audio);
        } catch (e) {
          r = Reply('Error: $e', error: true);
        }

        if (r.error) {
          _addMsg('model', r.say);
          break;
        }
        if (r.heard.isEmpty && r.say.isEmpty && r.actions.isEmpty) {
          quiet++;
          if (quiet >= 2) break;
          continue;
        }
        quiet = 0;
        if (r.heard.isNotEmpty) _addMsg('user', r.heard);
        if (r.say.isNotEmpty) _addMsg('model', r.say);
        for (final a in r.actions) {
          await _run(a);
        }
        if (r.say.isNotEmpty) {
          _mode('speaking');
          await _speak(r.say);
        }
        _lastProgress = DateTime.now();
        if (r.end) break;
        await Future.delayed(const Duration(milliseconds: 250));
        _pre.clear();
      }
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

    return '''
You are Jarvis, a fast, witty and polite voice assistant on the user's phone, in the style of a calm British butler.
The user talks to you by voice (audio) or text, in Arabic or English. ALWAYS answer in English, even if the user speaks Arabic.
This is a live voice call: keep "say" very short (max 2 sentences), natural, with no markdown.
Current local time: $t.
Installed apps on the phone: $apps.

Reply ONLY with one JSON object:
{"heard":"<what the user said, in the user's language; empty if there was no clear speech>","say":"<spoken reply>","actions":[ ... ],"end":false}
- If the audio has no clear speech, return heard "", say "", actions [], end false.
- Ignore the wake word "Jarvis" at the start of the audio.
- Set "end" to true when the user says goodbye, thanks, stop, that is all, never mind, go away, leave me, or clearly finished the conversation. Say a very short farewell in "say".
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

Rules:
- For "in N minutes" reminders use a timer. For a clock time use an alarm.
- To write in another app: first open the app or chat, then use a type action, then a click action with the visible text of the send button.
- Actions run in order, so you can chain them (open_app, type, click).
- If a phone number is missing, ask for it in "say" and use no action.
- In "say", briefly tell what you did. Never claim a message was sent: the user must press send.
- If the user only calls your name ("Jarvis"), reply say "Yes, sir?" with no actions.
- Never type passwords, codes or card numbers, and ask the user to confirm before payments, deleting things or sending money.
- The scroll, screenshot, screen_record, system, click and type actions need the phone accessibility permission: if the user complains they do nothing, tell them to turn on "Jarvis control" in Accessibility settings.
''';
  }

  Future<Reply> _askGemini({Uint8List? audio}) async {
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

    final res = await http.post(
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
          'temperature': 0.3,
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
          final target = (a['name'] ?? '').toString().toLowerCase().trim();
          Map<String, String>? hit;
          for (final app in _apps) {
            if ((app['name'] ?? '').toLowerCase() == target) {
              hit = app;
              break;
            }
          }
          if (hit == null && target.isNotEmpty) {
            for (final app in _apps) {
              final nm = (app['name'] ?? '').toLowerCase();
              if (nm.contains(target) || target.contains(nm)) {
                hit = app;
                break;
              }
            }
          }
          if (hit != null) {
            await _native.invokeMethod('launchApp', {'package': hit['package']});
          } else {
            _addMsg('model', 'App not found: $target');
          }
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
          await AndroidIntent(
            action: 'android.intent.action.DIAL',
            data: 'tel:${_clean((a['number'] ?? '').toString(), plus: true)}',
          ).launch();
          break;
        case 'whatsapp':
          final waNumber = _clean((a['number'] ?? '').toString());
          final waText = Uri.encodeComponent((a['text'] ?? '').toString());
          await _open(Uri.parse('https://wa.me/$waNumber?text=$waText'));
          break;
        case 'sms':
          final smsNumber = _clean((a['number'] ?? '').toString(), plus: true);
          final smsBody = Uri.encodeComponent((a['text'] ?? '').toString());
          await _open(Uri.parse('sms:$smsNumber?body=$smsBody'));
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
      if (launches.contains(a['type'])) {
        await Future.delayed(const Duration(milliseconds: 1500));
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
    setState(() {
      _msgs.add(Msg('model', r.say.isEmpty ? 'Done.' : r.say));
      _busy = false;
    });
    _scrollDown();
    if (!r.error) {
      for (final a in r.actions) {
        await _run(a);
      }
      await _speak(r.say);
    }
  }

  // ---------------- UI ----------------

  String _statusText() {
    switch (_state) {
      case 'idle':
        if (_pm != null && _zeroFrames > 30) {
          return 'Another app is using the microphone (voice message, call...). I will hear you again when it stops.';
        }
        return _pm != null
            ? 'Say "Jarvis"...   (mic ${_lastRms.round()})'
            : 'Wake word is off. Tap the call button to talk.';
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
