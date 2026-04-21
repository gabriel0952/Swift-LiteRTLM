import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import '../services/litert_service.dart';

enum _EngineState { notLoaded, loading, ready, failed }

class ChatMessage {
  final String role; // 'user' | 'model'
  final StringBuffer buffer;
  final Uint8List? imageBytes;
  bool isStreaming;

  ChatMessage({
    required this.role,
    String text = '',
    this.imageBytes,
    this.isStreaming = false,
  }) : buffer = StringBuffer(text);

  String get text => buffer.toString();
}

class ChatScreen extends StatefulWidget {
  const ChatScreen({super.key});

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final _service = LiteRTService();
  final _textCtrl = TextEditingController();
  final _scrollCtrl = ScrollController();
  final _imagePicker = ImagePicker();

  _EngineState _engineState = _EngineState.notLoaded;
  String _engineError = '';
  bool _hasConversation = false;
  bool _isGenerating = false;
  bool _useStreaming = true;
  String _backend = 'gpu';
  Uint8List? _pendingImage;

  final List<ChatMessage> _messages = [];
  StreamSubscription<String>? _streamSub;

  @override
  void initState() {
    super.initState();
    _loadRecommendedBackend();
  }

  @override
  void dispose() {
    _textCtrl.dispose();
    _scrollCtrl.dispose();
    _streamSub?.cancel();
    super.dispose();
  }

  Future<void> _loadRecommendedBackend() async {
    try {
      final backend = await _service.getRecommendedBackend();
      if (!mounted) return;
      setState(() => _backend = backend);
    } catch (_) {}
  }

  // MARK: - Engine

  Future<void> _initEngine() async {
    setState(() {
      _engineState = _EngineState.loading;
      _engineError = '';
    });
    try {
      await _service.initEngine(backend: _backend);
      setState(() => _engineState = _EngineState.ready);
    } catch (e) {
      setState(() {
        _engineState = _EngineState.failed;
        _engineError = e.toString();
      });
    }
  }

  Future<void> _closeEngine() async {
    setState(() {
      _engineState = _EngineState.notLoaded;
      _hasConversation = false;
      _messages.clear();
    });
    try {
      await _service.closeEngine();
    } catch (_) {}
  }

  Future<void> _newConversation() async {
    setState(() {
      _hasConversation = false;
      _messages.clear();
    });
    try {
      await _service.newConversation();
      setState(() => _hasConversation = true);
    } catch (e) {
      _showError(e.toString());
    }
  }

  // MARK: - Image Picker

  Future<void> _pickImage(ImageSource source) async {
    try {
      final picked = await _imagePicker.pickImage(
        source: source,
        maxWidth: 1024,
        maxHeight: 1024,
        imageQuality: 85,
      );
      if (picked != null && mounted) {
        final bytes = await picked.readAsBytes();
        setState(() => _pendingImage = bytes);
      }
    } catch (e) {
      _showError(e.toString());
    }
  }

