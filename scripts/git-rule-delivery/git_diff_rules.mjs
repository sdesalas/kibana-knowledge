#!/usr/bin/env node
/*
 * POC: diff detection rules between two commits of a git repo, talking git's
 * wire protocol directly over HTTPS or SSH. No git binary, no clone, no disk cache.
 *
 * Usage:
 *   node git_diff_rules.mjs <from> <to> [--out <dir>] [--repo <url>] [--ca <pem>] [--cert <pem>] [--key <pem>] [--ssh-key <file>] [--known-hosts <file>] [--accept-new-host] [--insecure]
 *
 *   <from>, <to>  full 40-char commit SHAs, or a branch name like "main".
 *                 Short SHAs won't work: the protocol only accepts full ids.
 *   --out         where to write rule files (default: ./out next to this script)
 *   --repo        defaults to https://github.com/elastic/detection-rules
 *
 * How it works (git protocol v2; the protocol code itself lives in git_protocol.mjs,
 * the SSH client in ssh_transport.mjs). The steps below name the HTTPS requests;
 * over SSH the same commands go through one SSH session instead:
 *
 *   1. GET  <repo>/info/refs?service=git-upload-pack
 *        Handshake (over SSH: the greeting the server sends on connect).
 *        The server lists the commands and features it supports.
 *        We check it supports protocol v2 and the "filter" feature.
 *
 *   2. POST <repo>/git-upload-pack   command=ls-refs
 *        Only used if you pass a branch name instead of a SHA. Turns
 *        "main" into the commit SHA it currently points at.
 *
 *   3. POST <repo>/git-upload-pack   command=fetch  (once per commit)
 *        Ask for the commit with "deepen 1" (no history, just that commit)
 *        and "filter blob:none" (no file contents, just the directory
 *        listings, which git calls "trees"). The result is a small packfile
 *        holding one commit plus every tree in the repo at that commit.
 *        From the trees we build a map of { path -> blob id } for rule files.
 *
 *   4. Compare the two maps. A file's blob id is a hash of its content, so a
 *      different id means the file changed. No file content needed for this.
 *
 *   5. POST <repo>/git-upload-pack   command=fetch  (once per changed file)
 *        Ask for one blob by its id. The server returns a packfile with just
 *        that one file. We unpack it, read rule_id from it, write it to disk
 *        and drop it before asking for the next one. So only one rule file
 *        is in memory at any time.
 *
 * Requires Node 22+ (import.meta.dirname). Written on Node 24.
 */

import { mkdir, writeFile } from 'node:fs/promises';
import { join } from 'node:path';
import { parseArgs } from 'node:util';
import {
  DEFAULT_REPO,
  TRANSPORT_OPTIONS,
  closeTransport,
  configureTransport,
  fetchPack,
  getCapabilities,
  kb,
  listRuleFiles,
  mb,
  parsePack,
  readRuleId,
  resolveCommit,
  stats,
} from './git_protocol.mjs';

// ---------------------------------------------------------------------------
// Memory reporting
// ---------------------------------------------------------------------------
//   heap     JS objects the script created (path maps, strings, parsed trees)
//   buffers  raw bytes held outside the JS heap (downloaded packs, file contents)
//   rss      everything the OS has given the process, including Node itself
// heap + buffers is roughly "the script's own data". rss is mostly Node.
// With --expose-gc, garbage is collected before each reading, so the numbers
// show what's actually still held rather than what just hasn't been freed yet.

const memorySnapshots = [];
const recordMemory = (phase) => {
  globalThis.gc?.();
  const { heapUsed, arrayBuffers, rss } = process.memoryUsage();
  memorySnapshots.push({ phase, heapUsed, arrayBuffers, rss });
};

const printMemory = () => {
  console.log('\nMemory after each phase:');
  console.log(`  ${'phase'.padEnd(16)}${'heap'.padStart(10)}${'buffers'.padStart(10)}${'rss'.padStart(10)}`);
  for (const { phase, heapUsed, arrayBuffers, rss } of memorySnapshots) {
    console.log(`  ${phase.padEnd(16)}${mb(heapUsed).padStart(10)}${mb(arrayBuffers).padStart(10)}${mb(rss).padStart(10)}`);
  }
  // maxRSS is the highest rss reached at any point, reported by Node in KB.
  console.log(`  Peak rss: ${mb(process.resourceUsage().maxRSS * 1024)}`);
  console.log('  heap + buffers = the script\'s own data. rss also counts Node itself');
  console.log('  (see "start").');
  if (!globalThis.gc) console.log('  Tip: run with --expose-gc for numbers without leftover garbage.');
};

// ---------------------------------------------------------------------------
// Compare the two file lists
// ---------------------------------------------------------------------------

const diffFileLists = (fromFiles, toFiles) => {
  const changes = [];
  for (const [path, toId] of toFiles) {
    const fromId = fromFiles.get(path);
    if (!fromId) changes.push({ status: 'added', path, toId });
    else if (fromId !== toId) changes.push({ status: 'modified', path, fromId, toId });
  }
  for (const [path, fromId] of fromFiles) {
    if (!toFiles.has(path)) changes.push({ status: 'deleted', path, fromId });
  }

  // A file moved without edits keeps its blob id. Pair those up as renames
  // so they don't show as a delete plus an add.
  const addedById = new Map(changes.filter((c) => c.status === 'added').map((c) => [c.toId, c]));
  for (const change of changes) {
    if (change.status !== 'deleted') continue;
    const added = addedById.get(change.fromId);
    if (!added) continue;
    added.status = 'renamed';
    added.fromPath = change.path;
    added.fromId = change.fromId;
    change.status = 'drop';
    addedById.delete(change.fromId);
  }
  return changes.filter((c) => c.status !== 'drop');
};

