#!/usr/bin/env node
/*
 * POC: download every version of every rule file on main between a date in
 * the past and now, over git's wire protocol. No git binary, no clone.
 *
 * Usage:
 *   node git_download_history.mjs <YYYY-MM-DD> [--batch 100] [--branch main] [--out <dir>] [--repo <url>] [--ca <pem>] [--cert <pem>] [--key <pem>] [--ssh-key <file>] [--known-hosts <file>] [--accept-new-host] [--insecure]
 *
 *   The date is read as UTC. The start point is the last commit on the branch
 *   on or before the end of that day, i.e. what main looked like that evening.
 *
 * Steps:
 *   1. Resolve the branch to its latest commit (the end point).
 *   2. One fetch for the branch's recent history: "deepen-since <date>" (only
 *      commits newer than the date) plus "filter blob:none" (commits and
 *      directory listings, no file contents).
 *   3. Walk back from the latest commit through first parents only. That is
 *      the sequence of states main actually went through; commits that only
 *      lived on PR branches are skipped. The first commit older than the date
 *      is the start point. Usually it isn't in the reply (it's just past the
 *      cut-off), so we fetch it separately.
 *   4. Compare directory listings commit by commit, oldest to newest. Every
 *      rule file blob seen for the first time is a new version. Folders whose
 *      tree id didn't change are skipped without opening them, which is what
 *      makes this cheap. The history pack stays compressed (openPack): a
 *      folder listing is only unpacked when a comparison needs it, so memory
 *      doesn't grow with the number of commits.
 *   5. Download those versions in batches (one request, N "want" lines), and
 *      save each as <rule_id>_<commit>.toml, where <commit> is the commit
 *      where that exact content first appeared. The start point's files are
 *      named after the start commit.
 *
 * "One file per distinct content": a rename without edits, or a revert back
 * to an earlier version, doesn't produce a new file because the content
 * already exists under an earlier commit. Deleted rules just stop getting
 * new versions.
 *
 * Requires Node 22+. Written on Node 24.
 */

import { mkdir, readdir, rm, writeFile } from 'node:fs/promises';
import { join } from 'node:path';
import { parseArgs } from 'node:util';
import {
  DEFAULT_REPO,
  TRANSPORT_OPTIONS,
  closeTransport,
  configureTransport,
  fetchPack,
  getCapabilities,
  isRuleFile,
  kb,
  mb,
  openPack,
  parsePack,
  parseTree,
  readRuleId,
  resolveCommit,
  stats,
} from './git_protocol.mjs';

const DAY_SECONDS = 24 * 60 * 60;

// ---------------------------------------------------------------------------
// Memory tracking
// ---------------------------------------------------------------------------
//   heap     JS objects (commit list, tree objects, version list)
//   buffers  raw bytes outside the JS heap (packs, file contents)
//   rss      everything the process uses, including Node itself
// A 10ms timer samples peaks in between the explicit readings.

const peak = { heapUsed: 0, arrayBuffers: 0, rss: 0 };

const readMemory = () => {
  const reading = process.memoryUsage();
  for (const key of Object.keys(peak)) peak[key] = Math.max(peak[key], reading[key]);
  return reading;
};

const formatMemory = ({ heapUsed, arrayBuffers, rss }) =>
  `heap ${mb(heapUsed).padStart(8)}  buffers ${mb(arrayBuffers).padStart(8)}  rss ${mb(rss).padStart(9)}`;

const sampler = setInterval(readMemory, 10);
sampler.unref();

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

const secondsToDate = (seconds) => new Date(seconds * 1000).toISOString().replace('.000Z', 'Z');

/** "2026-05-01" -> unix seconds at the end of that day (UTC). */
const endOfDay = (date) => {
  if (!/^\d{4}-\d{2}-\d{2}$/.test(date)) throw new Error(`Expected a date like 2026-05-01, got "${date}"`);
  const start = Date.parse(`${date}T00:00:00Z`) / 1000;
  if (Number.isNaN(start)) throw new Error(`Invalid date "${date}"`);
  return start + DAY_SECONDS;
};

