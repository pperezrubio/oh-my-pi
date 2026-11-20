#!/usr/bin/env bash
# =============================================================================
# .gitlab/repair/run.sh — driver for the on-failure `repair` job
# =============================================================================
# Runs in the same pipeline as the failed `rebuild` job. The agent doctrine
# lives in doctrine.md next to this script; this file owns everything the
# agent must NOT do itself: state bounding, rebase replay, credentials,
# push, and the pipeline re-trigger.
#
# Invariants this script enforces (do not "simplify" them away — each one was
# a live incident on the GitHub side, see the header commentary of
# .github/workflows/fork-auto-rebuild.yml):
#   - the release tag is the idempotency key: repair attempts are counted per
#     fork-<version>, in the generic package registry, NOT per pipeline
#   - the rebase replay uses the merge-base as the fork point, never ~1 (the
#     stack holds several patches; --onto from ~1 would drop commits)
#   - the branch push is --force-with-lease against the SHA recorded at job
#     start, with the REMOTE-side ref name in the lease (a remote-tracking
#     nickname in the lease matches no lease and degrades to a plain push)
#   - a repair that produces no commit movement is never re-triggered: an
#     identical pipeline would just fail identically
#   - the agent gets no push credential at all; the harness pushes
set -euo pipefail

say() { printf '\033[36m[repair]\033[0m %s\n' "$*"; }
warn() { printf '\033[33m[repair WARN]\033[0m %s\n' "$*" >&2; }
die() { printf '\033[31m[repair FATAL]\033[0m %s\n' "$*" >&2; exit 1; }

UPSTREAM_REPO="can1357/oh-my-pi"
UPSTREAM_URL="https://github.com/${UPSTREAM_REPO}.git"
FIX_BRANCH="fix/local-patch-stack"
RELEASE_TAG_PREFIX="fork-"

# ---------------------------------------------------------------------------
# 0. preflight
# ---------------------------------------------------------------------------
for v in CI_PROJECT_DIR CI_PROJECT_ID CI_PIPELINE_ID CI_DEFAULT_BRANCH \
         CI_JOB_TOKEN CI_API_V4_URL FORK_GL_TOKEN LITELLM_API_KEY; do
   [ -n "${!v:-}" ] || die "required variable $v is not set"
done
for t in git bun jq curl timeout tar; do
   command -v "$t" >/dev/null 2>&1 || die "required tool $t not in the builder image"
done
[ -n "${REPAIR_MODEL:-}" ] || die "REPAIR_MODEL is not set"
[ -n "${LITELLM_BASE_URL:-}" ] || die "LITELLM_BASE_URL is not set"
REPAIR_MAX_ATTEMPTS="${REPAIR_MAX_ATTEMPTS:-3}"
REPAIR_AGENT_MAX_TIME="${REPAIR_AGENT_MAX_TIME:-35m}"
REPAIR_AGENT_MAX_COST="${REPAIR_AGENT_MAX_COST:-8}"

cd "$CI_PROJECT_DIR"
git config user.name "omp fork-repair [bot]"
git config user.email "fork-repair@users.noreply.gitlab.k8s.bvox.net"
git config core.editor true
git config advice.detachedHead false
# the agent's `git rebase --continue` must never open an interactive editor
export GIT_EDITOR=true EDITOR=true
export DEBIAN_FRONTEND=noninteractive

# ---------------------------------------------------------------------------
# 1. remotes, pre-run state, target resolution (mirrors the rebuild job)
# ---------------------------------------------------------------------------
git remote remove upstream >/dev/null 2>&1 || true
git remote add upstream "$UPSTREAM_URL"
say "fetching upstream tags"
git fetch --tags --force upstream 'refs/tags/*:refs/tags/*' >/dev/null 2>&1

say "fetching origin/$FIX_BRANCH"
git fetch origin "$FIX_BRANCH" >/dev/null 2>&1
BEFORE_SHA="$(git rev-parse FETCH_HEAD)"
say "remote stack tip at job start: $BEFORE_SHA"

