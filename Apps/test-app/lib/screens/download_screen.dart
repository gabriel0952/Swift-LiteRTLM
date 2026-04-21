import 'package:flutter/material.dart';
import '../services/litert_service.dart';

class DownloadScreen extends StatefulWidget {
  const DownloadScreen({super.key});

  @override
  State<DownloadScreen> createState() => _DownloadScreenState();
}

class _DownloadScreenState extends State<DownloadScreen> {
  final _service = LiteRTService();
  DownloadStatus _status = DownloadStatus.initial();

  @override
  void initState() {
    super.initState();
    _loadInitialStatus();
    _service.downloadProgress.listen(
      (s) { if (mounted) setState(() => _status = s); },
      onError: (_) {},
    );
  }

  Future<void> _loadInitialStatus() async {
    try {
      final s = await _service.getDownloadStatus();
      if (mounted) setState(() => _status = s);
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Model Download'),
        backgroundColor: cs.surfaceContainerHighest,
      ),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _StatusCard(status: _status, colorScheme: cs),
            const SizedBox(height: 24),
            if (_status.status == 'downloading' || _status.status == 'paused')
              _ProgressSection(status: _status),
            const SizedBox(height: 24),
            _ControlButtons(
              status: _status,
              service: _service,
              onError: _showError,
            ),
            if (_status.status == 'completed') ...[
              const SizedBox(height: 16),
              Card(
                color: cs.secondaryContainer,
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Row(
                    children: [
                      Icon(Icons.check_circle, color: cs.onSecondaryContainer),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          'Model ready — go to Chat tab to start testing.',
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: cs.onSecondaryContainer,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  void _showError(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), backgroundColor: Theme.of(context).colorScheme.error),
    );
  }
}

class _StatusCard extends StatelessWidget {
  final DownloadStatus status;
  final ColorScheme colorScheme;

  const _StatusCard({required this.status, required this.colorScheme});

  @override
  Widget build(BuildContext context) {
    final (icon, label, color) = switch (status.status) {
      'notStarted' => (Icons.cloud_download_outlined, 'Not Downloaded', colorScheme.outline),
      'downloading' => (Icons.downloading, 'Downloading…', colorScheme.primary),
      'paused' => (Icons.pause_circle_outline, 'Paused', colorScheme.tertiary),
      'completed' => (Icons.check_circle, 'Ready', colorScheme.primary),
      'failed' => (Icons.error_outline, 'Failed', colorScheme.error),
      _ => (Icons.help_outline, status.status, colorScheme.outline),
    };

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Row(
          children: [
            Icon(icon, size: 48, color: color),
            const SizedBox(width: 20),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Gemma 4 E2B',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 4),
                  Text(label, style: TextStyle(color: color, fontWeight: FontWeight.w500)),
                  if (status.status == 'failed' && status.error != null)
                    Text(
                      status.error!,
                      style: TextStyle(color: colorScheme.error, fontSize: 12),
                    ),
                  const SizedBox(height: 4),
                  Text(
                    'Size: ${status.displaySize}',
                    style: Theme.of(context).textTheme.bodySmall,
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

class _ProgressSection extends StatelessWidget {
  final DownloadStatus status;
  const _ProgressSection({required this.status});

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        LinearProgressIndicator(value: status.progress, minHeight: 8),
        const SizedBox(height: 8),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              '${status.downloadedDisplay} / ${status.displaySize}',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            Text(
              '${(status.progress * 100).toStringAsFixed(1)}%',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ],
    );
  }
}

class _ControlButtons extends StatelessWidget {
  final DownloadStatus status;
  final LiteRTService service;
  final void Function(String) onError;

  const _ControlButtons({
    required this.status,
    required this.service,
    required this.onError,
  });

  Future<void> _run(Future<void> Function() action) async {
    try {
      await action();
    } catch (e) {
      onError(e.toString());
    }
  }

  @override
  Widget build(BuildContext context) {
    return switch (status.status) {
      'notStarted' || 'failed' => FilledButton.icon(
          onPressed: () => _run(service.startDownload),
          icon: const Icon(Icons.download),
          label: Text('Download (${status.displaySize})'),
        ),
      'downloading' => Row(
          children: [
            Expanded(
              child: FilledButton.icon(
                onPressed: () => _run(service.pauseDownload),
                icon: const Icon(Icons.pause),
                label: const Text('Pause'),
              ),
            ),
            const SizedBox(width: 12),
            OutlinedButton.icon(
              onPressed: () => _run(service.cancelDownload),
              icon: const Icon(Icons.cancel_outlined),
              label: const Text('Cancel'),
            ),
          ],
        ),
      'paused' => Row(
          children: [
            Expanded(
              child: FilledButton.icon(
                onPressed: () => _run(service.startDownload),
                icon: const Icon(Icons.play_arrow),
                label: const Text('Resume'),
              ),
            ),
            const SizedBox(width: 12),
            OutlinedButton.icon(
              onPressed: () => _run(service.cancelDownload),
              icon: const Icon(Icons.cancel_outlined),
              label: const Text('Cancel'),
            ),
          ],
        ),
      'completed' => OutlinedButton.icon(
          onPressed: () => _run(service.deleteModel),
          icon: const Icon(Icons.delete_outline),
          label: const Text('Delete Model'),
        ),
      _ => const SizedBox.shrink(),
    };
  }
}
