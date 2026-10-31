import 'dart:convert';
import 'package:photos/core/Configuration.dart';
import 'package:photos/core/event_bus.dart';
import 'package:photos/db/collections_db.dart';
import 'package:photos/db/files_db.dart';
import 'package:photos/db/ml/ml_data_db.dart';
import 'package:photos/events/collection_updated_event.dart';
import 'package:photos/events/people_changed_event.dart';
import 'package:photos/models/collection/collection.dart';
import 'package:photos/models/file/file.dart';
import 'package:photos/models/ml/face/person.dart';
import 'package:photos/utils/crypto_util.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

class LocalOfflineFeaturesService {
  LocalOfflineFeaturesService._privateConstructor();
  static final LocalOfflineFeaturesService instance =
      LocalOfflineFeaturesService._privateConstructor();

  static const String _autoAddPrefsPrefix = "local_album_auto_add_people_";

  /// 1. OFFLINE PEOPLE NAMING
  Future<PersonEntity> savePersonLocally({
    required String name,
    required String clusterID,
    String? avatarFaceID,
  }) async {
    final String personID = const Uuid().v4();
    final int now = DateTime.now().microsecondsSinceEpoch;

    final personData = PersonData(
      name: name.trim(),
      assigned: [
        ClusterAssignment(clusterID: clusterID, assignedAt: now),
      ],
      rejected: [],
      avatarFaceID: avatarFaceID,
    );

    final personEntity = PersonEntity(
      remoteID: personID,
      data: personData,
      isIgnored: false,
      version: 1,
    );

    await MLDataDB.instance.putPerson(personEntity);
    await MLDataDB.instance.assignClusterToPerson(
      personID: personID,
      clusterID: clusterID,
    );
    Bus.instance.fire(PeopleChangedEvent());
    await syncLocalAutoAddAlbums();
    return personEntity;
  }

  Future<PersonEntity> updatePersonLocally(PersonEntity updatedPerson) async {
    await MLDataDB.instance.putPerson(updatedPerson);
    Bus.instance.fire(PeopleChangedEvent());
    await syncLocalAutoAddAlbums();
    return updatedPerson;
  }

  /// 2. OFFLINE VIRTUAL ALBUM CREATION (Negative IDs avoid server ID collisions)
  Future<Collection> createLocalAlbum(String albumName) async {
    final int localCollectionID = -DateTime.now().millisecondsSinceEpoch;
    final int now = DateTime.now().microsecondsSinceEpoch;
    final int ownerID = Configuration.instance.getUserID() ?? 0;

    final localCollection = Collection(
      localCollectionID,
      User(id: ownerID, email: "local@device", name: "Local User"),
      CryptoUtil.generateKey(),
      null,
      albumName,
      CollectionType.album,
      CollectionAttributes(),
      [],
      now,
      isDeleted: false,
      mMdVersion: 1,
      magicMetadata: CollectionMagicMetadata(visibility: visibilityVisible),
    )..decryptedName = albumName;

    await CollectionsDB.instance.insert([localCollection]);
    Bus.instance.fire(
      CollectionUpdatedEvent(localCollectionID, <EnteFile>[], "local_album_created"),
    );
    return localCollection;
  }

  /// 3. ADD OR MOVE LOCAL PHOTOS BETWEEN ALBUMS
  Future<void> addLocalFilesToAlbum(
    int toCollectionID,
    List<EnteFile> files,
  ) async {
    final List<EnteFile> copies = [];
    for (final file in files) {
      final copy = file.copyWith(
        generatedID: null,
        collectionID: toCollectionID,
      );
      copies.add(copy);
    }
    await FilesDB.instance.insertMultiple(copies);
    Bus.instance.fire(
      CollectionUpdatedEvent(toCollectionID, copies, "local_files_added"),
    );
  }

