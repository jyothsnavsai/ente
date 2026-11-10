import "package:photos/core/event_bus.dart";
import "package:photos/db/files_db.dart";
import "package:photos/db/local_albums_db.dart";
import "package:photos/events/collection_updated_event.dart";
import "package:photos/events/files_updated_event.dart";
import "package:photos/models/file/file.dart";
import "package:photos/models/file_load_result.dart";

class LocalAlbumsService {
  LocalAlbumsService._();

  static final instance = LocalAlbumsService._();

  final _albumsDB = LocalAlbumsDB.instance;
  final _filesDB = FilesDB.instance;

  Future<List<LocalAlbum>> getAlbums() => _albumsDB.getAlbums();

  Future<LocalAlbum> createAlbum(String name) async {
    final album = await _albumsDB.createAlbum(name);
    Bus.instance.fire(
      CollectionUpdatedEvent(-album.id, const [], "localAlbumCreate"),
    );
    return album;
  }

  Future<void> addFiles(int albumID, Iterable<EnteFile> files) async {
    final localAlbumID = _collectionID(albumID);
    final filesByLocalID = <String, EnteFile>{};
    for (final file in files) {
      final localID = file.localID;
      if (localID != null) {
        filesByLocalID.putIfAbsent(localID, () => file);
      }
    }
    if (filesByLocalID.isEmpty) return;

    await _albumsDB.addFiles(albumID, filesByLocalID.keys);
    final albumFiles = filesByLocalID.values
        .map((file) => EnteFile.from(file)..collectionID = localAlbumID)
        .toList();
    Bus.instance.fire(
      CollectionUpdatedEvent(localAlbumID, albumFiles, "localAlbumAdd"),
    );
    Bus.instance.fire(FilesUpdatedEvent(albumFiles, source: "localAlbumAdd"));
  }

  Future<void> removeFiles(int albumID, Iterable<EnteFile> files) async {
    final selectedFiles = files.toList();
    final localIDs = selectedFiles
        .map((file) => file.localID)
        .whereType<String>();
    final uniqueLocalIDs = localIDs.toSet();
    if (uniqueLocalIDs.isEmpty) return;

    final localAlbumID = _collectionID(albumID);
    await _albumsDB.removeFiles(albumID, uniqueLocalIDs);
    final albumFiles = selectedFiles
        .map((file) => EnteFile.from(file)..collectionID = localAlbumID)
        .toList();
    Bus.instance.fire(
      CollectionUpdatedEvent(localAlbumID, albumFiles, "localAlbumRemove"),
    );
    Bus.instance.fire(
      FilesUpdatedEvent(albumFiles, source: "localAlbumRemove"),
    );
  }

  Future<void> deleteAlbum(int albumID) async {
    final localAlbumID = _collectionID(albumID);
    await _albumsDB.deleteAlbum(albumID);
    Bus.instance.fire(
      CollectionUpdatedEvent(localAlbumID, const [], "localAlbumDelete"),
    );
  }

  Future<void> renameAlbum(int albumID, String name) =>
      _albumsDB.renameAlbum(albumID, name);

  Future<FileLoadResult> getFiles(
    int albumID,
    int startTime,
    int endTime, {
    int? limit,
    bool? asc,
  }) async {
    final localIDs = await _albumsDB.getLocalIDs(albumID);
    final files = await _filesDB.getLocalFilesByIDs(localIDs);
    files.removeWhere((file) {
      final creationTime = file.creationTime ?? 0;
      return creationTime < startTime || creationTime > endTime;
    });
    files.sort((first, second) {
      final creationComparison = (first.creationTime ?? 0).compareTo(
        second.creationTime ?? 0,
      );
      final comparison = creationComparison != 0
          ? creationComparison
          : (first.modificationTime ?? 0).compareTo(
              second.modificationTime ?? 0,
            );
      return (asc ?? false) ? comparison : -comparison;
    });
    final hasMore = limit != null && files.length > limit;
    return FileLoadResult(
      limit == null ? files : files.take(limit).toList(),
      hasMore,
    );
  }

  static int _collectionID(int albumID) {
    if (albumID <= 0) {
      throw ArgumentError.value(albumID, "albumID", "must be positive");
    }
    return -albumID;
  }
}