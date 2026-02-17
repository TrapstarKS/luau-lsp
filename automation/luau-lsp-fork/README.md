# luau-lsp Fork Automation

This folder contains a ready automation kit for maintaining a patched `luau-lsp` fork where `sharedRequire` is treated like `require` by Luau analysis.

## What this automates

- Detect latest upstream `luau-lsp` release tag.
- Create a sync branch from upstream tag.
- Patch `luau/Analysis/src/RequireTracer.cpp` to include `sharedRequire`.
- Push patched `luau` submodule branch to your Luau fork.
- Update parent `luau-lsp` fork to point to patched submodule commit.
- Push sync branch and try to open PR automatically.

## Required repositories

You need two forks:

1. `luau-lsp` fork (where this workflow runs).
2. `luau` fork (for patched submodule commits).

## Required secret (in your `luau-lsp` fork)

- `LUAU_FORK_REPO` = `owner/luau` (example: `yourname/luau`).

## Install in your luau-lsp fork

Copy these files into your `luau-lsp` fork:

- `automation/luau-lsp-fork/scripts/patch-require-tracer.mjs`
- `automation/luau-lsp-fork/scripts/sync-luau-lsp-fork.sh`
- `automation/luau-lsp-fork/workflows/sync-luau-lsp-fork.yml` -> `.github/workflows/sync-luau-lsp-fork.yml`

Make script executable:

```bash
chmod +x automation/luau-lsp-fork/scripts/sync-luau-lsp-fork.sh
```

## Manual run

From root of your `luau-lsp` fork:

```bash
export LUAU_FORK_REPO="yourname/luau"
bash automation/luau-lsp-fork/scripts/sync-luau-lsp-fork.sh
```

Optional:

```bash
TARGET_TAG="1.62.0" REQUIRE_LIKE_FUNCTIONS="sharedRequire,anotherRequireName" bash automation/luau-lsp-fork/scripts/sync-luau-lsp-fork.sh
```

## Notes

- The script is intentionally strict: if upstream structure changes, patching fails fast.
- Keep patch scope minimal to reduce merge/rebase conflicts over time.
- If a PR fails to create automatically, branch push still happens and you can open PR manually.
