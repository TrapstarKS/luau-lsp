#!/usr/bin/env bash
set -euo pipefail

require_cmd() {
	command -v "$1" >/dev/null 2>&1 || {
		echo "[sync] Missing command: $1" >&2
		exit 1
	}
}

require_cmd git
require_cmd curl
require_cmd node
require_cmd jq

if [[ -n "${GH_TOKEN:-}" ]]; then
  git config --global url."https://x-access-token:${GH_TOKEN}@github.com/".insteadOf "https://github.com/"
fi

UPSTREAM_LSP_REPO="${UPSTREAM_LSP_REPO:-JohnnyMorganz/luau-lsp}"
UPSTREAM_LUAU_REPO="${UPSTREAM_LUAU_REPO:-luau-lang/luau}"
LUAU_FORK_REPO="${LUAU_FORK_REPO:?Set LUAU_FORK_REPO (ex: yourname/luau)}"
SYNC_BRANCH_PREFIX="${SYNC_BRANCH_PREFIX:-automation/sync-luau-lsp}"
BASE_BRANCH="${BASE_BRANCH:-main}"
REQUIRE_LIKE_FUNCTIONS="${REQUIRE_LIKE_FUNCTIONS:-sharedRequire}"
TARGET_TAG="${TARGET_TAG:-}"

if [[ -z "$TARGET_TAG" ]]; then
  TARGET_TAG="$(curl -fsSL "https://api.github.com/repos/${UPSTREAM_LSP_REPO}/releases/latest" | jq -r '.tag_name')"
fi

if [[ -z "$TARGET_TAG" || "$TARGET_TAG" == "null" ]]; then
  echo "[sync] Could not resolve TARGET_TAG." >&2
  exit 1
fi

if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "[sync] Run this inside your luau-lsp fork repository." >&2
  exit 1
fi

if [[ ! -f ".gitmodules" ]]; then
  echo "[sync] .gitmodules not found; this does not look like luau-lsp fork root." >&2
  exit 1
fi

if ! git remote get-url upstream >/dev/null 2>&1; then
  git remote add upstream "https://github.com/${UPSTREAM_LSP_REPO}.git"
fi

git fetch upstream --tags --prune
git fetch origin --prune

SYNC_BRANCH="${SYNC_BRANCH_PREFIX}/${TARGET_TAG}"
echo "[sync] Preparing branch: ${SYNC_BRANCH} from tag ${TARGET_TAG}"

git checkout -B "${SYNC_BRANCH}" "refs/tags/${TARGET_TAG}"
git submodule update --init --recursive

git config user.name "github-actions[bot]"
git config user.email "41898282+github-actions[bot]@users.noreply.github.com"

echo "[sync] Pointing luau submodule URL to your fork: ${LUAU_FORK_REPO}"
git config -f .gitmodules submodule.luau.url "https://github.com/${LUAU_FORK_REPO}.git"
git submodule sync --recursive luau

pushd luau >/dev/null
git config user.name "github-actions[bot]"
git config user.email "41898282+github-actions[bot]@users.noreply.github.com"

if ! git remote get-url upstream >/dev/null 2>&1; then
  git remote add upstream "https://github.com/${UPSTREAM_LUAU_REPO}.git"
fi
if ! git remote get-url origin >/dev/null 2>&1; then
  git remote add origin "https://github.com/${LUAU_FORK_REPO}.git"
fi

git fetch upstream --tags --prune
git fetch origin --prune

if [[ -n "${GH_TOKEN:-}" ]]; then
  git remote set-url origin "https://x-access-token:${GH_TOKEN}@github.com/${LUAU_FORK_REPO}.git"
fi

LUAU_BRANCH="${SYNC_BRANCH_PREFIX//\//-}-luau-${TARGET_TAG}"
git checkout -B "${LUAU_BRANCH}" HEAD

node <<'NODE'
const fs = require('node:fs');
const path = 'Analysis/src/RequireTracer.cpp';
const extra = (process.env.REQUIRE_LIKE_FUNCTIONS || 'sharedRequire')
  .split(',')
  .map((s) => s.trim())
  .filter(Boolean)
  .filter((n, i, arr) => arr.indexOf(n) === i)
  .filter((n) => n !== 'require');
const names = ['require', ...extra];

let src = fs.readFileSync(path, 'utf8');
const condition = names.map((name) => `global->name == "${name}"`).join(' || ');

const before = /if\s*\(\s*global\s*&&\s*global->name\s*==\s*"require"\s*&&\s*expr->args\.size\s*>=\s*1\s*\)\s*\n\s*requireCalls\.push_back\(expr\);\n/;
if (before.test(src)) {
  src = src.replace(
    before,
    `if (global && expr->args.size >= 1 && (${condition}))\n            requireCalls.push_back(expr);\n`
  );
} else {
  const current = /if\s*\(\s*global\s*&&\s*expr->args\.size\s*>=\s*1\s*&&\s*\(([^)]+)\)\s*\)\s*\n\s*requireCalls\.push_back\(expr\);\n/;
  const match = src.match(current);
  if (!match) {
    throw new Error('Could not find require tracing condition in RequireTracer.cpp');
  }
  const existing = match[1];
  const required = names
    .map((name) => `global->name == "${name}"`)
    .filter((check) => !existing.includes(check));
  if (required.length > 0) {
    src = src.replace(current, (all) => all.replace(existing, `${existing} || ${required.join(' || ')}`));
  }
}

fs.writeFileSync(path, src, 'utf8');
console.log('[sync] Patched RequireTracer for:', names.join(', '));
NODE

if ! git diff --quiet; then
  git add Analysis/src/RequireTracer.cpp
  git commit -m "feat(require): treat ${REQUIRE_LIKE_FUNCTIONS} as require-like calls"
else
  echo "[sync] Luau submodule already patched."
fi

git push --force-with-lease origin "${LUAU_BRANCH}"
LUAU_SHA="$(git rev-parse HEAD)"
popd >/dev/null

git add .gitmodules luau

if ! git diff --cached --quiet; then
  git commit -m "chore(sync): ${TARGET_TAG} + require-like patch (${LUAU_SHA:0:8})"
else
  echo "[sync] No parent-repo changes staged."
fi

git push --force-with-lease origin "${SYNC_BRANCH}"

if [[ -n "${GH_TOKEN:-}" && -n "${GITHUB_REPOSITORY:-}" ]]; then
  echo "[sync] Attempting to create/update PR in ${GITHUB_REPOSITORY}"
  PR_TITLE="chore: sync luau-lsp ${TARGET_TAG} + sharedRequire patch"
  PR_BODY=$(
    cat <<EOB
Automated sync to upstream tag \`${TARGET_TAG}\`.

Includes:
- upstream luau-lsp tag sync
- luau submodule patch to treat \`${REQUIRE_LIKE_FUNCTIONS}\` like \`require\`

Generated by \`automation/luau-lsp-fork/scripts/sync-luau-lsp-fork.sh\`.
EOB
  )

  curl -fsSL -X POST \
    -H "Authorization: Bearer ${GH_TOKEN}" \
    -H "Accept: application/vnd.github+json" \
    "https://api.github.com/repos/${GITHUB_REPOSITORY}/pulls" \
    -d "$(jq -nc --arg title "${PR_TITLE}" --arg head "${SYNC_BRANCH}" --arg base "${BASE_BRANCH}" --arg body "${PR_BODY}" '{title:$title, head:$head, base:$base, body:$body}')" \
    || echo "[sync] PR already exists or could not be created automatically."
fi

echo "[sync] Done. Branch: ${SYNC_BRANCH}"
