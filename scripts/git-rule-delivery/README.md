# git-rule-delivery

Proof-of-concept scripts that read detection rules straight from a git repository over git's own HTTPS protocol. They need no `git` binary, no clone and no local cache. They were written to test whether Kibana could pull prebuilt rules from git instead of Fleet.

## Requirements

- Node 22 or newer (tested on Node 24). No `npm install`: only Node built-ins are used.
- Network access to the repo. By default that's `https://github.com/elastic/detection-rules`. Only public GitHub repos have been tested; there's no auth support yet.

## Scripts

| Script | What it does | Requests |
|---|---|---|
| [`git_diff_rules.mjs`](#git_diff_rulesmjs) | Compares two commits and downloads only the rule files that changed (both sides of each edit) | 1 per changed file |
| [`git_download_rules.mjs`](#git_download_rulesmjs) | Downloads every rule file as it was at one commit | ~1 per 100 files |
| [`git_download_history.mjs`](#git_download_historymjs) | Downloads every version of every rule file from a date in the past up to now | ~1 per 100 versions |
| `git_protocol.mjs` | Shared code the other three import. Not run directly. | |

## What they have in common

- **Which files count as rules:** `*.toml` files under `rules/` and `rules_building_block/` (the `elastic/detection-rules` layout). Everything else in the repo is ignored.
- **Output files** are named `<rule_id>_<commit sha>.toml`, where `rule_id` comes from the file itself. The content is the file exactly as it is in git.
- **Commits** can be given as a full 40-character SHA or a branch name (`main`). Short SHAs don't work: the protocol only accepts full ids.
- **Options:** `--repo <url>` points at another repo. `--out <dir>` sets the output folder, which defaults to `out/` next to the script.
- **Memory report:** each script ends by printing memory use, split into:
  - `heap`: JavaScript objects;
  - `buffers`: raw bytes like downloaded data;
  - `rss`: the whole process, Node itself included.

  `heap` + `buffers` is roughly the script's own data. If Node is started with `--expose-gc`, `git_diff_rules.mjs` collects garbage before each reading.

## Simulating kibana memory constraints

All the examples below run with `node --max-old-space-size=50`. This simulates the limited memory available inside Kibana: the same work there shares one Node process with everything else Kibana does, so it can't count on much heap.

Without a cap, Node assumes it has gigabytes to spare and lets garbage pile up before collecting, so the peaks look worse than they'd be in practice. The flag only limits V8's long-lived objects (the "old space"). It doesn't cap rss or memory outside the heap. These scripts keep well under 50 MB of long-lived objects, so the cap never stops them; it just keeps the measurements realistic.

## git_diff_rules.mjs

Compares the rule files at two commits and downloads only what changed. It's useful for "what's new since the version I have?".

```sh
node git_diff_rules.mjs <from> <to> [--out <dir>] [--repo <url>]
```

What it writes for each kind of change:

| Change | Files written |
|---|---|
| added | the new file, named after `<to>` |
| modified | both sides, one named after `<from>` and one after `<to>`, so you can diff them |
| deleted | the old file, named after `<from>` (the only way to know its `rule_id`) |
| renamed (same content) | nothing |

It also writes `changes_<from>_<to>.json`, which lists every change with its status, path, `rule_id`, git blob ids and file names. It doesn't clear the output folder first.

Files are fetched one request at a time, so only one rule is in memory at once. That makes it slow for big gaps (about 0.2–0.25s per file). For thousands of changes, use `git_download_history.mjs`, which batches.

### Example: 6 commits apart

```sh
$ node --max-old-space-size=50 git_diff_rules.mjs b351c0147b514c03790b8f404f5f9017afb4542e 28a7a93c0eaa791e9548989c0c3ef3437cab8c07 --out ./out
Repo: https://github.com/elastic/detection-rules
Server capabilities: agent=git/github-f351b52fe3d7-Linux, ls-refs=unborn, fetch=shallow wait-for-done filter, server-option, object-format=sha1
From: b351c0147b514c03790b8f404f5f9017afb4542e
To:   28a7a93c0eaa791e9548989c0c3ef3437cab8c07

Listing rule files at each commit (directory listings only)...
  b351c0147b51: 2479 rule files, pack 135.2 KB
  28a7a93c0eaa: 2485 rule files, pack 135.4 KB

12 changed rule files:
  modified rules/cross-platform/privilege_escalation_setuid_setgid_bit_set_via_chmod.toml
  added    rules/integrations/cloud_defend/defense_evasion_container_image_build_inside_a_container.toml
  added    rules/integrations/cloud_defend/execution_at_scheduled_job_inside_a_container.toml
  modified rules/integrations/cloud_defend/execution_container_management_binary_launched_inside_a_container.toml
  added    rules/integrations/github/exfiltration_github_high_number_of_zip_downloads.toml
  added    rules/integrations/github/exfiltration_github_repository_transferred.toml
  added    rules/integrations/github/exfiltration_github_token_use_from_unusual_asn.toml
  added    rules/integrations/github/persistence_github_user_ssh_key_added.toml
  added    rules/integrations/kubernetes/execution_common_debug_or_base_image_pod_creation.toml
  modified rules/integrations/kubernetes/privilege_escalation_pod_created_with_hostnetwork.toml
  modified rules/integrations/kubernetes/privilege_escalation_privileged_pod_created.toml
  deleted  rules_building_block/execution_common_debug_or_base_image_pod_creation.toml

Downloading changed files one at a time into ./out
  + 8a1b0278-0f9a-487d-96bd-d4833298e87a_28a7a93c0eaa791e9548989c0c3ef3437cab8c07.toml
  + 8a1b0278-0f9a-487d-96bd-d4833298e87a_b351c0147b514c03790b8f404f5f9017afb4542e.toml
  + daa0d56b-9149-475c-8bf7-bce8a337eed8_28a7a93c0eaa791e9548989c0c3ef3437cab8c07.toml
  + 1a263a5f-8aea-4c42-a121-0defc82e0a2e_28a7a93c0eaa791e9548989c0c3ef3437cab8c07.toml
  + 6c6bb7ea-0636-44ca-b541-201478ef6b50_28a7a93c0eaa791e9548989c0c3ef3437cab8c07.toml
  + 6c6bb7ea-0636-44ca-b541-201478ef6b50_b351c0147b514c03790b8f404f5f9017afb4542e.toml
  + 0fe75796-0258-4e19-a762-26228edcc468_28a7a93c0eaa791e9548989c0c3ef3437cab8c07.toml
  + 35466375-aa84-4e8f-9021-0e99f6a57614_28a7a93c0eaa791e9548989c0c3ef3437cab8c07.toml
  + f2ecac9a-7145-4587-95bc-70c1ee0fc7ba_28a7a93c0eaa791e9548989c0c3ef3437cab8c07.toml
  + 8205043a-5fd1-4dd8-be6f-55677ffe067b_28a7a93c0eaa791e9548989c0c3ef3437cab8c07.toml
  + 93120a05-caf5-47f6-a305-e8abee463fb9_28a7a93c0eaa791e9548989c0c3ef3437cab8c07.toml
  + 12cbf709-69e8-4055-94f9-24314385c27e_28a7a93c0eaa791e9548989c0c3ef3437cab8c07.toml
  + 12cbf709-69e8-4055-94f9-24314385c27e_b351c0147b514c03790b8f404f5f9017afb4542e.toml
  + c7908cac-337a-4f38-b50d-5eeb78bdb531_28a7a93c0eaa791e9548989c0c3ef3437cab8c07.toml
  + c7908cac-337a-4f38-b50d-5eeb78bdb531_b351c0147b514c03790b8f404f5f9017afb4542e.toml
  + 93120a05-caf5-47f6-a305-e8abee463fb9_b351c0147b514c03790b8f404f5f9017afb4542e.toml

Done.
  HTTP requests:        19
  Downloaded total:     313.0 KB
    listing + diff:     271.2 KB in 1.0s
    changed files:      41.8 KB in 3.3s

Memory after each phase:
  phase                 heap   buffers       rss
  start               5.2 MB    0.1 MB   51.6 MB
  handshake           9.3 MB    0.3 MB   71.2 MB
  listing + diff     10.3 MB    1.1 MB  107.9 MB
  downloads          11.5 MB    1.6 MB  109.5 MB
  Peak rss: 109.5 MB
  heap + buffers = the script's own data. rss also counts Node itself
  (see "start") and the one-off setup of fetch() (see "handshake").
  Tip: run with --expose-gc for numbers without leftover garbage.
```

Rule `93120a05…` was moved from `rules_building_block/` to `rules/integrations/kubernetes/` *and* edited. That's why the change list shows it as a delete plus an add, and why both its versions were downloaded.

### Example: 70 commits apart

Same command, older starting point. The listing step costs the same no matter how far apart the commits are. The downloads are what grows.

```sh
$ node --max-old-space-size=50 git_diff_rules.mjs e429547dddb6b90478301e75a13cf96e598614b7 28a7a93c0eaa791e9548989c0c3ef3437cab8c07 --out ./out
Repo: https://github.com/elastic/detection-rules
Server capabilities: agent=git/github-f351b52fe3d7-Linux, ls-refs=unborn, fetch=shallow wait-for-done filter, server-option, object-format=sha1
From: e429547dddb6b90478301e75a13cf96e598614b7
To:   28a7a93c0eaa791e9548989c0c3ef3437cab8c07

Listing rule files at each commit (directory listings only)...
  e429547dddb6: 2434 rule files, pack 133.0 KB
  28a7a93c0eaa: 2485 rule files, pack 135.4 KB

273 changed rule files:
  added    rules/_deprecated/defense_evasion_ml_suspicious_windows_event_low_probability.toml
  modified rules/cross-platform/command_and_control_aws_iot_secure_tunneling_localproxy.toml
  modified rules/cross-platform/command_and_control_common_llm_endpoint.toml
  modified rules/cross-platform/command_and_control_curl_activity_auditd_llm_triage.toml
  modified rules/cross-platform/command_and_control_curl_activity_llm_triage.toml
  modified rules/cross-platform/command_and_control_curl_download_from_npm_install.toml
  modified rules/cross-platform/command_and_control_kubectl_networking_modification.toml
  …  (260 more)
  modified rules_building_block/discovery_kubectl_workload_and_cluster_discovery.toml
  modified rules_building_block/discovery_potential_memory_seeking_activity.toml
  modified rules_building_block/initial_access_potential_toolshell_exploit_attempt.toml
  deleted  rules/integrations/github/impact_github_repository_activity_from_unusual_ip.toml
  deleted  rules/integrations/problemchild/defense_evasion_ml_suspicious_windows_event_low_probability.toml
  deleted  rules_building_block/execution_common_debug_or_base_image_pod_creation.toml

Downloading changed files one at a time into ./out
  + 13e908b9-7bf0-4235-abc9-b5deb500d0ad_28a7a93c0eaa791e9548989c0c3ef3437cab8c07.toml
  + deab559f-f3ab-4ce3-b17c-8f70c4169fd6_28a7a93c0eaa791e9548989c0c3ef3437cab8c07.toml
  + deab559f-f3ab-4ce3-b17c-8f70c4169fd6_e429547dddb6b90478301e75a13cf96e598614b7.toml
  + 4ae94fc1-f08f-419f-b692-053d28219380_28a7a93c0eaa791e9548989c0c3ef3437cab8c07.toml
  + 4ae94fc1-f08f-419f-b692-053d28219380_e429547dddb6b90478301e75a13cf96e598614b7.toml
  + c3da1952-bae4-4672-aa57-2be7e6805381_28a7a93c0eaa791e9548989c0c3ef3437cab8c07.toml
  …  (477 more)
  + 035a6f21-4092-471d-9cda-9e379f459b1e_e429547dddb6b90478301e75a13cf96e598614b7.toml
  + 6e4f6446-67ca-11f0-a148-f661ea17fbcd_28a7a93c0eaa791e9548989c0c3ef3437cab8c07.toml
  + 6e4f6446-67ca-11f0-a148-f661ea17fbcd_e429547dddb6b90478301e75a13cf96e598614b7.toml
  + daf2e0e0-0bab-4672-bfa1-62db0ee5ec22_e429547dddb6b90478301e75a13cf96e598614b7.toml
  + 13e908b9-7bf0-4235-abc9-b5deb500d0ad_e429547dddb6b90478301e75a13cf96e598614b7.toml
  + 93120a05-caf5-47f6-a305-e8abee463fb9_e429547dddb6b90478301e75a13cf96e598614b7.toml

Done.
  HTTP requests:        492
  Downloaded total:     1803.5 KB
    listing + diff:     269.0 KB in 1.2s
    changed files:      1534.6 KB in 115.8s

Memory after each phase:
  phase                 heap   buffers       rss
  start               5.2 MB    0.1 MB   51.4 MB
  handshake           8.6 MB    0.3 MB   71.0 MB
  listing + diff     10.3 MB    1.1 MB  108.5 MB
  downloads          12.5 MB    2.7 MB  106.3 MB
  Peak rss: 113.3 MB
  heap + buffers = the script's own data. rss also counts Node itself
  (see "start") and the one-off setup of fetch() (see "handshake").
  Tip: run with --expose-gc for numbers without leftover garbage.
```

## git_download_rules.mjs

Downloads every rule file as it was at one commit. It's a full snapshot, the equivalent of a first install.

```sh
node git_download_rules.mjs <commit sha | branch> [--batch 100] [--out <dir>] [--repo <url>]
```

- Files are requested in batches (`--batch`, default 100): one request returns a batch of files, which are written to disk before the next batch is requested.
- **Clears the output folder first.** It only deletes the `.toml` and `.json` files there, nothing else.
- Prints a memory line per batch, measured while the batch is held. At the end it checks peak heap against a 25 MB target.

### Example: all rules at one commit

```sh
$ node --max-old-space-size=50 git_download_rules.mjs 28a7a93c0eaa791e9548989c0c3ef3437cab8c07 --out ./out
Start: heap   5.2 MB  buffers   0.1 MB  rss   51.2 MB
Repo: https://github.com/elastic/detection-rules
Commit: 28a7a93c0eaa791e9548989c0c3ef3437cab8c07

Listing rule files (directory listings only)...
  28a7a93c0eaa: 2485 rule files, pack 135.4 KB
After listing: heap  11.2 MB  buffers   1.0 MB  rss  105.0 MB

Cleared 0 old files from ./out
Downloading 2485 files in 25 batches of up to 100...

  batch  1/25   100 files  pack  142.7 KB  0.4s  heap   9.9 MB  buffers   1.8 MB  rss  107.4 MB
  batch  2/25   100 files  pack  258.0 KB  0.9s  heap   9.6 MB  buffers   3.8 MB  rss  109.6 MB
  batch  3/25   100 files  pack  241.5 KB  0.4s  heap  12.3 MB  buffers   6.4 MB  rss  110.5 MB
  batch  4/25   100 files  pack  250.4 KB  0.4s  heap  12.2 MB  buffers   6.9 MB  rss  110.8 MB
  batch  5/25   100 files  pack  279.0 KB  0.4s  heap  12.3 MB  buffers   8.4 MB  rss  111.2 MB
  batch  6/25   100 files  pack  250.7 KB  0.3s  heap  11.9 MB  buffers   4.7 MB  rss  111.5 MB
  batch  7/25   100 files  pack  277.9 KB  0.4s  heap  11.9 MB  buffers   6.8 MB  rss  111.8 MB
  …
  batch 19/25   100 files  pack  279.8 KB  0.4s  heap  10.7 MB  buffers   7.7 MB  rss  118.9 MB
  batch 20/25   100 files  pack  329.3 KB  0.4s  heap  13.1 MB  buffers  11.5 MB  rss  118.9 MB
  batch 21/25   100 files  pack  332.7 KB  0.4s  heap  11.2 MB  buffers   6.5 MB  rss  119.9 MB
  batch 22/25   100 files  pack  318.6 KB  0.5s  heap  13.7 MB  buffers  10.1 MB  rss  119.9 MB
  batch 23/25   100 files  pack  304.4 KB  0.4s  heap  10.0 MB  buffers   9.9 MB  rss  120.0 MB
  batch 24/25   100 files  pack  250.7 KB  0.4s  heap  12.2 MB  buffers  12.8 MB  rss  120.1 MB
  batch 25/25    85 files  pack   97.3 KB  0.4s  heap  10.4 MB  buffers   3.2 MB  rss  120.2 MB

Done. 2485 files written to ./out
  HTTP requests:     27
  Downloaded total:  6470.0 KB
  Time:              listing 0.8s, downloads 9.9s

Peak memory seen:
  heap      16.5 MB  (under the 25.0 MB target)
  buffers   12.8 MB
  rss       120.2 MB  (also counts Node itself and the setup of fetch())
  Peaks are sampled (every 10ms, plus after each batch), so a short spike in between can be missed.
```

## git_download_history.mjs

Downloads every version of every rule file between a date in the past and the latest commit on a branch. You get the starting snapshot plus every change since.

```sh
node git_download_history.mjs <YYYY-MM-DD> [--batch 100] [--branch main] [--out <dir>] [--repo <url>]
```

- **The date is read as UTC.** The starting point is the last commit on the branch on or before the end of that day, i.e. what the branch looked like that evening.
- **It only follows the branch's own history** (first parents). Commits that only lived on PR branches are skipped.
- **One file per distinct content**, named `<rule_id>_<commit where that content first appeared>.toml`. Files that already existed at the start are named after the start commit. A rename without edits, or a revert to an earlier version, doesn't produce a new file.
- **Clears the output folder first** (`.toml` and `.json` only). It also writes `history_<start>_<end>.json` with the start and end commits, every commit in between, and every version written (`ruleId`, `path`, `commit`, `blobId`, `file`).
- Downloads in batches like `git_download_rules.mjs`. The memory the script holds stays roughly flat however long the window is (tested from 1 week to 2 years). Peaks still grow somewhat with the window; see the table at the end of this section.

### Example: everything since 2026-11-10

```sh
$ node --max-old-space-size=50 git_download_history.mjs 2026-11-10 --out ./out
Start: heap   5.3 MB  buffers   0.1 MB  rss   51.4 MB
Repo: https://github.com/elastic/detection-rules

Fetching main history after 2026-11-11T00:00:00Z...
  history pack 150.5 KB, 247 objects (commits + trees)
  start commit pack 135.2 KB
  start: fd6c45d004e1fa7b8979add1d7661aefc42fc0a8  2026-11-10T14:06:25Z  (last commit on or before 2026-11-10)
  end:   9398c9d4f51bcb2841253cca7ebcca325e9aea71  2026-11-16T14:51:48Z  (latest on main)
  11 commits in between on main (first-parent)

2494 rule file versions: 2479 at the start point, 15 added or changed since
After listing: heap   9.2 MB  buffers   2.0 MB  rss  110.6 MB

Cleared 0 old files from ./out
Downloading 2494 versions in 25 batches of up to 100...

  batch  1/25   100 files  pack  142.7 KB  0.9s  heap  11.4 MB  buffers   3.5 MB  rss  111.3 MB
  batch  2/25   100 files  pack  258.0 KB  0.4s  heap  11.4 MB  buffers   5.5 MB  rss  112.3 MB
  batch  3/25   100 files  pack  241.7 KB  0.4s  heap  11.1 MB  buffers   4.6 MB  rss  112.8 MB
  batch  4/25   100 files  pack  250.4 KB  0.3s  heap  10.6 MB  buffers   5.8 MB  rss  113.0 MB
  batch  5/25   100 files  pack  279.0 KB  0.3s  heap  10.7 MB  buffers   7.4 MB  rss  113.6 MB
  batch  6/25   100 files  pack  250.7 KB  0.4s  heap  13.4 MB  buffers  10.0 MB  rss  113.9 MB
  batch  7/25   100 files  pack  277.9 KB  0.3s  heap  12.4 MB  buffers   5.0 MB  rss  114.3 MB
  …
  batch 19/25   100 files  pack  281.7 KB  0.4s  heap  11.2 MB  buffers   5.2 MB  rss  120.7 MB
  batch 20/25   100 files  pack  324.5 KB  0.8s  heap  13.7 MB  buffers   8.9 MB  rss  120.7 MB
  batch 21/25   100 files  pack  337.1 KB  0.4s  heap  10.3 MB  buffers   9.3 MB  rss  120.7 MB
  batch 22/25   100 files  pack  321.0 KB  0.4s  heap  12.9 MB  buffers  13.0 MB  rss  120.9 MB
  batch 23/25   100 files  pack  307.3 KB  0.3s  heap  11.4 MB  buffers   6.1 MB  rss  120.9 MB
  batch 24/25   100 files  pack  236.2 KB  0.3s  heap  13.6 MB  buffers   8.7 MB  rss  120.9 MB
  batch 25/25    94 files  pack  128.4 KB  0.3s  heap  15.4 MB  buffers  10.1 MB  rss  121.0 MB

Done. 2494 versions of 2488 rules written to ./out
  HTTP requests:     29
  Downloaded total:  6638.6 KB
  Time:              history + listing 1.6s, downloads 10.9s

Peak memory seen:
  heap      17.1 MB
  buffers   13.0 MB
  rss       123.5 MB  (also counts Node itself and the setup of fetch())
  Peaks are sampled (every 10ms, plus after each batch), so a short spike in between can be missed.
```

The files and manifest look like this:

```sh
$ ls out | head -3
000047bb-b27a-47ec-8b62-ef1a5d2c9e19_fd6c45d004e1fa7b8979add1d7661aefc42fc0a8.toml
00140285-b827-4aee-aa09-8113f58a08f3_fd6c45d004e1fa7b8979add1d7661aefc42fc0a8.toml
0022d47d-39c7-4f69-a232-4fe9dc7a3acd_fd6c45d004e1fa7b8979add1d7661aefc42fc0a8.toml
```

```json
{
  "repo": "https://github.com/elastic/detection-rules",
  "branch": "main",
  "date": "2026-11-10",
  "start": { "sha": "fd6c45d004e1fa7b8979add1d7661aefc42fc0a8", "time": "2026-11-10T14:06:25Z" },
  "end": { "sha": "9398c9d4f51bcb2841253cca7ebcca325e9aea71", "time": "2026-11-16T14:51:48Z" },
  "commits": [{ "sha": "b351c0147b514c03790b8f404f5f9017afb4542e", "time": "2026-11-11T08:30:08Z" }, …],
  "versions": [
    …,
    {
      "ruleId": "76402e4d-c462-4852-aeb9-0266e6ee2890",
      "path": "rules/integrations/github/discovery_github_credential_scanner_user_agent.toml",
      "commit": "9398c9d4f51bcb2841253cca7ebcca325e9aea71",
      "blobId": "89c2f558fe6ac62313eb74fc797d8b5de14dffe0",
      "file": "76402e4d-c462-4852-aeb9-0266e6ee2890_9398c9d4f51bcb2841253cca7ebcca325e9aea71.toml"
    }
  ]
}
```

### Example: everything since 2026-04-30 (~6 months)

```sh
$ node --max-old-space-size=50 git_download_history.mjs 2026-04-30 --out ./out
Start: heap   5.3 MB  buffers   0.1 MB  rss   51.4 MB
Repo: https://github.com/elastic/detection-rules

Fetching main history after 2026-05-01T00:00:00Z...
  history pack 1451.2 KB, 3990 objects (commits + trees)
  start commit pack 109.8 KB
  start: eb32e7a2424dd9f597917bd7d7473f8c29dde6c1  2026-04-30T21:15:40Z  (last commit on or before 2026-04-30)
  end:   9398c9d4f51bcb2841253cca7ebcca325e9aea71  2026-11-16T14:51:48Z  (latest on main)
  722 commits in between on main (first-parent)

8001 rule file versions: 1898 at the start point, 6103 added or changed since
After listing: heap  21.3 MB  buffers   4.5 MB  rss  175.0 MB

Cleared 0 old files from ./out
Downloading 8001 versions in 81 batches of up to 100...

  batch  1/81   100 files  pack  133.4 KB  0.5s  heap  25.1 MB  buffers   5.9 MB  rss  175.1 MB
  batch  2/81   100 files  pack  246.0 KB  0.5s  heap  13.5 MB  buffers   3.7 MB  rss  175.0 MB
  batch  3/81   100 files  pack  271.0 KB  0.5s  heap  16.1 MB  buffers   6.5 MB  rss  175.1 MB
  batch  4/81   100 files  pack  259.1 KB  0.6s  heap  12.4 MB  buffers   4.8 MB  rss  175.1 MB
  batch  5/81   100 files  pack  255.2 KB  0.6s  heap  15.2 MB  buffers   7.5 MB  rss  175.3 MB
  batch  6/81   100 files  pack  224.6 KB  0.5s  heap  12.6 MB  buffers   4.4 MB  rss  175.1 MB
  batch  7/81   100 files  pack  240.0 KB  0.6s  heap  15.1 MB  buffers   6.9 MB  rss  175.2 MB
  …
  batch 75/81   100 files  pack  256.0 KB  0.4s  heap  13.0 MB  buffers   2.9 MB  rss  177.2 MB
  batch 76/81   100 files  pack  257.2 KB  0.4s  heap  12.9 MB  buffers   2.9 MB  rss  177.2 MB
  batch 77/81   100 files  pack  260.6 KB  0.7s  heap  13.0 MB  buffers   3.0 MB  rss  177.2 MB
  batch 78/81   100 files  pack  282.0 KB  0.4s  heap  13.0 MB  buffers   3.3 MB  rss  177.2 MB
  batch 79/81   100 files  pack  281.8 KB  0.3s  heap  13.8 MB  buffers   5.3 MB  rss  177.2 MB
  batch 80/81   100 files  pack  239.9 KB  0.4s  heap  12.9 MB  buffers   2.8 MB  rss  177.2 MB
  batch 81/81     1 files  pack    2.8 KB  0.2s  heap  12.7 MB  buffers   2.1 MB  rss  177.5 MB

Done. 8001 versions of 2488 rules written to ./out
  HTTP requests:     85
  Downloaded total:  22287.3 KB
  Time:              history + listing 2.1s, downloads 30.6s

Peak memory seen:
  heap      25.1 MB
  buffers   17.7 MB
  rss       183.4 MB  (also counts Node itself and the setup of fetch())
  Peaks are sampled (every 10ms, plus after each batch), so a short spike in between can be missed.
```

Compared with the one-week run, the history is 10× bigger (1.45 MB vs 150 KB) and there are about 3× more versions. Peak heap went from 17 to 25 MB and peak rss from 124 to 183 MB. Most of that is short-lived garbage from unpacking the history; once the listing is done, heap drops back to 12–16 MB per batch.

Bigger windows, for scale (all with `--max-old-space-size=50`, one run each; peaks vary between runs):

| Since | Commits | Versions | Requests | Downloaded | Time | Peak heap | Peak rss |
|---|---|---|---|---|---|---|---|
| 2026-11-10 | 11 | 2,494 | 29 | 6.6 MB | ~13s | 17 MB | 124 MB |
| 2026-04-30 | 722 | 8,001 | 85 | 22.3 MB | ~33s | 25 MB | 183 MB |
| 2024-11-16 | 1,854 | 14,929 | 154 | 38.6 MB | ~59s | 27 MB | 240 MB |

## Memory recap

All runs with `--max-old-space-size=50`, one run each on macOS. Peaks vary between runs.

| Example | Peak heap | Peak rss |
|---|---|---|
| `git_diff_rules.mjs`, 6 commits apart | 11.5 MB* | 110 MB |
| `git_diff_rules.mjs`, 70 commits apart | 12.5 MB* | 113 MB |
| `git_download_rules.mjs`, all rules at one commit | 16.5 MB | 120 MB |
| `git_download_history.mjs`, 1 week | 17 MB | 124 MB |
| `git_download_history.mjs`, 6 months | 25 MB | 183 MB |
| `git_download_history.mjs`, 2 years | 27 MB | 240 MB |

\* `git_diff_rules.mjs` measures heap at the end of each phase rather than sampling peaks, so its real peak may be a little higher.

None of them come close to the 50 MB cap. Most of the rss is Node itself and the setup of `fetch()`, about 70 MB before any work starts.

## Limits

- **Reads only, public repos only.** There's no auth, and no pushing back to the repo.
- **No retries.** A dropped connection fails the whole run with `Failed: fetch failed`. This happens now and then on long history downloads (hundreds of requests); just run it again.
- **Only tested against GitHub.** Other servers need git protocol v2 and must allow `filter` (partial clone) and fetching objects by id.
- **`rule_id` is read with a simple text match,** not a TOML parser. It worked on every file in `elastic/detection-rules`, but it isn't a general TOML reader.
- **The `.toml` files are rule *source*, not what Kibana installs.** Rule `version`, `required_fields` and `related_integrations` are added by the detection-rules build. `elastic/integrations` holds the built JSON (`packages/security_detection_engine/kibana/security_rule/`), which may be a better source.
