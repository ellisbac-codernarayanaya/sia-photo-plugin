import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:sia_storage/sia_storage.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:video_player/video_player.dart';
import 'package:workmanager/workmanager.dart';
import 'core/backup_policy.dart';
import 'services/backup.dart';
import 'services/sia_account.dart';
import 'services/store.dart';

const green = Color(0xFF146B52);
const ink = Color(0xFF172F29);
const paper = Color(0xFFF7F8F3);

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Workmanager().initialize(backupDispatcher);
  final store = await Store.open();
  final connected = await SiaAccount.hasAccount();
  if (connected) await BackupSchedule.configure(store);
  runApp(SiaPhotosApp(store: store, connected: connected));
}

class SiaPhotosApp extends StatelessWidget {
  final Store store;
  final bool connected;
  const SiaPhotosApp({super.key, required this.store, required this.connected});
  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Sia Photos',
    debugShowCheckedModeBanner: false,
    theme: ThemeData(
      useMaterial3: true,
      scaffoldBackgroundColor: paper,
      colorScheme: ColorScheme.fromSeed(seedColor: green, surface: paper),
      appBarTheme: const AppBarTheme(
        backgroundColor: paper,
        foregroundColor: ink,
      ),
      inputDecorationTheme: const InputDecorationTheme(
        border: OutlineInputBorder(),
      ),
    ),
    home: connected ? LibraryPage(store: store) : WelcomePage(store: store),
  );
}

class WelcomePage extends StatefulWidget {
  final Store store;
  const WelcomePage({super.key, required this.store});
  @override
  State<WelcomePage> createState() => _WelcomePageState();
}

class _WelcomePageState extends State<WelcomePage> {
  final phrase = TextEditingController();
  bool restore = false, saved = false, busy = false, existing = false;
  String? error, approvalUrl;
  String progress = '';
  int operation = 0;

  @override
  void dispose() {
    operation++;
    phrase.dispose();
    super.dispose();
  }