/**
 * A commit object is text: header lines, a blank line, then the message.
 *   tree <id>
 *   parent <id>            (none for the first commit, two or more for merges)
 *   author ...
 *   committer Name <email> <unix seconds> <timezone>
 * Only the header is decoded; the message isn't needed.
 */
const parseCommit = (data) => {
  const headerEnd = data.indexOf('\n\n');
  const header = data.toString('utf8', 0, headerEnd === -1 ? data.length : headerEnd);
  return {
    tree: header.match(/^tree ([0-9a-f]{40})/m)[1],
    parents: [...header.matchAll(/^parent ([0-9a-f]{40})/gm)].map((match) => match[1]),
    time: Number(header.match(/^committer .* (\d+) [+-]\d{4}$/m)[1]),
  };
};

/** Delete the .toml and .json files this POC writes in outDir, nothing else. */
const clearOutDir = async (outDir) => {
  await mkdir(outDir, { recursive: true });
  const entries = await readdir(outDir, { withFileTypes: true });
  const ours = entries.filter((e) => e.isFile() && /\.(toml|json)$/.test(e.name));
  await Promise.all(ours.map((e) => rm(join(outDir, e.name))));
  return ours.length;
};

// ---------------------------------------------------------------------------
// Steps 2 + 3: fetch recent history and find the start commit
// ---------------------------------------------------------------------------

const fetchHistory = async ({ repoUrl, branchSha, sinceSeconds }) => {
  // Commits newer than the date, with all their directory listings.
  const pack = await fetchPack(repoUrl, [
    `want ${branchSha}`,
    `deepen-since ${sinceSeconds}`,
    'filter blob:none',
  ]);
  // Kept compressed; objects are unpacked one at a time as we ask for them.
  const historyPack = openPack(pack);
  console.log(`  history pack ${kb(pack.length)}, ${historyPack.size} objects (commits + trees)`);

  // Walk back from the tip through first parents until we pass the date.
  const commits = [];
  let sha = branchSha;
  let startSha;
  for (;;) {
    const object = historyPack.get(sha);
    if (!object) { startSha = sha; break; } // beyond the cut-off: older than the date
    const commit = parseCommit(object.data);
    if (commit.time <= sinceSeconds) { startSha = sha; break; }
    commits.push({ sha, ...commit });
    sha = commit.parents[0];
    if (!sha) throw new Error('Reached the first commit of the repo before reaching the date');
  }
  commits.reverse(); // oldest first

  // The start commit is usually just outside what came back. Fetch it on its
  // own: one commit, its directory listings, no history.
  let startPack;
  if (!historyPack.has(startSha)) {
    const startPackBytes = await fetchPack(repoUrl, [`want ${startSha}`, 'deepen 1', 'filter blob:none']);
    startPack = openPack(startPackBytes);
    console.log(`  start commit pack ${kb(startPackBytes.length)}`);
  }

  // Look an object up in whichever pack has it.
  const getObject = (id) => historyPack.get(id) ?? startPack?.get(id);
  const start = { sha: startSha, ...parseCommit(getObject(startSha).data) };

  return { getObject, start, commits };
};

// ---------------------------------------------------------------------------
// Step 4: find every distinct version of every rule file
// ---------------------------------------------------------------------------

/**
 * Compare two directory trees and call onFile(path, blobId) for every rule
 * file that is new or different in `newTreeId`. Pass oldTreeId = null to
 * report every rule file in the tree.
 *
 * The trick: a tree's id is a hash of everything inside it. If a folder has
 * the same id in both commits, nothing in it changed, so we don't open it.
 * Most commits touch a handful of files, so this only opens a few folders.
 */
const diffTrees = (getObject, oldTreeId, newTreeId, prefix, onFile) => {
  if (oldTreeId === newTreeId) return;
  const readTree = (id) => {
    const tree = getObject(id);
    if (!tree) throw new Error(`Tree ${id} missing from server reply`);
    return parseTree(tree.data);
  };

  const before = new Map(oldTreeId ? readTree(oldTreeId).map((entry) => [entry.name, entry]) : []);
  for (const entry of readTree(newTreeId)) {
    const old = before.get(entry.name);
    const path = prefix + entry.name;
    if (entry.mode === '40000') {
      diffTrees(getObject, old?.mode === '40000' ? old.id : null, entry.id, `${path}/`, onFile);
    } else if (isRuleFile(path) && old?.id !== entry.id) {
      onFile(path, entry.id);
    }
  }
};

