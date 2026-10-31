#!/usr/bin/env python3
"""
Automated patcher for Ente Photos (mobile/apps/photos)
Enables:
1. Offline People Naming & Editing (without an Ente cloud account)
2. Offline Virtual Albums + Moving/Adding local photos between albums
3. Offline Auto-Add People to Local Albums (Smart Albums)
4. Unlocks Gallery Mode UI guards (buttons hidden by hasConfiguredAccount)
"""

import os
import re
import subprocess
import sys
from pathlib import Path


def find_photos_lib_dir() -> Path:
    candidates = [
        Path("mobile/apps/photos/lib"),
        Path("apps/photos/lib"),
        Path("lib"),
    ]
    for candidate in candidates:
        if candidate.exists() and (candidate / "main.dart").exists():
            return candidate.resolve()
    print("Error: Could not locate 'mobile/apps/photos/lib'. Run this from the ente repo root.")
    sys.exit(1)


def create_git_branch():
    try:
        subprocess.run(
            ["git", "checkout", "-b", "feat/offline-local-albums-and-people"],
            check=False,
        )
    except Exception as e:
        print(f"Skipping git branch creation: {e}")


def backup_and_write(file_path: Path, new_content: str):
    file_path.write_text(new_content, encoding="utf-8")
    print(f"[PATCHED] {file_path}")


def create_local_smart_album_helper(lib_dir: Path):
    """
    Creates a standalone service `lib/services/local_offline_features_service.dart`
    that handles:
      - Saving/updating PersonEntity locally in MLDataDB without server calls
      - Creating local virtual albums (negative collection IDs) in CollectionsDB
      - Moving & copying local EnteFiles (uploadedFileID == null) between albums in FilesDB
      - Auto-adding local photos of named People into local albums
    """
    helper_path = lib_dir / "services" / "local_offline_features_service.dart"
    code = '''import 'dart:convert';
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
'''
    backup_and_write(helper_path, code)


def patch_person_service(lib_dir: Path):
    """
    Patches person_service.dart so adding/updating a person works offline
    when Configuration.instance.hasConfiguredAccount() is false.
    """
    candidates = list(lib_dir.rglob("person_service.dart"))
    if not candidates:
        print("[WARN] person_service.dart not found; skipping direct patch.")
        return

    path = candidates[0]
    content = path.read_text(encoding="utf-8")

    import_stmt = "import 'package:photos/services/local_offline_features_service.dart';\nimport 'package:photos/core/configuration.dart';\n"
    if "local_offline_features_service.dart" not in content:
        content = import_stmt + content

    # Hook into addPerson / createPerson
    pattern_add = re.compile(
        r"(Future<PersonEntity\?>\s+addPerson\s*\([^)]*\)\s*async\s*\{)",
        re.MULTILINE,
    )
    replacement_add = (
        r"\1\n"
        r"    if (!Configuration.instance.hasConfiguredAccount()) {\n"
        r"      final saved = await LocalOfflineFeaturesService.instance.savePersonLocally(\n"
        r"        name: name,\n"
        r"        clusterID: clusterID,\n"
        r"        avatarFaceID: avatarFaceID,\n"
        r"      );\n"
        r"      return saved;\n"
        r"    }\n"
    )
    new_content, count = pattern_add.subn(replacement_add, content, count=1)

    if count > 0:
        backup_and_write(path, new_content)
    else:
        print(f"[INFO] Could not auto-match addPerson signature in {path}; import added.")
        backup_and_write(path, content)


def patch_collections_service(lib_dir: Path):
    """
    Patches collections_service.dart so addToCollection and move work for local-only
    files and when signed out.
    """
    candidates = list(lib_dir.rglob("collections_service.dart"))
    if not candidates:
        print("[WARN] collections_service.dart not found; skipping direct patch.")
        return

    path = candidates[0]
    content = path.read_text(encoding="utf-8")

    import_stmt = "import 'package:photos/services/local_offline_features_service.dart';\n"
    if "local_offline_features_service.dart" not in content:
        content = import_stmt + content

    # Patch addToCollection
    pattern_add = re.compile(
        r"(Future<void>\s+addToCollection\s*\(\s*int\s+collectionID\s*,\s*List<EnteFile>\s+files\s*\)\s*async\s*\{)",
        re.MULTILINE,
    )
    replacement_add = (
        r"\1\n"
        r"    if (!Configuration.instance.hasConfiguredAccount() || collectionID < 0) {\n"
        r"      await LocalOfflineFeaturesService.instance.addLocalFilesToAlbum(collectionID, files);\n"
        r"      return;\n"
        r"    }\n"
    )
    content, c1 = pattern_add.subn(replacement_add, content, count=1)

    # Patch move
    pattern_move = re.compile(
        r"(Future<void>\s+move\s*\(\s*List<EnteFile>\s+files\s*,\s*\{\s*required\s+int\s+toCollectionID\s*,\s*required\s+int\s+fromCollectionID\s*,?\s*\}\s*\)\s*async\s*\{)",
        re.MULTILINE,
    )
    replacement_move = (
        r"\1\n"
        r"    if (!Configuration.instance.hasConfiguredAccount() || toCollectionID < 0) {\n"
        r"      await LocalOfflineFeaturesService.instance.moveLocalFilesBetweenAlbums(\n"
        r"        files,\n"
        r"        fromCollectionID: fromCollectionID,\n"
        r"        toCollectionID: toCollectionID,\n"
        r"      );\n"
        r"      return;\n"
        r"    }\n"
    )
    content, c2 = pattern_move.subn(replacement_move, content, count=1)

    backup_and_write(path, content)
    print(f"[INFO] collections_service.dart patched (addToCollection={c1}, move={c2})")


def unlock_ui_account_guards(lib_dir: Path):
    """
    Finds UI files in people/, actions/, and tabs/ that hide People Naming or
    Album Move/Add actions behind Configuration.instance.hasConfiguredAccount()
    and unlocks them.
    """
    target_dirs = [
        lib_dir / "ui" / "viewer" / "people",
        lib_dir / "ui" / "viewer" / "actions",
        lib_dir / "ui" / "actions",
        lib_dir / "ui" / "tabs",
    ]
    for d in target_dirs:
        if not d.exists():
            continue
        for dart_file in d.rglob("*.dart"):
            text = dart_file.read_text(encoding="utf-8")
            if "hasConfiguredAccount()" in text:
                # Replace guard checks inside UI action sheets & people pages with true
                updated = text.replace(
                    "Configuration.instance.hasConfiguredAccount()",
                    "true /* unlocked for offline local mode */",
                )
                if updated != text:
                    backup_and_write(dart_file, updated)


def main():
    lib_dir = find_photos_lib_dir()
    print(f"Found Ente Photos lib directory at: {lib_dir}")
    create_git_branch()
    create_local_smart_album_helper(lib_dir)
    patch_person_service(lib_dir)
    patch_collections_service(lib_dir)
    unlock_ui_account_guards(lib_dir)
    print("\nDone! Run `git status` and `git diff` to inspect all applied changes.")


if __name__ == "__main__":
    main()