  void _showImageSourceSheet() {
    showModalBottomSheet<void>(
      context: context,
      builder: (_) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.photo_library_outlined),
              title: const Text('Photo Library'),
              onTap: () {
                Navigator.pop(context);
                _pickImage(ImageSource.gallery);
              },
            ),
            ListTile(
              leading: const Icon(Icons.camera_alt_outlined),
              title: const Text('Camera'),
              onTap: () {
                Navigator.pop(context);
                _pickImage(ImageSource.camera);
              },
            ),
          ],
        ),
      ),
    );
  }

  // MARK: - Messaging

  Future<void> _send() async {
    final text = _textCtrl.text.trim();
    final image = _pendingImage;
    if ((text.isEmpty && image == null) || _isGenerating || !_hasConversation) return;

    _textCtrl.clear();
    setState(() {
      _messages.add(ChatMessage(role: 'user', text: text, imageBytes: image));
      _pendingImage = null;
      _isGenerating = true;
    });
    _scrollToBottom();

    if (image != null) {
      if (_useStreaming) {
        await _sendImageStream(image, text);
      } else {
        await _sendImageBlocking(image, text);
      }
    } else {
      if (_useStreaming) {
        await _sendStream(text);
      } else {
        await _sendBlocking(text);
      }
    }
  }

  Future<void> _sendBlocking(String text) async {
    final placeholder = ChatMessage(role: 'model', text: '…');
    setState(() => _messages.add(placeholder));
    try {
      final reply = await _service.sendMessage(text);
      setState(() {
        _messages.last.buffer.clear();
        _messages.last.buffer.write(reply);
      });
    } catch (e) {
      setState(() {
        _messages.last.buffer.clear();
        _messages.last.buffer.write('[Error] ${e.toString()}');
      });
    } finally {
      setState(() => _isGenerating = false);
      _scrollToBottom();
    }
  }

  Future<void> _sendImageBlocking(Uint8List imageBytes, String text) async {
    final placeholder = ChatMessage(role: 'model', text: '…');
    setState(() => _messages.add(placeholder));
    try {
      final reply = await _service.sendImageMessage(imageBytes, text);
      setState(() {
        _messages.last.buffer.clear();
        _messages.last.buffer.write(reply);
      });
    } catch (e) {
      setState(() {
        _messages.last.buffer.clear();
        _messages.last.buffer.write('[Error] ${e.toString()}');
      });
    } finally {
      setState(() => _isGenerating = false);
      _scrollToBottom();
    }
  }

  Future<void> _sendStream(String text) async {
    final modelMsg = ChatMessage(role: 'model', isStreaming: true);
    setState(() => _messages.add(modelMsg));

    await _streamSub?.cancel();
    _streamSub = _service.streamTokens().listen(
      (token) {
        if (!mounted) return;
        setState(() => modelMsg.buffer.write(token));
        _scrollToBottom();
      },
      onDone: () {
        if (mounted) {
          setState(() {
            modelMsg.isStreaming = false;
            _isGenerating = false;
          });
        }
      },
      onError: (e) {
        if (mounted) {
          setState(() {
            modelMsg.buffer.write('\n[Error] $e');
            modelMsg.isStreaming = false;
            _isGenerating = false;
          });
        }
      },
    );

    try {
      await _service.sendMessageStream(text);
    } catch (e) {
      await _streamSub?.cancel();
      _streamSub = null;
      if (mounted) {
        setState(() {
          modelMsg.buffer.write('[Error] $e');
          modelMsg.isStreaming = false;
          _isGenerating = false;
        });
      }
    }
  }

  Future<void> _sendImageStream(Uint8List imageBytes, String text) async {
    final modelMsg = ChatMessage(role: 'model', isStreaming: true);
    setState(() => _messages.add(modelMsg));

    await _streamSub?.cancel();
    _streamSub = _service.streamTokens().listen(
      (token) {
        if (!mounted) return;
        setState(() => modelMsg.buffer.write(token));
        _scrollToBottom();
      },
      onDone: () {
        if (mounted) {
          setState(() {
            modelMsg.isStreaming = false;
            _isGenerating = false;
          });
        }
      },
      onError: (e) {
        if (mounted) {
          setState(() {
            modelMsg.buffer.write('\n[Error] $e');
            modelMsg.isStreaming = false;
            _isGenerating = false;
          });
        }
      },
    );

    try {
      await _service.sendImageMessageStream(imageBytes, text);
    } catch (e) {
      await _streamSub?.cancel();
      _streamSub = null;
      if (mounted) {
        setState(() {
          modelMsg.buffer.write('[Error] $e');
          modelMsg.isStreaming = false;
          _isGenerating = false;
        });
      }
    }
  }

  Future<void> _cancel() async {
    _streamSub?.cancel();
    setState(() {
      _isGenerating = false;
      if (_messages.isNotEmpty && _messages.last.isStreaming) {
        _messages.last.isStreaming = false;
      }
    });
    try {
      await _service.cancelGeneration();
    } catch (_) {}
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollCtrl.hasClients) {
        _scrollCtrl.animateTo(
          _scrollCtrl.position.maxScrollExtent,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      }
    });
  }

  void _showError(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg),
        backgroundColor: Theme.of(context).colorScheme.error,
      ),
    );
  }

  // MARK: - Build

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Chat'),
        backgroundColor: Theme.of(context).colorScheme.surfaceContainerHighest,
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(1),
          child: _EngineBar(
            state: _engineState,
            error: _engineError,
            backend: _backend,
            onBackendChanged: (v) => setState(() => _backend = v),
            onInit: _initEngine,
            onClose: _closeEngine,
            onNewConversation: _newConversation,
            hasConversation: _hasConversation,
          ),
        ),
      ),
      body: Column(
        children: [
          Expanded(
            child: _messages.isEmpty
                ? _EmptyState(
                    engineState: _engineState,
                    hasConversation: _hasConversation,
                  )
                : ListView.builder(
                    controller: _scrollCtrl,
                    padding: const EdgeInsets.symmetric(
                      vertical: 8,
                      horizontal: 12,
                    ),
                    itemCount: _messages.length,
                    itemBuilder: (ctx, i) => _MessageBubble(msg: _messages[i]),
                  ),
          ),
          _InputBar(
            controller: _textCtrl,
            isGenerating: _isGenerating,
            useStreaming: _useStreaming,
            canSend: _hasConversation && _engineState == _EngineState.ready,
            pendingImage: _pendingImage,
            onStreamToggle: (v) => setState(() => _useStreaming = v),
            onPickImage: _showImageSourceSheet,
            onClearImage: () => setState(() => _pendingImage = null),
            onSend: _send,
            onCancel: _cancel,
          ),
        ],
      ),
    );
  }
}

