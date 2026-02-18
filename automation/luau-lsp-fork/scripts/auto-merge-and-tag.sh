#!/usr/bin/env bash
set -euo pipefail

require_cmd() {
	command -v "$1" >/dev/null 2>&1 || {
		echo "[auto-merge] Missing command: $1" >&2
		exit 1
	}
}

require_cmd git
require_cmd jq

set_output() {
	local key="$1"
	local value="$2"
	if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
		printf '%s=%s\n' "${key}" "${value}" >>"${GITHUB_OUTPUT}"
	fi
}

append_summary() {
	local line="$1"
	if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
		printf '%s\n' "${line}" >>"${GITHUB_STEP_SUMMARY}"
	fi
}

TARGET_TAG="${TARGET_TAG:?Set TARGET_TAG (ex: 1.62.0)}"
BASE_BRANCH="${BASE_BRANCH:-main}"
SYNC_BRANCH_PREFIX="${SYNC_BRANCH_PREFIX:-automation/sync-luau-lsp}"
PATCH_SUFFIX="${PATCH_SUFFIX:-sharedrequire}"

SYNC_BRANCH="${SYNC_BRANCH_PREFIX}/${TARGET_TAG}"
REMOTE_SYNC_REF="origin/${SYNC_BRANCH}"
REMOTE_BASE_REF="origin/${BASE_BRANCH}"

if ! git rev-parse --verify "${REMOTE_SYNC_REF}" >/dev/null 2>&1; then
	echo "[auto-merge] Sync branch not found: ${REMOTE_SYNC_REF}" >&2
	exit 1
fi

if git diff --quiet "${REMOTE_BASE_REF}".."${REMOTE_SYNC_REF}"; then
	echo "[auto-merge] No changes to merge/tag for ${SYNC_BRANCH}."
	echo "::notice::No changes to merge/tag for ${SYNC_BRANCH}."
	set_output "no_changes" "true"
	set_output "new_tag" ""
	append_summary "### Sync result"
	append_summary "- Status: no changes to merge/tag"
	append_summary "- Target tag: \`${TARGET_TAG}\`"
	append_summary "- Sync branch: \`${SYNC_BRANCH}\`"
	exit 0
fi

set_output "no_changes" "false"

echo "[auto-merge] Merging ${REMOTE_SYNC_REF} into ${BASE_BRANCH}"
git checkout "${BASE_BRANCH}"
git pull --ff-only origin "${BASE_BRANCH}"

set +e
git merge --no-edit "${REMOTE_SYNC_REF}"
MERGE_EXIT=$?
set -e

if [[ ${MERGE_EXIT} -ne 0 ]]; then
	echo "[auto-merge] Merge had conflicts, attempting luau submodule fallback."
	CONFLICTS="$(git diff --name-only --diff-filter=U || true)"
	if [[ "${CONFLICTS}" != "luau" ]]; then
		echo "[auto-merge] Conflicts are not limited to submodule 'luau':" >&2
		echo "${CONFLICTS}" >&2
		git merge --abort || true
		exit 1
	fi

	git checkout "${REMOTE_SYNC_REF}" -- luau
	git add luau
	git commit -m "chore(sync): resolve luau submodule merge for ${TARGET_TAG}"
fi

git push origin "${BASE_BRANCH}"

TAG_PREFIX="${TARGET_TAG}-${PATCH_SUFFIX}."
LAST_INDEX="$(
	git ls-remote --tags origin |
	awk -v prefix="${TAG_PREFIX}" '
		$2 ~ /refs\/tags\// {
			tag=$2
			sub("refs/tags/", "", tag)
			if (index(tag, prefix) == 1) {
				suffix=substr(tag, length(prefix)+1)
				if (suffix ~ /^[0-9]+$/) {
					if (suffix+0 > max) max=suffix+0
				}
			}
		}
		END {print max+0}
	'
)"
NEXT_INDEX=$((LAST_INDEX + 1))
NEW_TAG="${TAG_PREFIX}${NEXT_INDEX}"

echo "[auto-merge] Creating tag ${NEW_TAG}"
git tag -a "${NEW_TAG}" -m "sharedRequire patched release for ${TARGET_TAG}"
git push origin "${NEW_TAG}"
set_output "new_tag" "${NEW_TAG}"

append_summary "### Sync result"
append_summary "- Status: merged and tagged"
append_summary "- Target tag: \`${TARGET_TAG}\`"
append_summary "- Sync branch: \`${SYNC_BRANCH}\`"
append_summary "- New release tag: \`${NEW_TAG}\`"

echo "[auto-merge] Done. Merged ${SYNC_BRANCH} and pushed ${NEW_TAG}"
