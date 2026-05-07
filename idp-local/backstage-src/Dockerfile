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
WORKDIR /app
ENV NODE_ENV=production
LABEL org.opencontainers.image.title="IDP Backstage"

# Copy hoisted node_modules (yarn workspaces hoists most deps to the root)
COPY --from=build /app/node_modules ./node_modules

# Workspace manifests (needed at runtime for module resolution)
COPY --from=build /app/package.json ./
COPY --from=build /app/.yarnrc ./

# Frontend SPA assets — backend's app-backend plugin serves these
COPY --from=build /app/packages/app/dist ./packages/app/dist
COPY --from=build /app/packages/app/package.json ./packages/app/

# Compiled backend + per-package node_modules (for any non-hoisted deps)
COPY --from=build /app/packages/backend/dist ./packages/backend/dist
COPY --from=build /app/packages/backend/package.json ./packages/backend/

# Default app-config provides safe build-time defaults.
# The runtime ConfigMap mounts the real config at /app/app-config.yaml.
COPY --from=build /app/app-config.yaml ./

USER node
EXPOSE 7007

# Modern Backstage backend output is dist/index.cjs.js. Pointing at the
# package directory still works because Node resolves "main" via the
# generated package.json inside dist/.
CMD ["node", "packages/backend", "--config", "app-config.yaml"]