/** Returns a Map of { blob id -> { path, commitSha } }, in order of first appearance. */
const collectVersions = ({ getObject, start, commits }) => {
  const versions = new Map();
  const record = (commitSha) => (path, blobId) => {
    if (!versions.has(blobId)) versions.set(blobId, { path, commitSha });
  };

  // Everything that existed at the start point.
  diffTrees(getObject, null, start.tree, '', record(start.sha));
  const atStart = versions.size;

  // Then whatever each commit added or changed, in order.
  let previousTree = start.tree;
  for (const commit of commits) {
    diffTrees(getObject, previousTree, commit.tree, '', record(commit.sha));
    previousTree = commit.tree;
  }
  return { versions, atStart };
};

/**
 * Fetch the history, find the start commit and collect every distinct
 * version. The packs are only reachable through getObject inside this
 * function, so they can be freed as soon as it returns, before downloading.
 */
const findVersions = async ({ repoUrl, branchSha, sinceSeconds }) => {
  const { getObject, start, commits } = await fetchHistory({ repoUrl, branchSha, sinceSeconds });
  const { versions, atStart } = collectVersions({ getObject, start, commits });
  return { start, commits, versions, atStart };
};

// ---------------------------------------------------------------------------
// Step 5: download in batches
// ---------------------------------------------------------------------------

/**
 * Fetch one batch of blobs and save them. The pack and unpacked objects go
 * out of scope when this returns, so the batch can be garbage collected.
 * rule_id is read from raw bytes (see readRuleId for why that matters).
 */
const downloadBatch = async ({ repoUrl, outDir, batch, writtenNames }) => {
  const pack = await fetchPack(repoUrl, batch.map(({ blobId }) => `want ${blobId}`));
  const objects = parsePack(pack);
  const memory = readMemory(); // the batch is fully in memory right now

  const saved = [];
  for (const { blobId, path, commitSha } of batch) {
    const blob = objects.get(blobId);
    if (!blob) throw new Error(`Blob ${blobId} (${path}) missing from server reply`);

    const ruleId = readRuleId(blob.data);
    if (!ruleId) console.warn(`  ! no rule_id in ${path} at ${commitSha.slice(0, 12)}, using file name`);
    const name = ruleId ?? path.split('/').pop().replace(/\.toml$/, '');
    const fileName = `${name}_${commitSha}.toml`;

    // Two files with the same rule_id changed in one commit would collide.
    if (writtenNames.has(fileName)) console.warn(`  ! ${fileName} written twice (${path})`);
    writtenNames.add(fileName);

    await writeFile(join(outDir, fileName), blob.data);
    saved.push({ ruleId, path, commit: commitSha, blobId, file: fileName });
  }
  return { saved, packBytes: pack.length, memory };
};

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

