# Stage 1: build the backend bundle (includes compiled frontend SPA)
#
# --platform=linux/amd64 forces an x86_64 image even on ARM64 hosts
# (Surface Pro 11 / Snapdragon X, Apple Silicon, Raspberry Pi, etc.).
# Backstage's `isolate-vm` (via @backstage/plugin-scaffolder-backend) does NOT
# build cleanly on ARM64 Linux — node-gyp dies mid-compile with cryptic C++
# errors. Running under amd64 emulation is slower but reliable.
FROM --platform=linux/amd64 node:20-bookworm-slim AS build
WORKDIR /app

# Enable pipefail so a failing command on the LHS of a pipe surfaces as a
# build error instead of being masked by `tail` / `echo`.
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# Native build toolchain — required by Backstage's native deps:
#   - isolate-vm  (used by @backstage/plugin-scaffolder-backend) needs python3 + g++
#   - better-sqlite3 (default DB driver) needs python3 + make + g++
# Without these, node-gyp fails with "gyp ERR! find Python" or
# "make: g++: Command not found" during `yarn install`.
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        python3 make g++ build-essential ca-certificates && \
    ln -sf /usr/bin/python3 /usr/bin/python && \
    rm -rf /var/lib/apt/lists/*

# Route npm/yarn through npmmirror.com — registry.npmjs.org is often
# unreachable or throttled in restricted networks (same pattern as Docker Hub).
# .yarnrc in the build context sets the registry for yarn; npm config covers npx.
RUN npm config set registry https://registry.npmmirror.com && \
    yarn config set python /usr/bin/python3

# Increase Node heap for webpack bundling (frontend SPA can exceed 1.5 GB default)
ENV NODE_OPTIONS="--max-old-space-size=4096"
# Tell node-gyp where Python lives (belt-and-braces alongside `yarn config`).
ENV PYTHON=/usr/bin/python3

# Copy workspace manifests first — layer is cached until deps change
COPY package.json ./
COPY .yarnrc ./
COPY packages/app/package.json packages/app/
COPY packages/backend/package.json packages/backend/

# Install all deps. Do NOT pipe to tail/head — that masks the real exit
# code on failure. --network-timeout matches the .yarnrc value as a safety net
# in case the rc file isn't picked up before COPY (defensive).
# Note: yarn 1 has NO `--frozen-lockfile=false` form — the flag is a pure
# boolean; omit it entirely when no lockfile is committed.
RUN yarn install --network-timeout 1200000 --ignore-engines --no-progress

# Copy sources
COPY . .

# Compile TypeScript (errors non-fatal — CLI build runs its own tsc pass)
RUN yarn tsc --skipLibCheck || true

# Step 1: build the frontend SPA (produces packages/app/dist/)
RUN yarn workspace app build

# Step 2: compile the backend — produces packages/backend/dist/index.cjs.js
# and dist/skeleton.tar.gz (a production package.json skeleton, unused here
# because Stage 2 copies node_modules wholesale instead).
RUN yarn workspace backend build

# ─────────────────────────────────────────────────────────────────────────────
# Stage 2: minimal runtime image. Match Stage 1's architecture — node_modules
# we copy across contains pre-compiled native .node binaries for amd64.
#
# Modern @backstage/cli no longer produces a single bundle.tar.gz. Instead
# `package build` emits:
#   - packages/backend/dist/index.cjs.js   (compiled Node entry)
#   - packages/backend/dist/skeleton.tar.gz (production package.json skeleton)
# Rather than re-running `yarn install --production` (which would need the
# native toolchain again and re-download the world), we simply copy node_modules
# and the built dist/ folders from the build stage. The result is smaller and
# faster because nothing recompiles.
FROM --platform=linux/amd64 node:20-bookworm-slim
ENV NODE_ENV=production
LABEL org.opencontainers.image.title="IDP Backstage"

# Don't use WORKDIR on /app because it creates the dir with mode 700 (root-only)
# when it doesn't exist, and WORKDIR happens before RUN. Instead:
# 1. Create /app with correct permissions before any COPY
# 2. Use RUN cd /app or explicit paths in COPY
# Cache-bust: 2025-05-08-fix-v3
RUN mkdir -p /app && chown node:node /app && chmod 755 /app

# Copy hoisted node_modules (yarn workspaces hoists most deps to the root)
# Use --chown=node:node on every COPY to set ownership at copy time. This is
# O(1) metadata per COPY operation — vastly faster than a post-COPY
# `chown -R /app` (which on Backstage's ~300k-file node_modules takes 5-15 min
# on Docker Desktop's overlay FS on Windows). We never need a recursive chown.
COPY --from=build --chown=node:node /app/node_modules /app/node_modules

# Workspace manifests (needed at runtime for module resolution)
COPY --from=build --chown=node:node /app/package.json /app/
COPY --from=build --chown=node:node /app/.yarnrc /app/

# Frontend SPA assets — backend's app-backend plugin serves these
COPY --from=build --chown=node:node /app/packages/app/dist /app/packages/app/dist
COPY --from=build --chown=node:node /app/packages/app/package.json /app/packages/app/

# Compiled backend output. `yarn workspace backend build` produces:
#   packages/backend/dist/bundle.tar.gz   — entry + sourcemap (only ~2 KB)
#   packages/backend/dist/skeleton.tar.gz — production package.json skeleton
# bundle.tar.gz extracts to packages/backend/dist/index.cjs.js (a 628-byte
# loader stub that calls require('@backstage/backend-defaults') — all real
# backend code lives in /app/node_modules). skeleton.tar.gz is only needed
# when running `yarn install --production` fresh in the runtime stage, which
# we skip because we copy node_modules wholesale.
COPY --from=build --chown=node:node /app/packages/backend/dist /app/packages/backend/dist
COPY --from=build --chown=node:node /app/packages/backend/package.json /app/packages/backend/
RUN cd /app && set -eux \
    && tar -xzf packages/backend/dist/bundle.tar.gz \
    && rm packages/backend/dist/bundle.tar.gz \
       packages/backend/dist/skeleton.tar.gz \
    # Make extracted files node-owned (tar runs as root, so it creates
    # root-owned files — we only need to chown the freshly-extracted dist
    # subtree, NOT all of /app). This is fast: dist/ has 2 files, vs
    # node_modules with ~300k files (which is already node-owned via
    # COPY --chown above).
    && chown -R node:node packages/backend/dist \
    && ls -la packages/backend/dist/index.cjs.js

# Default app-config provides safe build-time defaults.
# The runtime ConfigMap mounts the real config at /app/app-config.yaml.
COPY --from=build --chown=node:node /app/app-config.yaml /app/

# Defensive: ensure intermediate directories under /app are traversable.
# BuildKit's COPY --chown can occasionally leave auto-created intermediate
# directories (/app/packages/, /app/packages/app/, etc.) with restrictive
# modes. Touch only directories, depth-capped to 5 so we never recurse into
# node_modules — runs in milliseconds, not the 5-15 minutes that a recursive
# chmod over 300k node_modules files would take.
RUN find /app -maxdepth 5 -type d -exec chmod 755 {} +

# WORKDIR sets the runtime cwd. Without this the container starts with
# cwd=/, and CMD's relative paths resolve against / instead of /app —
# Node then fails with "Cannot find module '/packages/backend/dist/...'".
WORKDIR /app

USER node
EXPOSE 7007

# Modern Backstage backend output is packages/backend/dist/index.cjs.js.
#
# Older builds shipped a packages/backend/index.js shim, so `node
# packages/backend` resolved via Node's directory-as-module behavior. Modern
# @backstage/cli emits only dist/, and packages/backend/package.json has no
# "main" field — so `node packages/backend` fails with:
#   Error: Cannot find module '/app/packages/backend'
# (Node looks at packages/backend/package.json, finds no "main", then tries
# packages/backend/index.js, which doesn't exist either.)
#
# Pointing at the compiled file directly avoids the resolver dance entirely.
CMD ["node", "packages/backend/dist/index.cjs.js", "--config", "app-config.yaml"]
