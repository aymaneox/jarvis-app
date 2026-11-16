import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:speech_to_text/speech_to_text.dart';

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

class ChatPage extends StatefulWidget {
  const ChatPage({super.key});

  @override
  State<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends State<ChatPage> {
  static const model = 'gemini-2.5-flash-lite';
  static const systemPrompt =
      "You are Jarvis, a fast, witty voice assistant on the user's phone. "
      "The user may speak Arabic or English. Always reply in English, "
      "in at most 2 short sentences, with no markdown or lists.";

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
    _tts.setLanguage('en-US');
    _loadKey();
  }

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

  Future<String> _askGemini() async {
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
            {'text': systemPrompt}
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
      }),
    );

    if (res.statusCode != 200) {
      final b = res.body.length > 200 ? res.body.substring(0, 200) : res.body;
      return 'Error ${res.statusCode}: $b';
    }
    final data = jsonDecode(res.body);
    return (data['candidates'][0]['content']['parts'][0]['text'] as String)
        .trim();
  }

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

    String reply;
    try {
      reply = await _askGemini();
    } catch (e) {
      reply = 'Error: $e';
    }
    if (!mounted) return;
    setState(() {
      _msgs.add(Msg('model', reply));
      _busy = false;
    });
    _scrollDown();
    if (!reply.startsWith('Error')) {
      await _tts.speak(reply);
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
          const SnackBar(content: Text('Microphone or speech service unavailable')),
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