say "resolving latest upstream release"
tag="$(curl -fsSL --retry 3 "https://api.github.com/repos/${UPSTREAM_REPO}/releases/latest" | jq -r '.tag_name // empty')"
[ -n "$tag" ] || die "could not resolve the latest upstream release"
grep -qE '^v[0-9]+\.[0-9]+\.[0-9]+$' <<<"$tag" || die "unexpected upstream tag '$tag'"
git rev-parse -q --verify "refs/tags/${tag}^{commit}" >/dev/null || die "tag '$tag' is not present in this checkout"
TARGET_SHA="$(git rev-parse "refs/tags/${tag}^{commit}")"
# release name and binary version must agree (upstream has re-pointed tags
# before) — same lookup the rebuild does
tree_version="$(git show "${tag}:packages/coding-agent/package.json" | jq -r '.version // empty' 2>/dev/null || true)"
[ -n "$tree_version" ] || tree_version="${tag#v}"
RELEASE_TAG="${RELEASE_TAG_PREFIX}${tree_version}"

# ---------------------------------------------------------------------------
# 2. bounded attempts — state keyed by the release tag in the package registry
# ---------------------------------------------------------------------------
STATE_URL="${CI_API_V4_URL}/projects/${CI_PROJECT_ID}/packages/generic/omp-repair/${RELEASE_TAG}/state.json"
ATTEMPTS=0
if state_json="$(curl -fsSL -H "JOB-TOKEN: ${CI_JOB_TOKEN}" "$STATE_URL" 2>/dev/null)"; then
   ATTEMPTS="$(jq -r '.attempts // 0' <<<"$state_json" 2>/dev/null || echo 0)"
fi
say "target ${tag} (${TARGET_SHA:0:12}) -> fork release ${RELEASE_TAG}; agent repairs so far: ${ATTEMPTS}/${REPAIR_MAX_ATTEMPTS}"
if [ "$ATTEMPTS" -ge "$REPAIR_MAX_ATTEMPTS" ]; then
   die "repair budget exhausted for ${RELEASE_TAG} (${ATTEMPTS} attempts). The stack needs a human: the operator notes in .github/workflows/fork-auto-rebuild.yml (header) describe the hand-rebase procedure, including the lease refname trap."
fi

# ---------------------------------------------------------------------------
# 3. failed rebuild trace + failure classification
# ---------------------------------------------------------------------------
MODE="unknown"
TRACE="/tmp/rebuild-trace.log"
EXCERPT="/tmp/trace-excerpt.txt"
: >"$TRACE"
: >"$EXCERPT"
failed_job_id="$(curl -fsSL -H "PRIVATE-TOKEN: ${FORK_GL_TOKEN}" \
   "${CI_API_V4_URL}/projects/${CI_PROJECT_ID}/pipelines/${CI_PIPELINE_ID}/jobs?per_page=100" \
   | jq -r '[.[] | select(.status == "failed")] | (map(select(.name == "rebuild")) + map(select(.name != "rebuild")))[0].id // empty')"
if [ -n "$failed_job_id" ] \
   && curl -fsSL -H "PRIVATE-TOKEN: ${FORK_GL_TOKEN}" \
         "${CI_API_V4_URL}/projects/${CI_PROJECT_ID}/jobs/${failed_job_id}/trace" -o "$TRACE" \
   && [ -s "$TRACE" ]; then
   # 0-byte traces are a known runner bug; an empty trace just degrades MODE
   if grep -qE '(^CONFLICT|error: could not apply)' "$TRACE"; then
      MODE="rebase-conflict"
   elif grep -q 'Test battery failed twice' "$TRACE"; then
      MODE="test-battery"
   elif grep -q 'missing from the built binary' "$TRACE"; then
      MODE="artifact-marker"
   elif grep -qE 'check:tools' "$TRACE"; then
      MODE="test-battery"
   fi
   tail -c 12000 "$TRACE" >"$EXCERPT"
   say "failure mode: ${MODE} (from job ${failed_job_id}, $(wc -c <"$TRACE") bytes of trace)"
else
   warn "could not fetch the failed rebuild trace; proceeding without it"
fi

# Infra/toolchain failures (missing image packages, registry or node outages)
# are not patch-stack defects and the agent has no doctrine for them: report
# by standing down without burning an agent attempt on unfixable ground.
# The pipeline is already red and visible; the attempt ledger is not consumed.
if [ "$MODE" = "unknown" ]; then
   say "no recognized patch-stack failure mode; standing down without an agent attempt"
   exit 0
fi