  Future<void> moveLocalFilesBetweenAlbums(
    List<EnteFile> files, {
    required int fromCollectionID,
    required int toCollectionID,
  }) async {
    await addLocalFilesToAlbum(toCollectionID, files);
    final db = await FilesDB.instance.database;
    final localIDs = files.where((f) => f.localID != null).map((f) => f.localID!).toList();
    if (localIDs.isNotEmpty) {
      final placeholders = List.filled(localIDs.length, '?').join(',');
      await db.delete(
        FilesDB.table,
        where: '${FilesDB.columnCollectionID} = ? AND ${FilesDB.columnLocalID} IN ($placeholders)',
        whereArgs: [fromCollectionID, ...localIDs],
      );
    }
    Bus.instance.fire(
      CollectionUpdatedEvent(fromCollectionID, files, "local_files_moved_out"),
    );
  }

  /// 4. AUTO-ADD PEOPLE TO LOCAL ALBUMS
  Future<void> setAutoAddPeopleForAlbum(
    int collectionID,
    List<String> personIDs,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList("$_autoAddPrefsPrefix$collectionID", personIDs);
    await syncLocalAutoAddAlbums();
  }

  Future<List<String>> getAutoAddPeopleForAlbum(int collectionID) async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getStringList("$_autoAddPrefsPrefix$collectionID") ?? <String>[];
  }

  Future<void> syncLocalAutoAddAlbums() async {
    final prefs = await SharedPreferences.getInstance();
    final keys = prefs.getKeys().where((k) => k.startsWith(_autoAddPrefsPrefix));

    for (final key in keys) {
      final collectionIDStr = key.replaceFirst(_autoAddPrefsPrefix, "");
      final int? collectionID = int.tryParse(collectionIDStr);
      if (collectionID == null) continue;

      final List<String> personIDs = prefs.getStringList(key) ?? [];
      if (personIDs.isEmpty) continue;

      final Set<int> matchingMlFileIDs = {};
      for (final personID in personIDs) {
        final clusterIDs = await MLDataDB.instance.getClusterIDsForPerson(personID);
        for (final clusterID in clusterIDs.keys) {
          final fileIDs = await MLDataDB.instance.getFileIDsOfCluster(clusterID);
          matchingMlFileIDs.addAll(fileIDs);
        }
      }

      if (matchingMlFileIDs.isEmpty) continue;

      // Match local files in FilesDB whose generatedID or uploadedFileID matches
      final db = await FilesDB.instance.database;
      final idList = matchingMlFileIDs.toList();
      final placeholders = List.filled(idList.length, '?').join(',');
      final rows = await db.query(
        FilesDB.table,
        where: '${FilesDB.columnGeneratedID} IN ($placeholders) OR ${FilesDB.columnUploadedFileID} IN ($placeholders)',
        whereArgs: [...idList, ...idList],
      );

      if (rows.isEmpty) continue;

      final existingRows = await db.query(
        FilesDB.table,
        columns: [FilesDB.columnLocalID],
        where: '${FilesDB.columnCollectionID} = ?',
        whereArgs: [collectionID],
      );
      final existingLocalIDs = existingRows
          .map((r) => r[FilesDB.columnLocalID] as String?)
          .whereType<String>()
          .toSet();

      final List<EnteFile> toAdd = [];
      final Set<String> seenInBatch = {};
      for (final row in rows) {
        final localID = row[FilesDB.columnLocalID] as String?;
        if (localID != null &&
            !existingLocalIDs.contains(localID) &&
            !seenInBatch.contains(localID)) {
          seenInBatch.add(localID);
          // Reconstruct via FilesDB helper if available
          final fileMap = Map<String, dynamic>.from(row);
          fileMap[FilesDB.columnGeneratedID] = null;
          fileMap[FilesDB.columnCollectionID] = collectionID;
          await db.insert(FilesDB.table, fileMap);
        }
      }

      if (seenInBatch.isNotEmpty) {
        Bus.instance.fire(
          CollectionUpdatedEvent(collectionID, <EnteFile>[], "auto_add_local_people"),
        );
      }
    }
  }
}