  Future<void> generate() async {
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final words = await Sia.generateRecoveryPhrase();
      if (mounted) {
        setState(() {
          phrase.text = words;
          saved = false;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(
          () => error =
              'Could not initialise Sia. This build needs the native Sia library.',
        );
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> connect() async {
    final current = ++operation;
    setState(() {
      busy = true;
      error = null;
      progress = 'Preparing your secure connection…';
    });
    try {
      final words = phrase.text
          .trim()
          .toLowerCase()
          .split(RegExp(r'\s+'))
          .join(' ');
      await Sia.validateRecoveryPhrase(words);
      final builder = await SiaAccount.builder();
      await builder.requestConnection();
      if (!mounted || current != operation) return;
      final url = Uri.parse(builder.responseUrl());
      if (url.scheme != 'https') {
        throw StateError('Expected a secure approval URL.');
      }
      setState(() {
        approvalUrl = url.toString();
        progress = 'Approve Sia Photos in your browser, then return here.';
      });
      if (!await launchUrl(url, mode: LaunchMode.externalApplication)) {
        throw StateError('Could not open the approval page.');
      }
      await builder.waitForApproval().timeout(const Duration(minutes: 10));
      if (!mounted || current != operation) return;
      setState(() => progress = 'Connecting your photo library…');
      final sdk = await builder.register(mnemonic: words);
      await SiaAccount.save(sdk, widget.store);
      await widget.store.set('include-existing', existing);
      await widget.store.set('started', DateTime.now().millisecondsSinceEpoch);
      // Permission and automatic backup are enabled explicitly on the next screen.
      await widget.store.set('enabled', false);
      if (!mounted || current != operation) return;
      phrase.clear();
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (_) => LibraryPage(store: widget.store)),
      );
    } catch (_) {
      if (mounted && current == operation) {
        setState(
          () => error =
              'Could not connect. Check the recovery phrase, approve the browser request, and try again.',
        );
      }
    } finally {
      if (mounted && current == operation) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    body: SafeArea(
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: ListView(
            padding: const EdgeInsets.all(28),
            children: [
              const SizedBox(height: 28),
              const Align(
                alignment: Alignment.centerLeft,
                child: CircleAvatar(
                  radius: 32,
                  backgroundColor: green,
                  child: Icon(
                    Icons.photo_library_outlined,
                    color: Colors.white,
                    size: 32,
                  ),
                ),
              ),
              const SizedBox(height: 28),
              const Text(
                'Your moments.\nYour network.',
                style: TextStyle(
                  fontSize: 40,
                  fontWeight: FontWeight.w700,
                  height: 1.1,
                  color: ink,
                ),
              ),
              const SizedBox(height: 18),
              const Text(
                'Take photos as usual. Sia Photos backs up new photos and videos to the Sia network, encrypted on your phone.',
                style: TextStyle(fontSize: 17, height: 1.5),
              ),
              const SizedBox(height: 24),
              const Text(
                'PERSONAL PREVIEW · ANDROID + IPHONE',
                style: TextStyle(
                  fontSize: 11,
                  letterSpacing: 1.5,
                  color: green,
                ),
              ),
              const SizedBox(height: 24),
              SegmentedButton<bool>(
                segments: const [
                  ButtonSegment(value: false, label: Text('New library')),
                  ButtonSegment(value: true, label: Text('Restore library')),
                ],
                selected: {restore},
                onSelectionChanged: busy
                    ? null
                    : (values) => setState(() {
                        restore = values.first;
                        saved = false;
                        phrase.clear();
                        error = null;
                      }),
              ),
              const SizedBox(height: 20),
              Text(
                restore
                    ? 'Enter your Sia Photos recovery phrase'
                    : 'Keep a recovery phrase',
                style: const TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 10),
              Text(
                restore
                    ? 'Use the same Sia account and the phrase created by this app on your other phone. Your library will be rebuilt from Sia.'
                    : 'These 12 words restore this photo library on another phone. Save them somewhere private; we cannot recover them for you.',
              ),
              const SizedBox(height: 16),
              if (!restore && phrase.text.isEmpty)
                OutlinedButton.icon(
                  onPressed: busy ? null : generate,
                  icon: const Icon(Icons.key),
                  label: const Text('Create recovery phrase'),
                ),
              if (restore || phrase.text.isNotEmpty)
                TextField(
                  controller: phrase,
                  readOnly: !restore || busy,
                  maxLines: 3,
                  autocorrect: false,
                  enableSuggestions: false,
                  decoration: const InputDecoration(
                    labelText: '12 recovery words',
                  ),
                ),
              if (!restore && phrase.text.isNotEmpty)
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('I saved these words somewhere private.'),
                  value: saved,
                  onChanged: busy ? null : (v) => setState(() => saved = v!),
                ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Include photos already on this phone'),
                subtitle: const Text('Off: back up new captures after setup.'),
                value: existing,
                onChanged: busy ? null : (v) => setState(() => existing = v),
              ),
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: busy || (!restore && !saved) ? null : connect,
                icon: const Icon(Icons.link),
                label: const Text('Connect my Sia account'),
              ),
              const SizedBox(height: 10),
              const Text(
                'Your Sia account provides storage. This independent app is not affiliated with the Sia Foundation.',
                style: TextStyle(fontSize: 12, height: 1.5),
              ),
              if (busy) ...[
                const SizedBox(height: 20),
                const LinearProgressIndicator(),
                const SizedBox(height: 12),
                Text(progress),
                if (approvalUrl != null)
                  TextButton(
                    onPressed: () => launchUrl(
                      Uri.parse(approvalUrl!),
                      mode: LaunchMode.externalApplication,
                    ),
                    child: const Text('Open approval page again'),
                  ),
              ],
              if (error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 16),
                  child: Text(
                    error!,
                    style: const TextStyle(color: Colors.red),
                  ),
                ),
            ],
          ),
        ),
      ),
    ),
  );
}

class LibraryPage extends StatefulWidget {
  final Store store;
  const LibraryPage({super.key, required this.store});
  @override
  State<LibraryPage> createState() => _LibraryPageState();
}