const main = async () => {
  const { positionals, values } = parseArgs({
    allowPositionals: true,
    options: {
      batch: { type: 'string', default: '100' },
      branch: { type: 'string', default: 'main' },
      out: { type: 'string', default: join(import.meta.dirname, 'out') },
      repo: { type: 'string', default: DEFAULT_REPO },
      ...TRANSPORT_OPTIONS,
    },
  });
  const batchSize = Number(values.batch);
  if (positionals.length !== 1 || !Number.isInteger(batchSize) || batchSize < 1) {
    console.error('Usage: node git_download_history.mjs <YYYY-MM-DD> [--batch 100] [--branch main] [--out <dir>] [--repo <url>] [--ca <pem>] [--cert <pem>] [--key <pem>] [--ssh-key <file>] [--known-hosts <file>] [--accept-new-host] [--insecure]');
    process.exit(1);
  }
  const sinceSeconds = endOfDay(positionals[0]);
  if (sinceSeconds * 1000 > Date.now()) throw new Error('The date must be in the past');
  configureTransport(values);
  const repoUrl = values.repo.replace(/\/$/, '');
  const outDir = values.out;
  const startedAt = performance.now();
  console.log(`Start: ${formatMemory(readMemory())}`);

  // 1. Handshake and the latest commit.
  console.log(`Repo: ${repoUrl}`);
  await getCapabilities(repoUrl);
  const branchSha = await resolveCommit(repoUrl, values.branch);

  // 2-4. History since the date, the start commit, and every distinct version.
  console.log(`\nFetching ${values.branch} history after ${secondsToDate(sinceSeconds)}...`);
  const { start, commits, versions, atStart } = await findVersions({ repoUrl, branchSha, sinceSeconds });
  const end = commits.at(-1) ?? start;
  const listedAt = performance.now();
  console.log(`  start: ${start.sha}  ${secondsToDate(start.time)}  (last commit on or before ${positionals[0]})`);
  console.log(`  end:   ${end.sha}  ${secondsToDate(end.time)}  (latest on ${values.branch})`);
  console.log(`  ${commits.length} commits in between on ${values.branch} (first-parent)`);
  console.log(`\n${versions.size} rule file versions: ${atStart} at the start point, ${versions.size - atStart} added or changed since`);
  console.log(`After listing: ${formatMemory(readMemory())}`);

  // 5. Download in batches.
  const all = [...versions].map(([blobId, { path, commitSha }]) => ({ blobId, path, commitSha }));
  versions.clear();
  const batches = [];
  for (let i = 0; i < all.length; i += batchSize) batches.push(all.slice(i, i + batchSize));

  const removed = await clearOutDir(outDir);
  console.log(`\nCleared ${removed} old files from ${outDir}`);
  console.log(`Downloading ${all.length} versions in ${batches.length} batches of up to ${batchSize}...\n`);

  const writtenNames = new Set();
  const manifest = [];
  for (const [index, batch] of batches.entries()) {
    const batchStart = performance.now();
    const result = await downloadBatch({ repoUrl, outDir, batch, writtenNames });
    manifest.push(...result.saved);

    const label = `batch ${String(index + 1).padStart(String(batches.length).length)}/${batches.length}`;
    const seconds = ((performance.now() - batchStart) / 1000).toFixed(1);
    console.log(`  ${label}  ${String(result.saved.length).padStart(4)} files  pack ${kb(result.packBytes).padStart(9)}  ${seconds}s  ${formatMemory(result.memory)}`);
  }

  // A summary of what was written, for whatever reads the files next.
  await writeFile(
    join(outDir, `history_${start.sha.slice(0, 12)}_${end.sha.slice(0, 12)}.json`),
    JSON.stringify({
      repo: repoUrl,
      branch: values.branch,
      date: positionals[0],
      start: { sha: start.sha, time: secondsToDate(start.time) },
      end: { sha: end.sha, time: secondsToDate(end.time) },
      commits: commits.map(({ sha, time }) => ({ sha, time: secondsToDate(time) })),
      versions: manifest,
    }, null, 2)
  );

  const doneAt = performance.now();
  clearInterval(sampler);
  readMemory();
  const distinctRules = new Set(manifest.map(({ ruleId }) => ruleId)).size;
  console.log(`
Done. ${manifest.length} versions of ${distinctRules} rules written to ${outDir}
  HTTP requests:     ${stats.requests}
  Downloaded total:  ${kb(stats.bytesDownloaded)}
  Time:              history + listing ${((listedAt - startedAt) / 1000).toFixed(1)}s, downloads ${((doneAt - listedAt) / 1000).toFixed(1)}s

Peak memory seen:
  heap      ${mb(peak.heapUsed)}
  buffers   ${mb(peak.arrayBuffers)}
  rss       ${mb(peak.rss)}  (also counts Node itself)
  Peaks are sampled (every 10ms, plus after each batch), so a short spike in between can be missed.`);
};

main().catch((error) => {
  console.error(`\nFailed: ${error.message}`);
  process.exit(1);
}).finally(closeTransport);
