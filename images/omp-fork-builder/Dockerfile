# omp-fork-builder — the CI image for the `rebuild` job in .gitlab-ci.yml.
#
# It mirrors the GitHub-hosted ubuntu-22.04 runner the fork-auto-rebuild
# workflow ran on before the GitLab port: same Ubuntu generation, the
# repo-pinned bun (package.json "packageManager": bun@1.4.4), a bazelisk that
# resolves the repo's .bazelversion at job time, node+npm for the darwin
# npm-leaf lookup (`npm view @oh-my-pi/pi-natives-darwin-arm64@<ver>`), and the
# small toolbelt the ported steps shell out to (git, jq, file, unzip, zip,
# python3, rcodesign deps). Everything else (bazel toolchains, the rust
# cross toolchain, Chrome for Testing, the macOS SDK) is resolved at job time
# so the image never drifts from the tag being rebuilt.
#
# amd64 only — the Talos CI cluster is amd64 (cluster table in the gitlab skill).
#
# House rules (golden-gitlab-ci.yml / vault-build-optimization):
#   - apt flows through the Nexus jammy proxies, never direct upstream
#   - release binaries are version- AND sha256-pinned
#   - layer order: apt toolbelt -> bun -> bazelisk (least to most volatile)
#   - no USER switch, no COPY — nothing to reorder for cache

FROM docker.io/library/ubuntu:22.04@sha256:9abcaffc92a5279fff3a6a41635c0800ea33e528425fb389658806476e7defde

ARG NEXUS_APT_BASE=http://nexus-nexus3.nexus.svc.cluster.local:8081/repository

# [1] system toolbelt + Chromium runtime libs. universe is required for jq on
#     jammy. The Chrome-for-Testing runtime libs (nss/atk/gbm/alsa/...) match
#     what the GH ubuntu-22.04 image preinstalled: without them the battery's
#     browser bucket cannot exec its managed Chromium and the 5s CDP probe
#     fails. build-essential covers node-gyp postinstalls the same way.
RUN rm -f /etc/apt/sources.list /etc/apt/sources.list.d/*.list /etc/apt/sources.list.d/*.sources \
    && printf '%s\n' \
      "deb ${NEXUS_APT_BASE}/apt-jammy/ jammy main universe" \
      "deb ${NEXUS_APT_BASE}/apt-jammy-updates/ jammy-updates main universe" \
      "deb ${NEXUS_APT_BASE}/apt-jammy-security/ jammy-security main universe" \
      > /etc/apt/sources.list \
    && apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
         ca-certificates curl git jq file unzip zip xz-utils python3 nodejs npm \
         build-essential cmake \
         libasound2 libatk-bridge2.0-0 libatk1.0-0 libcairo2 libcups2 \
         libdbus-1-3 libexpat1 libfontconfig1 libgbm1 libglib2.0-0 \
         libgtk-3-0 libnspr4 libnss3 libpango-1.0-0 libpangocairo-1.0-0 \
         libx11-6 libx11-xcb1 libxcb1 libxcomposite1 libxcursor1 \
         libxdamage1 libxext6 libxfixes3 libxi6 libxrandr2 libxrender1 \
         libxss1 libxtst6 \
    && rm -rf /var/lib/apt/lists/*

# [2] bun — pinned to the repo's packageManager field; bump both together.
#     Checksums: https://github.com/oven-sh/bun/releases/download/bun-v<BUN_VERSION>/SHASUMS256.txt
ARG BUN_VERSION=1.4.4
ARG BUN_SHA256=bf8ccbfb2b0b80159e0f9a6d15c55317add8077534dbc6130a3edb52fccb395c
RUN curl -fsSL --retry 3 -o /tmp/bun.zip \
      "https://github.com/oven-sh/bun/releases/download/bun-v${BUN_VERSION}/bun-linux-x64.zip" \
    && echo "${BUN_SHA256}  /tmp/bun.zip" | sha256sum -c - \
    && unzip -q /tmp/bun.zip -d /tmp/bun-out \
    && install -m 0755 /tmp/bun-out/bun-linux-x64/bun /usr/local/bin/bun \
    && ln -sf /usr/local/bin/bun /usr/local/bin/bunx \
    && rm -rf /tmp/bun.zip /tmp/bun-out \
    && bun --version

# [3] bazelisk — resolves .bazelversion (9.2.0) and downloads that bazel at
#     job time, so the image never carries a stale bazel. `--version` prints
#     bazelisk's own version without downloading bazel.
#     Checksum: <release asset>.sha256 next to the binary.
ARG BAZELISK_VERSION=v1.30.0
ARG BAZELISK_SHA256=a248ae2b2b62b5baebb748f6fba7203bff1a27e5d01b55399a8406744cb539e8
RUN curl -fsSL --retry 3 -o /usr/local/bin/bazelisk \
      "https://github.com/bazelbuild/bazelisk/releases/download/${BAZELISK_VERSION}/bazelisk-linux-amd64" \
    && echo "${BAZELISK_SHA256}  /usr/local/bin/bazelisk" | sha256sum -c - \
    && chmod +x /usr/local/bin/bazelisk \
    && bazelisk --version

ENV PATH=/usr/local/bin:${PATH} \
    BUN_INSTALL_CACHE_DIR=/root/.bun/install/cache
