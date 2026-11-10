import "dart:async";

import "package:ente_strings/ente_strings.dart";
import "package:flutter/material.dart";
import "package:photos/core/event_bus.dart";
import "package:photos/db/local_albums_db.dart";
import "package:photos/events/collection_updated_event.dart";
import "package:photos/events/files_updated_event.dart";
import "package:photos/models/selected_files.dart";
import "package:photos/services/local_albums_service.dart";
import "package:photos/ui/viewer/gallery/empty_state.dart";
import "package:photos/ui/viewer/gallery/gallery.dart";
import "package:photos/ui/viewer/gallery/state/selection_state.dart";

class LocalAlbumsSliver extends StatefulWidget {
  const LocalAlbumsSliver({super.key});

  @override
  State<LocalAlbumsSliver> createState() => _LocalAlbumsSliverState();
}

class _LocalAlbumsSliverState extends State<LocalAlbumsSliver> {
  late Future<List<LocalAlbum>> _albums = LocalAlbumsService.instance
      .getAlbums();
  late final StreamSubscription<CollectionUpdatedEvent>
  _collectionUpdatedSubscription;

  @override
  void initState() {
    super.initState();
    _collectionUpdatedSubscription = Bus.instance
        .on<CollectionUpdatedEvent>()
        .where((event) => (event.collectionID ?? 0) < 0)
        .listen((_) {
          if (!mounted) return;
          setState(() {
            _albums = LocalAlbumsService.instance.getAlbums();
          });
        });
  }

  @override
  void dispose() {
    unawaited(_collectionUpdatedSubscription.cancel());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SliverToBoxAdapter(
      child: FutureBuilder<List<LocalAlbum>>(
        future: _albums,
        builder: (context, snapshot) {
          final albums = snapshot.data ?? const <LocalAlbum>[];
          return Column(
            children: [
              ListTile(
                title: Text(context.strings.albums),
                trailing: IconButton(
                  tooltip: context.strings.createAlbum,
                  onPressed: _createAlbum,
                  icon: const Icon(Icons.add),
                ),
              ),
              if (snapshot.hasError)
                ListTile(title: Text(context.strings.somethingWentWrong))
              else if (snapshot.connectionState == ConnectionState.waiting)
                const LinearProgressIndicator()
              else if (albums.isEmpty)
                ListTile(title: Text(context.strings.noAlbumsFound))
              else
                for (final album in albums)
                  ListTile(
                    leading: const Icon(Icons.photo_album_outlined),
                    title: Text(album.name),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => LocalAlbumPage(album: album),
                      ),
                    ),
                  ),
            ],
          );
        },
      ),
    );
  }

  Future<void> _createAlbum() async {
    final controller = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(context.strings.createAlbum),
        content: TextField(
          controller: controller,
          autofocus: true,
          textCapitalization: TextCapitalization.sentences,
          decoration: InputDecoration(hintText: context.strings.enterAlbumName),
          onSubmitted: (value) => Navigator.of(context).pop(value.trim()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(context.strings.cancel),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(controller.text.trim()),
            child: Text(context.strings.create),
          ),
        ],
      ),
    );
    controller.dispose();
    if (!mounted || name == null || name.trim().isEmpty) return;
    await LocalAlbumsService.instance.createAlbum(name.trim());
    setState(() {
      _albums = LocalAlbumsService.instance.getAlbums();
    });
  }
}

class LocalAlbumPage extends StatefulWidget {
  const LocalAlbumPage({required this.album, super.key});

  final LocalAlbum album;

  @override
  State<LocalAlbumPage> createState() => _LocalAlbumPageState();
}

class _LocalAlbumPageState extends State<LocalAlbumPage> {
  final _selectedFiles = SelectedFiles();

  @override
  void dispose() {
    _selectedFiles.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final collectionID = -widget.album.id;
    return Scaffold(
      appBar: AppBar(title: Text(widget.album.name)),
      body: SelectionState(
        selectedFiles: _selectedFiles,
        child: Gallery(
          tagPrefix: "local_album_${widget.album.id}",
          albumName: widget.album.name,
          selectedFiles: _selectedFiles,
          emptyState: const EmptyState(),
          reloadEvent: Bus.instance.on<FilesUpdatedEvent>().where(
            (event) => event.files.any(
              (file) => file.collectionID == collectionID,
            ),
          ),
          asyncLoader: (startTime, endTime, {limit, asc}) async {
            return LocalAlbumsService.instance.getFiles(
              widget.album.id,
              startTime,
              endTime,
              limit: limit,
              asc: asc,
            );
          },
        ),
      ),
      bottomNavigationBar: AnimatedBuilder(
        animation: _selectedFiles,
        builder: (context, _) {
          if (_selectedFiles.files.isEmpty) return const SizedBox.shrink();
          return SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _removeSelectedFiles,
                      icon: const Icon(Icons.remove_circle_outline),
                      label: Text(context.strings.removeFromAlbumTitle),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: _moveSelectedFiles,
                      icon: const Icon(Icons.drive_file_move_outline),
                      label: Text(context.strings.moveToAlbum),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Future<void> _removeSelectedFiles() async {
    final files = _selectedFiles.files.toList();
    await LocalAlbumsService.instance.removeFiles(widget.album.id, files);
    _selectedFiles.clearAll();
  }

  Future<void> _moveSelectedFiles() async {
    final albums = await LocalAlbumsService.instance.getAlbums();
    if (!mounted) return;
    final destination = await showModalBottomSheet<LocalAlbum>(
      context: context,
      builder: (context) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            for (final album in albums.where(
              (album) => album.id != widget.album.id,
            ))
              ListTile(
                leading: const Icon(Icons.photo_album_outlined),
                title: Text(album.name),
                onTap: () => Navigator.of(context).pop(album),
              ),
          ],
        ),
      ),
    );
    if (!mounted || destination == null) return;

    final files = _selectedFiles.files.toList();
    await LocalAlbumsService.instance.addFiles(destination.id, files);
    await LocalAlbumsService.instance.removeFiles(widget.album.id, files);
    _selectedFiles.clearAll();
  }
}