// ---------------------------------------------------------------------------
// Download one file at a time
// ---------------------------------------------------------------------------

/** Fetch a single blob by id. The reply is a packfile with just that object. */
const fetchBlob = async (repoUrl, blobId) => {
  const objects = parsePack(await fetchPack(repoUrl, [`want ${blobId}`]));
  const blob = objects.get(blobId);
  if (!blob) throw new Error(`Blob ${blobId} missing from server reply`);
  return blob.data;
};

/**
 * Download one version of a rule file and save it as <rule_id>_<commit>.toml.
 * Stays on raw bytes: decoding the whole file to a string and keeping the
 * rule_id from it would keep the whole file alive (see readRuleId).
 */
const saveRuleVersion = async ({ repoUrl, outDir, blobId, commitSha, path }) => {
  const data = await fetchBlob(repoUrl, blobId);
  const ruleId = readRuleId(data);
  if (!ruleId) console.warn(`  ! no rule_id found in ${path}, using file name instead`);

  const name = ruleId ?? path.split('/').pop().replace(/\.toml$/, '');
  const fileName = `${name}_${commitSha}.toml`;
  await writeFile(join(outDir, fileName), data);
  return { ruleId, fileName };
};

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

const main = async () => {
  const { positionals, values } = parseArgs({
    allowPositionals: true,
    options: {
      out: { type: 'string', default: join(import.meta.dirname, 'out') },
      repo: { type: 'string', default: DEFAULT_REPO },
      ...TRANSPORT_OPTIONS,
    },
  });
  if (positionals.length !== 2) {
    console.error('Usage: node git_diff_rules.mjs <from> <to> [--out <dir>] [--repo <url>] [--ca <pem>] [--cert <pem>] [--key <pem>] [--ssh-key <file>] [--known-hosts <file>] [--accept-new-host] [--insecure]');
    process.exit(1);
  }
  configureTransport(values);
  const repoUrl = values.repo.replace(/\/$/, '');
  const outDir = values.out;
  const startedAt = performance.now();
  recordMemory('start');

  console.log(`Repo: ${repoUrl}`);
  const capabilities = await getCapabilities(repoUrl);
  recordMemory('handshake');
  console.log(`Server capabilities: ${capabilities.join(', ')}`);

  const fromSha = await resolveCommit(repoUrl, positionals[0]);
  const toSha = await resolveCommit(repoUrl, positionals[1]);
  console.log(`From: ${fromSha}\nTo:   ${toSha}\n`);

  console.log('Listing rule files at each commit (directory listings only)...');
  const fromFiles = await listRuleFiles(repoUrl, fromSha);
  const toFiles = await listRuleFiles(repoUrl, toSha);
  const listedAt = performance.now();
  recordMemory('listing + diff');

  const changes = diffFileLists(fromFiles, toFiles);
  console.log(`\n${changes.length} changed rule files:`);
  for (const change of changes) {
    const from = change.fromPath ? `${change.fromPath} -> ` : '';
    console.log(`  ${change.status.padEnd(8)} ${from}${change.path}`);
  }

  // Which versions to download for each kind of change:
  //   added     -> the new file (at `to`)
  //   modified  -> both sides, so you can diff them
  //   deleted   -> the old file (at `from`), the only way to know its rule_id
  //   renamed   -> nothing: same content, so same rule_id
  await mkdir(outDir, { recursive: true });
  const bytesBeforeFiles = stats.bytesDownloaded;
  console.log(`\nDownloading changed files one at a time into ${outDir}`);

  for (const change of changes) {
    const common = { repoUrl, outDir, path: change.path };
    if (change.status === 'added' || change.status === 'modified') {
      const saved = await saveRuleVersion({ ...common, blobId: change.toId, commitSha: toSha });
      change.ruleId = saved.ruleId;
      change.toFile = saved.fileName;
      console.log(`  + ${saved.fileName}`);
    }
    if (change.status === 'modified' || change.status === 'deleted') {
      const saved = await saveRuleVersion({ ...common, blobId: change.fromId, commitSha: fromSha });
      change.ruleId ??= saved.ruleId;
      change.fromFile = saved.fileName;
      console.log(`  + ${saved.fileName}`);
    }
  }

  // A summary next to the files, for whatever reads them next.
  await writeFile(
    join(outDir, `changes_${fromSha.slice(0, 12)}_${toSha.slice(0, 12)}.json`),
    JSON.stringify({ repo: repoUrl, from: fromSha, to: toSha, changes }, null, 2)
  );

  const doneAt = performance.now();
  recordMemory('downloads');
  console.log(`
Done.
  HTTP requests:        ${stats.requests}
  Downloaded total:     ${kb(stats.bytesDownloaded)}
    listing + diff:     ${kb(bytesBeforeFiles)} in ${((listedAt - startedAt) / 1000).toFixed(1)}s
    changed files:      ${kb(stats.bytesDownloaded - bytesBeforeFiles)} in ${((doneAt - listedAt) / 1000).toFixed(1)}s`);
  printMemory();
};

main().catch((error) => {
  console.error(`\nFailed: ${error.message}`);
  process.exit(1);
}).finally(closeTransport);