# ---------------------------------------------------------------------------
# 4. repair worktree + replay of the rebuild's exact rebase
# ---------------------------------------------------------------------------
WT="${CI_PROJECT_DIR}-repair"
git worktree remove --force "$WT" >/dev/null 2>&1 || true
say "preparing the repair worktree at $WT"
git worktree add -B "$FIX_BRANCH" "$WT" "$BEFORE_SHA" >/dev/null

base="$(git -C "$WT" merge-base HEAD "$TARGET_SHA")"
if [ "$base" = "$TARGET_SHA" ]; then
   say "stack already sits on ${tag}: the failure happened after a clean rebase; the worktree stands ready for a post-rebase fix"
else
   say "replaying the rebuild's rebase: git rebase --empty=drop --onto ${TARGET_SHA} ${base}"
   if git -C "$WT" rebase --empty=drop --onto "$TARGET_SHA" "$base"; then
      say "the replayed rebase completed cleanly this time; the failure was later in the job"
   else
      say "the replayed rebase stopped mid-flight (conflict); the agent must finish it"
   fi
fi
say "stack commits above ${tag}: $(git -C "$WT" rev-list --count HEAD "^${TARGET_SHA}" 2>/dev/null || echo '?')"

# ---------------------------------------------------------------------------
# 5. stage the omp agent runtime in the CLEAN checkout (never the worktree:
#    a conflicted tree must not be the code we execute)
# ---------------------------------------------------------------------------
say "bun install in the clean checkout (agent runtime)"
bun install --frozen-lockfile >/tmp/bun-install.log 2>&1 \
   || { tail -20 /tmp/bun-install.log >&2; die "bun install failed; the repair agent cannot run"; }