class _LibraryPageState extends State<LibraryPage> with WidgetsBindingObserver {
  List<PhotoEntry> photos = [];
  Map<String, int> counts = {};
  String message = 'Enable backup to protect new photos.', query = '';
  bool enabled = false, wifi = true, existing = false, limited = false;
  bool loading = false, running = false;
  int tab = 0, limit = 200;
  Timer? timer, debounce;
  final search = TextEditingController();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    PhotoManager.addChangeCallback(onPhotoChange);
    unawaited(load());
    unawaited(PhotoManager.startChangeNotify());
    timer = Timer.periodic(
      const Duration(seconds: 4),
      (_) => unawaited(load()),
    );
    unawaited(runBackup());
    unawaited(syncCloud());
  }

  @override
  void dispose() {
    timer?.cancel();
    debounce?.cancel();
    search.dispose();
    PhotoManager.removeChangeCallback(onPhotoChange);
    unawaited(PhotoManager.stopChangeNotify());
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(load());
      unawaited(runBackup());
      unawaited(syncCloud());
    }
  }

  void onPhotoChange(MethodCall _) {
    debounce?.cancel();
    debounce = Timer(const Duration(seconds: 3), () {
      unawaited(load());
      unawaited(runBackup());
    });
  }

  Future<void> load() async {
    if (loading) return;
    loading = true;
    try {
      final rows = await widget.store.photos(limit: limit);
      final byKey = {for (final p in rows) p.key: p};
      final permission = await PhotoManager.getPermissionState(
        requestOption: photoPermission,
      );
      if (permission.hasAccess) {
        final assets = await PhotoManager.getAssetListPaged(
          page: 0,
          pageCount: limit,
        );
        for (final asset in assets) {
          final key = assetVersion(asset.id, asset.modifiedDateTime);
          byKey.putIfAbsent(
            key,
            () => PhotoEntry(
              key: key,
              assetId: asset.id,
              name: asset.title ?? 'Photo',
              taken: asset.createDateTime,
              video: asset.type == AssetType.video,
              state: 'on-device',
            ),
          );
        }
      }
      final localIds = byKey.values
          .where((p) => p.assetId != null)
          .map((p) => p.objectId)
          .whereType<String>()
          .toSet();
      final list =
          byKey.values
              .where((p) => p.assetId != null || !localIds.contains(p.objectId))
              .toList()
            ..sort((a, b) => b.taken.compareTo(a.taken));
      final nextCounts = await widget.store.counts();
      final nextEnabled = await widget.store.get<bool>('enabled', false);
      final nextWifi = await widget.store.get<bool>('wifi-only', true);
      final nextExisting = await widget.store.get<bool>(
        'include-existing',
        false,
      );
      final nextMessage = await widget.store.get<String>(
        'message',
        'Enable backup to protect new photos.',
      );
      if (mounted) {
        setState(() {
          photos = list;
          counts = nextCounts;
          enabled = nextEnabled;
          wifi = nextWifi;
          existing = nextExisting;
          message = nextMessage;
          limited = permission.hasAccess && !permission.isAuth;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() => message = 'Allow photo access to see your camera roll.');
      }
    } finally {
      loading = false;
    }
  }

  Future<void> syncCloud() async {
    try {
      final sdk = await SiaAccount.connect();
      await SiaAccount.syncCatalog(sdk, widget.store);
      await load();
    } catch (_) {
      if (mounted) {
        setState(
          () => message =
              'Cloud library is unavailable. Your local photos are still visible.',
        );
      }
    }
  }

  Future<void> runBackup() async {
    if (running) return;
    running = true;
    try {
      if (Platform.isAndroid) {
        if (await widget.store.get<bool>('enabled', false)) {
          await BackupSchedule.now(widget.store);
        }
      } else {
        await BackupService(widget.store).run();
      }
    } finally {
      running = false;
      await load();
    }
  }

  Future<void> enable(bool value) async {
    if (value) {
      final permission = await PhotoManager.requestPermissionExtend(
        requestOption: photoPermission,
      );
      if (!permission.hasAccess) {
        await load();
        return;
      }
    }
    await widget.store.set('enabled', value);
    await widget.store.set(
      'message',
      value
          ? 'Automatic backup is on.'
          : 'Backup paused. Saved copies remain on Sia.',
    );
    await BackupSchedule.configure(widget.store);
    if (value) unawaited(runBackup());
    await load();
  }

  Future<void> changeSetting(String key, bool value) async {
    await widget.store.set(key, value);
    await BackupSchedule.configure(widget.store);
    await load();
    if (enabled) unawaited(runBackup());
  }

  @override
  Widget build(BuildContext context) {
    final filtered = photos
        .where(
          (p) =>
              p.name.toLowerCase().contains(query.toLowerCase()) ||
              p.taken.toIso8601String().contains(query),
        )
        .toList();
    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'Sia Photos',
          style: TextStyle(fontWeight: FontWeight.w700),
        ),
        actions: [
          IconButton(
            tooltip: 'Back up now',
            onPressed: () async {
              await widget.store.retryNow();
              await runBackup();
            },
            icon: const Icon(Icons.cloud_sync_outlined),
          ),
        ],
      ),
      body: SafeArea(
        child: tab == 0
            ? CustomScrollView(
                slivers: [
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            'A home for\nyour memories.',
                            style: TextStyle(
                              fontSize: 34,
                              fontWeight: FontWeight.w700,
                              height: 1.12,
                              color: ink,
                            ),
                          ),
                          const SizedBox(height: 20),
                          Container(
                            padding: const EdgeInsets.all(16),
                            decoration: BoxDecoration(
                              color: const Color(0xFFE5EFE7),
                              borderRadius: BorderRadius.circular(20),
                            ),
                            child: Row(
                              children: [
                                Icon(
                                  enabled
                                      ? Icons.cloud_done_outlined
                                      : Icons.cloud_off_outlined,
                                  color: green,
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        enabled
                                            ? 'Automatic backup is on'
                                            : 'Automatic backup is off',
                                        style: const TextStyle(
                                          fontWeight: FontWeight.w600,
                                        ),
                                      ),
                                      const SizedBox(height: 4),
                                      Text(
                                        message,
                                        style: const TextStyle(fontSize: 12),
                                      ),
                                    ],
                                  ),
                                ),
                                Switch(value: enabled, onChanged: enable),
                              ],
                            ),
                          ),
                          if (limited)
                            Padding(
                              padding: const EdgeInsets.only(top: 12),
                              child: TextButton(
                                onPressed: PhotoManager.openSetting,
                                child: const Text(
                                  'Limited access: allow all photos for automatic backup of new captures.',
                                ),
                              ),
                            ),
                          const SizedBox(height: 20),
                          TextField(
                            controller: search,
                            onChanged: (s) => setState(() => query = s),
                            decoration: InputDecoration(
                              hintText: 'Find a filename or date',
                              prefixIcon: const Icon(Icons.search),
                              filled: true,
                              fillColor: Colors.white,
                              border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(28),
                                borderSide: BorderSide.none,
                              ),
                            ),
                          ),
                          const SizedBox(height: 20),
                          Text(
                            'YOUR LIBRARY · ${filtered.length}',
                            style: const TextStyle(
                              letterSpacing: 1.5,
                              fontSize: 11,
                              color: green,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  if (filtered.isEmpty)
                    const SliverFillRemaining(
                      hasScrollBody: false,
                      child: Center(
                        child: Padding(
                          padding: EdgeInsets.all(32),
                          child: Text(
                            'Your photos will appear here.\nEnable photo access, then take a picture.',
                            textAlign: TextAlign.center,
                          ),
                        ),
                      ),
                    ),
                  SliverPadding(
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    sliver: SliverGrid.builder(
                      gridDelegate:
                          const SliverGridDelegateWithFixedCrossAxisCount(
                            crossAxisCount: 3,
                            crossAxisSpacing: 3,
                            mainAxisSpacing: 3,
                          ),
                      itemCount: filtered.length,
                      itemBuilder: (_, i) => PhotoTile(
                        photo: filtered[i],
                        onTap: () => Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) => PhotoPage(
                              photo: filtered[i],
                              store: widget.store,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: OutlinedButton(
                        onPressed: () {
                          limit += 200;
                          unawaited(load());
                        },
                        child: const Text('Load more photos'),
                      ),
                    ),
                  ),
                ],
              )
            : settings(),
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: tab,
        onDestinationSelected: (v) => setState(() => tab = v),
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.photo_library_outlined),
            label: 'Photos',
          ),
          NavigationDestination(
            icon: Icon(Icons.cloud_outlined),
            label: 'Backup',
          ),
        ],
      ),
    );
  }

  Widget settings() => ListView(
    padding: const EdgeInsets.all(20),
    children: [
      const Text(
        'Quietly protected.',
        style: TextStyle(fontSize: 32, fontWeight: FontWeight.w700, color: ink),
      ),
      const SizedBox(height: 16),
      Text(message),
      const SizedBox(height: 20),
      Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          for (final entry in counts.entries)
            Chip(label: Text('${entry.key}: ${entry.value}')),
        ],
      ),
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: const Text('Automatic backup'),
        subtitle: const Text('Encrypted on this phone, stored on Sia.'),
        value: enabled,
        onChanged: enable,
      ),
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: const Text('Wi-Fi only'),
        subtitle: const Text(
          'Wait for Wi-Fi before uploading and verifying backups.',
        ),
        value: wifi,
        onChanged: (v) => changeSetting('wifi-only', v),
      ),
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: const Text('Include existing photos'),
        subtitle: const Text(
          'Also back up photos and videos from before setup.',
        ),
        value: existing,
        onChanged: (v) => changeSetting('include-existing', v),
      ),
      const Divider(height: 32),
      ListTile(
        contentPadding: EdgeInsets.zero,
        leading: const Icon(Icons.verified_user_outlined),
        title: const Text('What does verified mean?'),
        subtitle: const Text(
          'The app uploaded the original, downloaded it back, and checked that every byte matches. Verification uses download data.',
        ),
      ),
      ListTile(
        contentPadding: EdgeInsets.zero,
        leading: const Icon(Icons.schedule),
        title: const Text('When will photos upload?'),
        subtitle: Text(
          Platform.isIOS
              ? 'While the app is open and when iOS grants background time. Force-quitting, Low Power Mode, or disabling Background App Refresh can stop background backup.'
              : 'When Android detects new media, with a scheduled check roughly every 15 minutes. Battery restrictions and force-stop can delay backup.',
        ),
      ),
      const ListTile(
        contentPadding: EdgeInsets.zero,
        leading: Icon(Icons.lock_outline),
        title: Text('Keep your recovery phrase'),
        subtitle: Text(
          'Your app key stays in protected device storage. Use the same recovery phrase on another phone to reopen this library. Your Sia subscription must remain active.',
        ),
      ),
      const ListTile(
        contentPadding: EdgeInsets.zero,
        leading: Icon(Icons.info_outline),
        title: Text('Personal preview'),
        subtitle: Text(
          'Original photos and videos only. Live Photo motion pairs, editing, face search, shared albums, and Google Photos import are not included. Storage pricing depends on your Sia plan.',
        ),
      ),
      OutlinedButton.icon(
        onPressed: () => launchUrl(
          Uri.parse('https://sia.storage'),
          mode: LaunchMode.externalApplication,
        ),
        icon: const Icon(Icons.open_in_new),
        label: const Text('Manage Sia storage'),
      ),
      TextButton(
        onPressed: PhotoManager.openSetting,
        child: const Text('Photo permissions'),
      ),
    ],
  );
}

