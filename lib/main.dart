import 'dart:convert';

import 'package:android_intent_plus/android_intent.dart';
import 'package:flutter/material.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:speech_to_text/speech_to_text.dart';
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
  final String say;
  final List<Map<String, dynamic>> actions;
  final bool error;
  Reply(this.say, {this.actions = const [], this.error = false});
}

class ChatPage extends StatefulWidget {
  const ChatPage({super.key});

  @override
  State<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends State<ChatPage> {
  static const model = 'gemini-3.5-flash-lite';

  static const appPackages = <String, String>{
    'whatsapp': 'com.whatsapp',
    'youtube': 'com.google.android.youtube',
    'chrome': 'com.android.chrome',
    'gmail': 'com.google.android.gm',
    'maps': 'com.google.android.apps.maps',
    'instagram': 'com.instagram.android',
    'facebook': 'com.facebook.katana',
    'telegram': 'org.telegram.messenger',
    'spotify': 'com.spotify.music',
    'tiktok': 'com.zhiliaoapp.musically',
  };

  final _msgs = <Msg>[];
  final _input = TextEditingController();
  final _scroll = ScrollController();
  final _stt = SpeechToText();
  final _tts = FlutterTts();

  String _key = '';
  String _locale = 'en_US';
  bool _listening = false;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _setupVoice();
    _loadKey();
  }

  // ---------- Voice (British butler style) ----------