say "staging the linux-x64 natives addon from the version-pinned npm leaf"
OMP_VERSION="$(jq -r '.version' packages/natives/package.json)"
leaf="@oh-my-pi/pi-natives-linux-x64@${OMP_VERSION}"
# `npm view` on the exact leaf, mirroring the GH workflow's darwin staging:
# the raw registry document URL must carry the bare package name only — a
# version-suffixed name 404s (found live on pipeline 2899's repair run).
tarball="$(npm view "$leaf" dist.tarball 2>/dev/null || true)"
[ -n "$tarball" ] || die "no npm leaf ${leaf} published and no natives staged"
curl -fsSL --retry 5 -o /tmp/leaf.tgz "$tarball"
rm -rf /tmp/leaf && mkdir -p /tmp/leaf
tar -xzf /tmp/leaf.tgz -C /tmp/leaf
mkdir -p packages/natives/native
cp /tmp/leaf/package/*.node packages/natives/native/
bun scripts/stamp-native-version.ts packages/natives/native/*.node \
   || warn "stamp-native-version failed; the loader may reject the unstaged addon"
bun packages/coding-agent/src/cli.ts --version >/dev/null 2>&1 \
   || die "omp does not run from source in the clean checkout"

# ---------------------------------------------------------------------------
# 6. isolated omp agent dir: provider lane + key file (no plaintext in env)
# ---------------------------------------------------------------------------
AGENT_DIR="/tmp/omp-agent"
mkdir -p "$AGENT_DIR"
umask 077
printf '%s' "$LITELLM_API_KEY" >"$AGENT_DIR/litellm.key"
cat >"$AGENT_DIR/models.yml" <<EOF
providers:
  litellm:
    name: LiteLLM (CI repair lane)
    baseUrl: ${LITELLM_BASE_URL}
    # resolved at request time from the 0600 key file written by the harness;
    # the key never lands in this file or in the job trace
    apiKey: "!cat ${AGENT_DIR}/litellm.key"
    api: openai-completions
    models:
      - id: z-ai/glm-5.3
        name: "Z.ai GLM 5.3 (repair lane)"
        reasoning: true
        reasoningContentField: reasoning_content
        input: [text]
        contextWindow: 1000000
        maxTokens: 32768
        compat:
          supportsToolChoice: true
          supportsReasoningEffort: true
      - id: z-ai/glm-5.3-flash
        name: "Z.ai GLM 5.3 Flash (repair lane fallback)"
        reasoning: true
        reasoningContentField: reasoning_content
        input: [text]
        contextWindow: 1000000
        maxTokens: 131072
        compat:
          supportsToolChoice: true
          supportsReasoningEffort: true
EOF
umask 022
export PI_CODING_AGENT_DIR="$AGENT_DIR"

# `providers:` is the only root key the model registry reads. A provider written
# at the root is ignored without a warning and surfaces only as the agent
# dying with "Model ... not found", so prove the model resolved before the turn.
bun packages/coding-agent/src/cli.ts models --json >/tmp/omp-models.json 2>/dev/null \
   || die "the source-build omp could not list models"
jq -e --arg s "$REPAIR_MODEL" 'any(.models[]?; .selector == $s)' /tmp/omp-models.json >/dev/null \
   || die "model ${REPAIR_MODEL} did not load from ${AGENT_DIR}/models.yml"

lane_code="$(curl -s -o /tmp/litellm-models.json -w '%{http_code}' \
   -H "Authorization: Bearer $(cat "$AGENT_DIR/litellm.key")" "${LITELLM_BASE_URL}/models")"
[ "$lane_code" = "200" ] || die "LiteLLM lane unreachable (HTTP ${lane_code} at ${LITELLM_BASE_URL}/models)"
jq -e --arg m "${REPAIR_MODEL#*/}" 'any(.data[]?; .id == $m)' /tmp/litellm-models.json >/dev/null 2>&1 \
   || warn "model ${REPAIR_MODEL#*/} not listed by the lane; continuing (some proxies under-report)"

# ---------------------------------------------------------------------------
# 7. the agent turn
# ---------------------------------------------------------------------------
PROMPT="/tmp/repair-prompt.md"
cat >"$PROMPT" <<EOF
# Repair task: ${FIX_BRANCH} onto upstream ${tag}

- Upstream target: ${tag} (commit ${TARGET_SHA}). The fork release this pipeline is trying to publish: ${RELEASE_TAG}.
- Remote tip of ${FIX_BRANCH} when this job started: ${BEFORE_SHA}. The harness pushes with a lease against exactly that SHA when you finish — you never push, tag, or publish anything.
- Failure mode classified from the failed rebuild job: ${MODE}.
- Failed rebuild trace (tail): /tmp/trace-excerpt.txt — full log: /tmp/rebuild-trace.log.
- Repair attempt: $((ATTEMPTS + 1)) of ${REPAIR_MAX_ATTEMPTS} for this release tag.
- Doctrine (also appended to your system prompt): ${CI_PROJECT_DIR}/.gitlab/repair/doctrine.md.
- Canonical rebuild workflow — the ground truth for every rule the doctrine cites: ${CI_PROJECT_DIR}/.github/workflows/fork-auto-rebuild.yml.
- Your working directory is the repair worktree (${WT}), currently mid- or post-rebase. A clean checkout of the pipeline ref lives at ${CI_PROJECT_DIR} (bun install + the linux natives addon are already staged THERE, for running the omp CLI); this worktree has no node_modules — if you need to run tests, run \`bun install --frozen-lockfile\` here first.

Finish the repair according to the doctrine, then stop. The harness verifies your result, pushes, and re-triggers the pipeline; it is the retried pipeline, not you, that runs the full battery.
EOF

say "running headless omp: model=${REPAIR_MODEL} max-time=${REPAIR_AGENT_MAX_TIME} max-cost=\$${REPAIR_AGENT_MAX_COST}"
set +e
(
   cd "$WT"
   PI_CODING_AGENT_DIR="$AGENT_DIR" \
      timeout --kill-after=60 "$REPAIR_AGENT_MAX_TIME" \
      bun "${CI_PROJECT_DIR}/packages/coding-agent/src/cli.ts" -p \
      --approval-mode yolo \
      --model "$REPAIR_MODEL" \
      --max-time "$REPAIR_AGENT_MAX_TIME" \
      --max-cost "$REPAIR_AGENT_MAX_COST" \
      --no-extensions --no-skills --no-title \
      --add-dir "$CI_PROJECT_DIR" \
      --append-system-prompt "${CI_PROJECT_DIR}/.gitlab/repair/doctrine.md" \
      <"$PROMPT"
) >/tmp/agent-out.txt 2>/tmp/agent-err.txt
AGENT_RC=$?
set -e
tail -40 /tmp/agent-out.txt || true
tail -20 /tmp/agent-err.txt >&2 || true
[ "$AGENT_RC" -eq 0 ] || die "repair agent exited ${AGENT_RC} (see the job artifacts section of the trace above)"

# ---------------------------------------------------------------------------
# 8. verify the agent's result — hard gates before anything is pushed
# ---------------------------------------------------------------------------
say "verifying the repaired stack"
GITDIR="$(git -C "$WT" rev-parse --absolute-git-dir)"
if [ -e "${GITDIR}/rebase-merge" ] || [ -e "${GITDIR}/rebase-apply" ]; then
   git -C "$WT" status | head -30 >&2 || true
   die "a rebase is still in progress: the agent did not finish it"
fi
if git -C "$WT" status --porcelain | grep -qE '^(UU|AA|DD|AU|UA|DU|UD)'; then
   die "unmerged paths remain in the worktree"
fi
# untracked files (e.g. a bun install the agent ran) are fine; tracked state must be clean
if git -C "$WT" status --porcelain | grep -qv '^??'; then
   git -C "$WT" status --porcelain | head -20 >&2 || true
   die "the worktree has uncommitted tracked changes; the repair must be committed"
fi
NEW_SHA="$(git -C "$WT" rev-parse HEAD)"
git -C "$WT" merge-base --is-ancestor "$TARGET_SHA" HEAD \
   || die "repaired HEAD does not contain the target ${tag}; the stack is not on the release"
if [ "$NEW_SHA" = "$BEFORE_SHA" ]; then
   die "no progress: HEAD equals the remote tip. An identical pipeline would fail identically; refusing to push or re-trigger. If the failure is upstream's own (doctrine: stock-tag battery red), that conclusion belongs in a non-zero exit, not an empty repair."
fi
say "stack on ${tag} after repair:"
git -C "$WT" log --oneline "${tag}..HEAD"

# ---------------------------------------------------------------------------
# 9. push with the lease, count the attempt, re-trigger
# ---------------------------------------------------------------------------
if [ "${REPAIR_TEST:-0}" = "1" ]; then
   say "REPAIR_TEST=1: verification-only lane, skipping push / state / re-trigger"
   exit 0
fi

say "pushing ${FIX_BRANCH} -> ${NEW_SHA} (lease against ${BEFORE_SHA})"
# remote-side ref name in the lease — a remote-tracking nickname matches no
# lease for the pushed ref and git degrades to a plain push (probed
# 2026-11-15 on the GitHub side; same git semantics here)
git -C "$WT" push --force-with-lease="refs/heads/${FIX_BRANCH}:${BEFORE_SHA}" \
   origin "HEAD:refs/heads/${FIX_BRANCH}"

NEW_ATTEMPTS=$((ATTEMPTS + 1))
ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
printf '{"attempts": %d, "last_mode": "%s", "last_pipeline": %s, "last_push": "%s", "last_model": "%s", "updated": "%s"}\n' \
   "$NEW_ATTEMPTS" "$MODE" "$CI_PIPELINE_ID" "$NEW_SHA" "$REPAIR_MODEL" "$ts" >/tmp/state.json
# count the attempt BEFORE the re-trigger: a crash between the two must not
# buy a free extra repair on the next nightly run
curl -fsS -X PUT -H "JOB-TOKEN: ${CI_JOB_TOKEN}" \
   --data-binary @/tmp/state.json \
   "${STATE_URL}?status=message" >/dev/null \
   || warn "could not persist the attempt counter (registry PUT failed)"

say "re-triggering the pipeline on ${CI_DEFAULT_BRANCH}"
resp="$(curl -fsS -X POST -H "PRIVATE-TOKEN: ${FORK_GL_TOKEN}" \
   --data-urlencode "ref=${CI_DEFAULT_BRANCH}" \
   "${CI_API_V4_URL}/projects/${CI_PROJECT_ID}/pipeline")"
new_ref="$(jq -r '.ref // empty' <<<"$resp")"
new_url="$(jq -r '.web_url // empty' <<<"$resp")"
# an ambiguous trigger response is never auto-retried (skill rule: verify the
# ref before trusting a mutating POST's success)
[ "$new_ref" = "$CI_DEFAULT_BRANCH" ] || die "pipeline trigger returned ref '${new_ref}', expected '${CI_DEFAULT_BRANCH}' — inspect manually, do not re-POST"

say "repair complete for ${RELEASE_TAG} (attempt ${NEW_ATTEMPTS}/${REPAIR_MAX_ATTEMPTS}); re-triggered: ${new_url}"