class PhotoTile extends StatefulWidget {
  final PhotoEntry photo;
  final VoidCallback onTap;
  const PhotoTile({super.key, required this.photo, required this.onTap});
  @override
  State<PhotoTile> createState() => _PhotoTileState();
}

class _PhotoTileState extends State<PhotoTile> {
  late Future<Uint8List?> thumbnail;
  @override
  void initState() {
    super.initState();
    thumbnail = loadThumb();
  }

  @override
  void didUpdateWidget(PhotoTile old) {
    super.didUpdateWidget(old);
    if (old.photo.key != widget.photo.key ||
        old.photo.thumbnail != widget.photo.thumbnail)
      thumbnail = loadThumb();
  }

  Future<Uint8List?> loadThumb() async {
    try {
      if (widget.photo.thumbnail != null)
        return base64Decode(widget.photo.thumbnail!);
      if (widget.photo.assetId == null) return null;
      final asset = await AssetEntity.fromId(widget.photo.assetId!);
      return await asset?.thumbnailDataWithSize(
        const ThumbnailSize.square(320),
      );
    } catch (_) {
      return null;
    }
  }

  @override
  Widget build(BuildContext context) => Semantics(
    label: '${widget.photo.name}, ${widget.photo.state}',
    button: true,
    child: InkWell(
      onTap: widget.onTap,
      child: Stack(
        fit: StackFit.expand,
        children: [
          Container(
            color: const Color(0xFFE2E7DE),
            child: FutureBuilder<Uint8List?>(
              future: thumbnail,
              builder: (_, s) => s.data == null
                  ? Icon(
                      widget.photo.video
                          ? Icons.videocam_outlined
                          : Icons.image_outlined,
                      color: green,
                    )
                  : Image.memory(
                      s.data!,
                      fit: BoxFit.cover,
                      gaplessPlayback: true,
                    ),
            ),
          ),
          Positioned(
            right: 6,
            bottom: 6,
            child: CircleAvatar(
              radius: 13,
              backgroundColor: Colors.black54,
              child: Icon(
                widget.photo.state == 'verified'
                    ? Icons.cloud_done
                    : widget.photo.state == 'on-device'
                    ? Icons.phone_android
                    : widget.photo.state == 'failed'
                    ? Icons.error_outline
                    : Icons.cloud_upload_outlined,
                color: Colors.white,
                size: 16,
              ),
            ),
          ),
          if (widget.photo.video)
            const Positioned(
              left: 8,
              top: 8,
              child: Icon(Icons.play_arrow, color: Colors.white),
            ),
        ],
      ),
    ),
  );
}