// MARK: - Sub-widgets

class _EngineBar extends StatelessWidget {
  final _EngineState state;
  final String error;
  final String backend;
  final void Function(String) onBackendChanged;
  final VoidCallback onInit;
  final VoidCallback onClose;
  final VoidCallback onNewConversation;
  final bool hasConversation;

  const _EngineBar({
    required this.state,
    required this.error,
    required this.backend,
    required this.onBackendChanged,
    required this.onInit,
    required this.onClose,
    required this.onNewConversation,
    required this.hasConversation,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      color: cs.surfaceContainerHighest,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Row(
        children: [
          _StateChip(state: state, error: error),
          const Spacer(),
          if (state == _EngineState.notLoaded ||
              state == _EngineState.failed) ...[
            DropdownButton<String>(
              value: backend,
              underline: const SizedBox.shrink(),
              items: const [
                DropdownMenuItem(value: 'gpu', child: Text('GPU')),
                DropdownMenuItem(value: 'cpu', child: Text('CPU')),
              ],
              onChanged: (v) {
                if (v != null) onBackendChanged(v);
              },
            ),
            const SizedBox(width: 8),
            FilledButton(onPressed: onInit, child: const Text('Load')),
          ] else if (state == _EngineState.ready) ...[
            if (!hasConversation)
              FilledButton(
                onPressed: onNewConversation,
                child: const Text('New Chat'),
              )
            else
              OutlinedButton(
                onPressed: onNewConversation,
                child: const Text('Reset'),
              ),
            const SizedBox(width: 8),
            OutlinedButton(onPressed: onClose, child: const Text('Unload')),
          ] else if (state == _EngineState.loading) ...[
            const SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            const SizedBox(width: 8),
            const Text('Loading model…'),
          ],
        ],
      ),
    );
  }
}

class _StateChip extends StatelessWidget {
  final _EngineState state;
  final String error;
  const _StateChip({required this.state, required this.error});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final (label, color) = switch (state) {
      _EngineState.notLoaded => ('Not Loaded', cs.outline),
      _EngineState.loading => ('Loading', cs.primary),
      _EngineState.ready => ('Ready', cs.primary),
      _EngineState.failed => ('Failed', cs.error),
    };
    return Chip(
      label: Text(label),
      side: BorderSide(color: color),
      labelStyle: TextStyle(color: color, fontSize: 12),
      padding: EdgeInsets.zero,
      visualDensity: VisualDensity.compact,
    );
  }
}

class _EmptyState extends StatelessWidget {
  final _EngineState engineState;
  final bool hasConversation;
  const _EmptyState({required this.engineState, required this.hasConversation});

  @override
  Widget build(BuildContext context) {
    final String hint = switch (engineState) {
      _EngineState.notLoaded => 'Load the engine to start chatting',
      _EngineState.loading => 'Loading model, please wait…',
      _EngineState.failed => 'Engine failed to load',
      _EngineState.ready when !hasConversation => 'Press "New Chat" to begin',
      _ => 'Send a message',
    };
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.chat_bubble_outline,
            size: 64,
            color: Theme.of(context).colorScheme.outlineVariant,
          ),
          const SizedBox(height: 16),
          Text(hint, style: Theme.of(context).textTheme.bodyMedium),
        ],
      ),
    );
  }
}

