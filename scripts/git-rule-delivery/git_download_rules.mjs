#!/usr/bin/env node
/*
 * POC: download every rule file at one commit, in batches, over git's wire
 * protocol. No git binary, no clone.
 *
 * Usage:
 *   node git_download_rules.mjs <commit sha | branch> [--batch 100] [--out <dir>] [--repo <url>]
 *
 * Steps:
 *   1. Handshake, and resolve a branch name to a SHA if needed.
 *   2. Fetch the commit's directory listings only (no file contents) and
 *      collect { path -> blob id } for every rule file. One request.
 *   3. Ask for the blobs in batches: one fetch request with N "want <blob id>"
 *      lines returns one packfile holding those N files. We unpack it, save
 *      each file as <rule_id>_<commit>.toml, then drop the whole batch before
 *      requesting the next. So at most one batch of files is in memory.
 *
 * Memory: a line per batch shows heap / buffers / rss measured right after the
 * batch is unpacked (when it's largest), plus peaks at the end. A target of
 * 25 MB heap is checked against the highest heap seen.
 *
 * Requires Node 22+. Written on Node 24.
 */

import { mkdir, readdir, rm, writeFile } from 'node:fs/promises';
import { join } from 'node:path';
import { parseArgs } from 'node:util';
import {
  DEFAULT_REPO,
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

const HEAP_TARGET = 25 * 1024 * 1024;

// ---------------------------------------------------------------------------
// Memory tracking
// ---------------------------------------------------------------------------
//   heap     JS objects (path maps, strings, parsed objects)
//   buffers  raw bytes outside the JS heap (packs, file contents)
//   rss      everything the process uses, including Node itself
//
// Peaks come from two places: the explicit readings below, and a timer that
// samples every 10ms in between. The timer can't run while synchronous code
// (like unpacking a batch) is busy, which is why we also measure right after
// each batch is unpacked.

const peak = { heapUsed: 0, arrayBuffers: 0, rss: 0 };

const readMemory = () => {
  const reading = process.memoryUsage();
  for (const key of Object.keys(peak)) peak[key] = Math.max(peak[key], reading[key]);
  return reading;
};

const formatMemory = ({ heapUsed, arrayBuffers, rss }) =>
  `heap ${mb(heapUsed).padStart(8)}  buffers ${mb(arrayBuffers).padStart(8)}  rss ${mb(rss).padStart(9)}`;

const sampler = setInterval(readMemory, 10);
sampler.unref(); // don't keep the process alive just for this

// ---------------------------------------------------------------------------
// Output folder
// ---------------------------------------------------------------------------

/**
 * "Clear" means delete the .toml and .json files this POC writes, nothing else.
 * Safer than wiping the whole folder in case --out points somewhere unexpected.
 */
const clearOutDir = async (outDir) => {
  await mkdir(outDir, { recursive: true });
  const entries = await readdir(outDir, { withFileTypes: true });
  const ours = entries.filter((e) => e.isFile() && /\.(toml|json)$/.test(e.name));
  await Promise.all(ours.map((e) => rm(join(outDir, e.name))));
  return ours.length;
};

// ---------------------------------------------------------------------------
// Batched download
// ---------------------------------------------------------------------------

/**
 * Fetch one batch of blobs and save them. Everything allocated here (the pack,
 * the unpacked objects, the file text) goes out of scope when this returns,
 * so the garbage collector can reclaim it before the next batch.
 */
const downloadBatch = async ({ repoUrl, commitSha, outDir, batch, seenRuleIds }) => {
  // One request, one "want" line per file.
  const pack = await fetchPack(
    repoUrl,
    batch.map(({ blobId }) => `want ${blobId}`)
  );
  const objects = parsePack(pack);
  const memory = readMemory(); // the batch is fully in memory right now

  let written = 0;
  for (const { path, blobId } of batch) {
    const blob = objects.get(blobId);
    if (!blob) throw new Error(`Blob ${blobId} (${path}) missing from server reply`);

    // Stay on raw bytes: never decode the whole file into a JS string (see readRuleId).
    const ruleId = readRuleId(blob.data);
    if (!ruleId) console.warn(`  ! no rule_id in ${path}, using file name instead`);
    if (ruleId && seenRuleIds.has(ruleId)) {
      console.warn(`  ! duplicate rule_id ${ruleId} in ${path} (overwrites ${seenRuleIds.get(ruleId)})`);
    }
    if (ruleId) seenRuleIds.set(ruleId, path);

    const name = ruleId ?? path.split('/').pop().replace(/\.toml$/, '');
    await writeFile(join(outDir, `${name}_${commitSha}.toml`), blob.data);
    written += 1;
  }
  return { written, packBytes: pack.length, memory };
};

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

const main = async () => {
  const { positionals, values } = parseArgs({
    allowPositionals: true,
    options: {
      batch: { type: 'string', default: '100' },
      out: { type: 'string', default: join(import.meta.dirname, 'out') },
      repo: { type: 'string', default: DEFAULT_REPO },
    },
  });
  const batchSize = Number(values.batch);
  if (positionals.length !== 1 || !Number.isInteger(batchSize) || batchSize < 1) {
    console.error('Usage: node git_download_rules.mjs <commit sha | branch> [--batch 100] [--out <dir>] [--repo <url>]');
    process.exit(1);
  }
  const repoUrl = values.repo.replace(/\/$/, '');
  const outDir = values.out;
  const startedAt = performance.now();
  console.log(`Start: ${formatMemory(readMemory())}`);

  // 1. Handshake + resolve
  console.log(`Repo: ${repoUrl}`);
  await getCapabilities(repoUrl);
  const commitSha = await resolveCommit(repoUrl, positionals[0]);
  console.log(`Commit: ${commitSha}`);

  // 2. List rule files (no contents)
  console.log('\nListing rule files (directory listings only)...');
  const files = await listRuleFiles(repoUrl, commitSha);
  console.log(`After listing: ${formatMemory(readMemory())}`);

  // Split into batches of { path, blobId }.
  const all = [...files].map(([path, blobId]) => ({ path, blobId }));
  const batches = [];
  for (let i = 0; i < all.length; i += batchSize) batches.push(all.slice(i, i + batchSize));

  const removed = await clearOutDir(outDir);
  console.log(`\nCleared ${removed} old files from ${outDir}`);
  console.log(`Downloading ${all.length} files in ${batches.length} batches of up to ${batchSize}...\n`);

  // 3. Download batch by batch. Memory is shown as it was with the batch loaded.
  const listedAt = performance.now();
  const seenRuleIds = new Map();
  let written = 0;
  for (const [index, batch] of batches.entries()) {
    const batchStart = performance.now();
    const result = await downloadBatch({ repoUrl, commitSha, outDir, batch, seenRuleIds });
    written += result.written;

    const label = `batch ${String(index + 1).padStart(String(batches.length).length)}/${batches.length}`;
    const seconds = ((performance.now() - batchStart) / 1000).toFixed(1);
    console.log(`  ${label}  ${String(result.written).padStart(4)} files  pack ${kb(result.packBytes).padStart(9)}  ${seconds}s  ${formatMemory(result.memory)}`);
  }
  const doneAt = performance.now();
  clearInterval(sampler);
  readMemory();

  const heapVerdict = peak.heapUsed <= HEAP_TARGET ? 'under' : 'OVER';
  console.log(`
Done. ${written} files written to ${outDir}
  HTTP requests:     ${stats.requests}
  Downloaded total:  ${kb(stats.bytesDownloaded)}
  Time:              listing ${((listedAt - startedAt) / 1000).toFixed(1)}s, downloads ${((doneAt - listedAt) / 1000).toFixed(1)}s

Peak memory seen:
  heap      ${mb(peak.heapUsed)}  (${heapVerdict} the ${mb(HEAP_TARGET)} target)
  buffers   ${mb(peak.arrayBuffers)}
  rss       ${mb(peak.rss)}  (also counts Node itself and the setup of fetch())
  Peaks are sampled (every 10ms, plus after each batch), so a short spike in between can be missed.`);
};

main().catch((error) => {
  console.error(`\nFailed: ${error.message}`);
  process.exit(1);
});