class PhotoPage extends StatefulWidget {
  final PhotoEntry photo;
  final Store store;
  const PhotoPage({super.key, required this.photo, required this.store});
  @override
  State<PhotoPage> createState() => _PhotoPageState();
}

class _PhotoPageState extends State<PhotoPage> {
  File? file;
  VideoPlayerController? video;
  String? error;
  bool busy = false;
  @override
  void initState() {
    super.initState();
    unawaited(loadLocal());
  }

  @override
  void dispose() {
    video?.dispose();
    super.dispose();
  }

  Future<void> showFile(File value) async {
    if (!mounted) return;
    if (widget.photo.video) {
      final controller = VideoPlayerController.file(value);
      await controller.initialize();
      if (!mounted) {
        await controller.dispose();
        return;
      }
      await video?.dispose();
      video = controller;
    }
    if (mounted) setState(() => file = value);
  }

  Future<void> loadLocal() async {
    try {
      final asset = widget.photo.assetId == null
          ? null
          : await AssetEntity.fromId(widget.photo.assetId!);
      final local = await asset?.file;
      if (local != null) await showFile(local);
    } catch (_) {
      if (mounted) {
        setState(() => error = 'Original is not available on this phone.');
      }
    }
  }

  Future<void> download({bool save = false}) async {
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final sdk = await SiaAccount.connect();
      final restored = await SiaAccount.downloadVerified(sdk, widget.photo);
      if (save) {
        final permission = await PhotoManager.requestPermissionExtend(
          requestOption: photoPermission,
        );
        if (!permission.hasAccess) {
          throw StateError('Photo permission is required.');
        }
        if (widget.photo.video) {
          await PhotoManager.editor.saveVideo(
            restored,
            title: safeFilename(widget.photo.name),
            creationDate: widget.photo.taken,
          );
        } else {
          await PhotoManager.editor.saveImageWithPath(
            restored.path,
            title: safeFilename(widget.photo.name),
            creationDate: widget.photo.taken,
          );
        }
      }
      await showFile(restored);
      if (mounted && save) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Saved to your phone’s photo library.')),
        );
      }
    } catch (_) {
      if (mounted) {
        setState(
          () => error =
              'Could not download a verified copy. Check your connection and try again.',
        );
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(widget.photo.name, maxLines: 1)),
    body: Column(
      children: [
        Expanded(
          child: Container(
            color: ink,
            alignment: Alignment.center,
            child: file == null
                ? const Icon(
                    Icons.photo_outlined,
                    color: Colors.white54,
                    size: 80,
                  )
                : video != null
                ? AspectRatio(
                    aspectRatio: video!.value.aspectRatio,
                    child: VideoPlayer(video!),
                  )
                : InteractiveViewer(
                    child: Image.file(
                      file!,
                      errorBuilder: (_, error, stack) => const Text(
                        'This format cannot be previewed here.',
                        style: TextStyle(color: Colors.white),
                      ),
                    ),
                  ),
          ),
        ),
        if (video != null)
          IconButton(
            onPressed: () async {
              if (video!.value.isPlaying) {
                await video!.pause();
              } else {
                await video!.play();
              }
              setState(() {});
            },
            icon: Icon(video!.value.isPlaying ? Icons.pause : Icons.play_arrow),
          ),
        Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            children: [
              Text(widget.photo.taken.toLocal().toString().split('.').first),
              Text(widget.photo.state, style: const TextStyle(color: green)),
              if (widget.photo.error != null) Text(widget.photo.error!),
              if (busy) const LinearProgressIndicator(),
              if (error != null)
                Text(error!, style: const TextStyle(color: Colors.red)),
              if (widget.photo.objectId != null) ...[
                const SizedBox(height: 12),
                OutlinedButton.icon(
                  onPressed: busy ? null : () => download(),
                  icon: const Icon(Icons.cloud_download_outlined),
                  label: const Text('View copy from Sia'),
                ),
                FilledButton.icon(
                  onPressed: busy ? null : () => download(save: true),
                  icon: const Icon(Icons.save_alt),
                  label: const Text('Save Sia copy to phone'),
                ),
              ],
            ],
          ),
        ),
      ],
    ),
  );
}