  Future<void> _setupVoice() async {
    try {
      await _tts.setLanguage('en-GB');
      await _tts.setPitch(0.7);
      await _tts.setSpeechRate(0.42);
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

  // ---------- API key ----------

  Future<void> _loadKey() async {
    final p = await SharedPreferences.getInstance();
    final k = p.getString('gemini_key') ?? '';
    setState(() => _key = k);
    if (k.isEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _askKey());
    }
  }

  Future<void> _askKey() async {
    final c = TextEditingController(text: _key);
    final v = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Gemini API key'),
        content: TextField(
          controller: c,
          obscureText: true,
          decoration: const InputDecoration(hintText: 'AIza...'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, c.text.trim()),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (v != null && v.isNotEmpty) {
      final p = await SharedPreferences.getInstance();
      await p.setString('gemini_key', v);
      setState(() => _key = v);
    }
  }

  // ---------- Gemini ----------

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

    return '''
You are Jarvis, a fast, witty and polite voice assistant on the user's phone, in the style of a calm British butler.
The user speaks Arabic or English. ALWAYS answer in English.
Current local time: $t.

Reply ONLY with one JSON object: {"say": "<1-2 short sentences to speak>", "actions": [ ... ]}
Use "actions": [] when the user only wants to talk.

Action formats (use only these):
{"type":"alarm","hour":0-23,"minute":0-59,"message":"..."}  reminder at a clock time (rings like an alarm)
{"type":"timer","seconds":300,"message":"..."}  reminder after a duration
{"type":"call","number":"+212600000000"}  opens the dialer with the number
{"type":"whatsapp","number":"digits with country code","text":"..."}  opens a WhatsApp chat with the text typed in
{"type":"sms","number":"...","text":"..."}  opens a text message
{"type":"open_app","name":"whatsapp|youtube|chrome|gmail|maps|instagram|facebook|telegram|spotify|tiktok|camera|settings"}
{"type":"search","query":"..."}
{"type":"youtube","query":"..."}
{"type":"url","url":"https://..."}

Rules:
- For "in N minutes" reminders use a timer. For a clock time use an alarm.
- If a phone number is missing, ask for it in "say" and use no action.
- In "say", briefly tell what you did. Never claim a message was sent: the user must press send.
''';
  }

  Future<Reply> _askGemini() async {
    var recent = _msgs.length > 12
        ? _msgs.sublist(_msgs.length - 12)
        : List<Msg>.from(_msgs);
    recent = recent.skipWhile((m) => m.role != 'user').toList();

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
        'contents': [
          for (final m in recent)
            {
              'role': m.role,
              'parts': [
                {'text': m.text}
              ]
            }
        ],
        'generationConfig': {
          'responseMimeType': 'application/json',
          'temperature': 0.3,
        },
      }),
    );

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
        final say = (j['say'] ?? '').toString().trim();
        final actions = <Map<String, dynamic>>[];
        if (j['actions'] is List) {
          for (final a in (j['actions'] as List)) {
            if (a is Map) actions.add(Map<String, dynamic>.from(a));
          }
        }
        return Reply(say.isEmpty ? 'Done.' : say, actions: actions);
      }
    } catch (_) {}
    return Reply(clean.isEmpty ? 'Sorry, say that again.' : clean);
  }

  // ---------- Phone actions ----------

  int _int(dynamic v) => v is num ? v.toInt() : int.tryParse('$v') ?? 0;

  String _clean(String s, {bool plus = false}) =>
      s.replaceAll(RegExp(plus ? r'[^0-9+]' : r'[^0-9]'), '');

  Future<void> _open(Uri uri) =>
      launchUrl(uri, mode: LaunchMode.externalApplication);

  Future<void> _run(Map<String, dynamic> a) async {
    try {
      switch (a['type']) {
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
        case 'open_app':
          final appName = (a['name'] ?? '').toString().toLowerCase();
          if (appName == 'camera') {
            await AndroidIntent(action: 'android.media.action.STILL_IMAGE_CAMERA')
                .launch();
          } else if (appName == 'settings') {
            await AndroidIntent(action: 'android.settings.SETTINGS').launch();
          } else if (appPackages.containsKey(appName)) {
            await AndroidIntent(
              action: 'android.intent.action.MAIN',
              category: 'android.intent.category.LAUNCHER',
              package: appPackages[appName],
            ).launch();
          }
          break;
        case 'search':
          await _open(Uri.https(
              'www.google.com', '/search', {'q': (a['query'] ?? '').toString()}));
          break;
        case 'youtube':
          await _open(Uri.https('www.youtube.com', '/results',
              {'search_query': (a['query'] ?? '').toString()}));
          break;
        case 'url':
          await _open(Uri.parse((a['url'] ?? '').toString()));
          break;
      }
    } catch (e) {
      if (mounted) {
        setState(() => _msgs.add(Msg('model', 'Action failed: $e')));
      }
    }
  }

  // ---------- Chat flow ----------

  Future<void> _send(String text) async {
    text = text.trim();
    if (text.isEmpty || _busy) return;
    if (_key.isEmpty) {
      await _askKey();
      return;
    }
    setState(() {
      _msgs.add(Msg('user', text));
      _busy = true;
      _input.clear();
    });
    _scrollDown();

    Reply reply;
    try {
      reply = await _askGemini();
    } catch (e) {
      reply = Reply('Error: $e', error: true);
    }
    if (!mounted) return;
    setState(() {
      _msgs.add(Msg('model', reply.say));
      _busy = false;
    });
    _scrollDown();

    if (!reply.error) {
      for (final a in reply.actions) {
        await _run(a);
      }
      await _tts.speak(reply.say);
    }
  }

  Future<void> _listen() async {
    if (_listening) {
      await _stt.stop();
      setState(() => _listening = false);
      return;
    }
    final ok = await _stt.initialize(
      onError: (e) {
        if (mounted) setState(() => _listening = false);
      },
      onStatus: (s) {
        if ((s == 'done' || s == 'notListening') && mounted) {
          setState(() => _listening = false);
        }
      },
    );
    if (!ok) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content: Text('Microphone or speech service unavailable')),
        );
      }
      return;
    }
    setState(() => _listening = true);
    await _stt.listen(
      localeId: _locale,
      listenFor: const Duration(seconds: 20),
      pauseFor: const Duration(seconds: 3),
      onResult: (r) {
        if (r.finalResult) {
          setState(() => _listening = false);
          _send(r.recognizedWords);
        }
      },
    );
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

  // ---------- UI ----------

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Jarvis'),
        actions: [
          TextButton(
            onPressed: () => setState(
                () => _locale = _locale == 'en_US' ? 'ar_SA' : 'en_US'),
            child: Text(_locale == 'en_US' ? 'EN' : 'AR'),
          ),
          IconButton(icon: const Icon(Icons.key), onPressed: _askKey),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
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
                        hintText: 'Type or tap the mic',
                        border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(24)),
                        contentPadding: const EdgeInsets.symmetric(
                            horizontal: 16, vertical: 10),
                      ),
                    ),
                  ),
                  IconButton(
                    icon: Icon(_listening ? Icons.stop_circle : Icons.mic),
                    color: _listening ? Colors.redAccent : Colors.cyan,
                    iconSize: 32,
                    onPressed: _listen,
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