class _MessageBubble extends StatelessWidget {
  final ChatMessage msg;
  const _MessageBubble({required this.msg});

  @override
  Widget build(BuildContext context) {
    final isUser = msg.role == 'user';
    final cs = Theme.of(context).colorScheme;
    final bgColor = isUser ? cs.primaryContainer : cs.surfaceContainerHigh;
    final textColor = isUser ? cs.onPrimaryContainer : cs.onSurface;

    return Align(
      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        constraints: BoxConstraints(
          maxWidth: MediaQuery.sizeOf(context).width * 0.8,
        ),
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: bgColor,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (msg.imageBytes != null) ...[
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: Image.memory(
                  msg.imageBytes!,
                  width: 200,
                  fit: BoxFit.cover,
                ),
              ),
              if (msg.text.isNotEmpty) const SizedBox(height: 8),
            ],
            if (msg.text.isNotEmpty || msg.isStreaming)
              Row(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Flexible(
                    child: SelectableText(
                      msg.text.isEmpty && msg.isStreaming ? '…' : msg.text,
                      style: TextStyle(color: textColor),
                    ),
                  ),
                  if (msg.isStreaming) ...[
                    const SizedBox(width: 6),
                    SizedBox(
                      width: 10,
                      height: 10,
                      child: CircularProgressIndicator(
                        strokeWidth: 1.5,
                        color: textColor.withValues(alpha: 0.6),
                      ),
                    ),
                  ],
                ],
              ),
          ],
        ),
      ),
    );
  }
}

class _InputBar extends StatelessWidget {
  final TextEditingController controller;
  final bool isGenerating;
  final bool useStreaming;
  final bool canSend;
  final Uint8List? pendingImage;
  final void Function(bool) onStreamToggle;
  final VoidCallback onPickImage;
  final VoidCallback onClearImage;
  final VoidCallback onSend;
  final VoidCallback onCancel;

  const _InputBar({
    required this.controller,
    required this.isGenerating,
    required this.useStreaming,
    required this.canSend,
    required this.pendingImage,
    required this.onStreamToggle,
    required this.onPickImage,
    required this.onClearImage,
    required this.onSend,
    required this.onCancel,
  });

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                const Text('Stream', style: TextStyle(fontSize: 13)),
                Switch(
                  value: useStreaming,
                  onChanged: canSend ? onStreamToggle : null,
                ),
              ],
            ),
            if (pendingImage != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Row(
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: Image.memory(
                        pendingImage!,
                        width: 64,
                        height: 64,
                        fit: BoxFit.cover,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'Image attached',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.close, size: 18),
                      onPressed: onClearImage,
                      tooltip: 'Remove image',
                      visualDensity: VisualDensity.compact,
                    ),
                  ],
                ),
              ),
            Row(
              children: [
                IconButton(
                  onPressed: canSend && !isGenerating ? onPickImage : null,
                  icon: const Icon(Icons.add_photo_alternate_outlined),
                  tooltip: 'Attach image',
                ),
                Expanded(
                  child: TextField(
                    controller: controller,
                    enabled: canSend && !isGenerating,
                    maxLines: null,
                    textInputAction: TextInputAction.newline,
                    decoration: InputDecoration(
                      hintText: canSend
                          ? (pendingImage != null
                              ? 'Add a question about the image…'
                              : 'Type a message…')
                          : 'Load engine first',
                      border: const OutlineInputBorder(),
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 10,
                      ),
                    ),
                    onSubmitted: (_) {
                      if (!isGenerating) onSend();
                    },
                  ),
                ),
                const SizedBox(width: 8),
                if (isGenerating)
                  IconButton.filled(
                    onPressed: onCancel,
                    icon: const Icon(Icons.stop),
                    tooltip: 'Cancel',
                  )
                else
                  IconButton.filled(
                    onPressed: canSend ? onSend : null,
                    icon: const Icon(Icons.send),
                    tooltip: 'Send',
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
