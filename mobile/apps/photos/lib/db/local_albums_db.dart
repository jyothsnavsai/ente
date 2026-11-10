import "package:photos/db/common/base.dart";
import "package:sqlite_async/sqlite_async.dart";

class LocalAlbum {
  const LocalAlbum({
    required this.id,
    required this.name,
    required this.createdAt,
  });

  final int id;
  final String name;
  final int createdAt;
}

class LocalAlbumsDB with SqlDbBase {
  static const _databaseName = "ente.local_albums.db";
  static const albumsTable = "local_albums";
  static const albumFilesTable = "local_album_files";

  static final _initialScript = [
    '''
      CREATE TABLE $albumsTable (
        id INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL,
        name TEXT NOT NULL,
        created_at INTEGER NOT NULL
      );
    ''',
    '''
      CREATE TABLE $albumFilesTable (
        album_id INTEGER NOT NULL,
        local_id TEXT NOT NULL,
        PRIMARY KEY (album_id, local_id)
      );
    ''',
    '''
      CREATE INDEX local_album_files_local_id_index
      ON $albumFilesTable(local_id);
    ''',
  ];

  LocalAlbumsDB._privateConstructor();

  static final instance = LocalAlbumsDB._privateConstructor();

  Future<SqliteDatabase> get database => getOrOpenDatabase(
    () => openMigratedDatabase(_databaseName, _initialScript),
  );

  Future<LocalAlbum> createAlbum(String name) async {
    final db = await database;
    final createdAt = DateTime.now().millisecondsSinceEpoch;
    final rows = await db.execute(
      "INSERT INTO $albumsTable (name, created_at) VALUES (?, ?) RETURNING id",
      [name, createdAt],
    );
    return LocalAlbum(
      id: rows.single["id"] as int,
      name: name,
      createdAt: createdAt,
    );
  }

  Future<List<LocalAlbum>> getAlbums() async {
    final db = await database;
    final rows = await db.getAll(
      "SELECT id, name, created_at FROM $albumsTable ORDER BY name COLLATE NOCASE",
    );
    return rows
        .map(
          (row) => LocalAlbum(
            id: row["id"] as int,
            name: row["name"] as String,
            createdAt: row["created_at"] as int,
          ),
        )
        .toList();
  }

  Future<void> renameAlbum(int albumID, String name) async {
    final db = await database;
    await db.execute("UPDATE $albumsTable SET name = ? WHERE id = ?", [
      name,
      albumID,
    ]);
  }

  Future<void> deleteAlbum(int albumID) async {
    final db = await database;
    await db.writeTransaction((tx) async {
      await tx.execute("DELETE FROM $albumFilesTable WHERE album_id = ?", [
        albumID,
      ]);
      await tx.execute("DELETE FROM $albumsTable WHERE id = ?", [albumID]);
    });
  }

  Future<void> addFiles(int albumID, Iterable<String> localIDs) async {
    final db = await database;
    final uniqueLocalIDs = localIDs.toSet();
    if (uniqueLocalIDs.isEmpty) return;
    await db.executeBatch(
      "INSERT OR IGNORE INTO $albumFilesTable (album_id, local_id) VALUES (?, ?)",
      [
        for (final localID in uniqueLocalIDs) [albumID, localID],
      ],
    );
  }

  Future<void> removeFiles(int albumID, Iterable<String> localIDs) async {
    final db = await database;
    final uniqueLocalIDs = localIDs.toSet();
    if (uniqueLocalIDs.isEmpty) return;
    await db.executeBatch(
      "DELETE FROM $albumFilesTable WHERE album_id = ? AND local_id = ?",
      [
        for (final localID in uniqueLocalIDs) [albumID, localID],
      ],
    );
  }

  Future<List<String>> getLocalIDs(int albumID) async {
    final db = await database;
    final rows = await db.getAll(
      "SELECT local_id FROM $albumFilesTable WHERE album_id = ? ORDER BY local_id",
      [albumID],
    );
    return rows.map((row) => row["local_id"] as String).toList();
  }
}
