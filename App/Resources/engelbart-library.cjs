'use strict';

// Puts one folder in Engelbart's library, by reference: a single row of type `folder` whose `folder_path` is the
// folder. Engelbart lists what is inside a folder row live from disk (its src/main/store/folder-files.cjs), so files
// written there later show up with no further row and nothing is copied.
//
// Run by Omi Import with Engelbart's own copy of PGlite (the version that wrote the database), under Engelbart's
// Electron binary with ELECTRON_RUN_AS_NODE=1, or under node. Only while no process has the database open: PGlite is a
// single-process Postgres, and a second writer would corrupt it. The caller checks that first.
//
//   node engelbart-library.cjs <pglite package dir> <library.pglite dir> status <folder>
//   node engelbart-library.cjs <pglite package dir> <library.pglite dir> add <folder> <name>
//
// Prints one line of JSON: { ok, state: 'present' | 'absent' | 'added', id?, error? }.

const fs = require('node:fs');
const path = require('node:path');
const { randomUUID } = require('node:crypto');
const { pathToFileURL } = require('node:url');

function reply(value, code = 0) {
  process.stdout.write(JSON.stringify(value) + '\n');
  process.exit(code);
}

async function main() {
  const [pglitePackage, libraryDir, command, folderArg, nameArg] = process.argv.slice(2);
  if (!pglitePackage || !libraryDir || !['status', 'add'].includes(command) || !folderArg) {
    reply({ ok: false, error: 'usage: <pglite package> <library.pglite> status|add <folder> [name]' }, 2);
  }
  if (!fs.existsSync(path.join(libraryDir, 'PG_VERSION'))) reply({ ok: false, error: `No Engelbart library at ${libraryDir}` }, 1);
  let folder;
  try { folder = fs.realpathSync(folderArg); } catch { reply({ ok: false, error: `No folder at ${folderArg}` }, 1); }
  if (!fs.statSync(folder).isDirectory()) reply({ ok: false, error: `${folder} is not a folder` }, 1);

  const { PGlite } = await import(pathToFileURL(path.join(pglitePackage, 'dist', 'index.js')).href);
  const db = new PGlite(libraryDir);
  await db.waitReady;
  let result;
  try {
    result = await run(db, command, folder, folderArg, nameArg);
  } finally {
    await db.close(); // before exiting: the insert is on disk once close returns
  }
  reply(result, result.ok ? 0 : 1);
}

async function run(db, command, folder, folderArg, nameArg) {
  const columns = new Set((await db.query("select column_name from information_schema.columns where table_name = 'library'")).rows.map((row) => row.column_name));
  for (const column of ['id', 'name', 'type', 'folder_path', 'tags', 'source', 'categorized', 'titled']) {
    if (!columns.has(column)) return { ok: false, error: `Engelbart's library has no ${column} column; this version is not supported` };
  }
  // The same folder, however its path was written when it was added (Engelbart keeps the path it resolved).
  const rows = (await db.query("select id, folder_path from library where type = 'folder' and folder_path is not null")).rows;
  const same = rows.find((row) => {
    if (row.folder_path === folder || row.folder_path === folderArg) return true;
    try { return fs.realpathSync(row.folder_path) === folder; } catch { return false; }
  });
  if (same) return { ok: true, state: 'present', id: same.id };
  if (command === 'status') return { ok: true, state: 'absent' };

  const name = (nameArg || path.basename(folder)).slice(0, 512);
  const id = randomUUID();
  // What Engelbart's own "add a folder by path" writes (library.cjs addItem), with categorized and titled left null:
  // Engelbart then applies its current rules to the row the next time it opens the library, as it does for any row
  // from an older version.
  await db.query(
    `insert into library (id, name, type, path, url, folder_path, project_id, github_id, tags, categorized, source, titled)
     values ($1, $2, 'folder', null, null, $3, null, null, '{}', null, 'mac', null)`,
    [id, name, folder],
  );
  return { ok: true, state: 'added', id };
}

main().catch((error) => reply({ ok: false, error: String((error && error.message) || error).slice(0, 2000) }, 1));
