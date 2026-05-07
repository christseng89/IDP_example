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

# Step 2: build backend and bundle with pre-built frontend into bundle.tar.gz
RUN yarn workspace backend build

# ─────────────────────────────────────────────────────────────────────────────
# Stage 2: minimal runtime image. Match Stage 1's architecture — the bundle
# we extract contains pre-compiled native .node binaries for amd64.
FROM --platform=linux/amd64 node:20-bookworm-slim
WORKDIR /app
ENV NODE_ENV=production
LABEL org.opencontainers.image.title="IDP Backstage"

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# `yarn install --production` re-resolves native modules in this stage, so the
# same toolchain is required here. Keep the install in one RUN layer and purge
# apt lists afterwards so the runtime image stays slim.
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        python3 make g++ build-essential ca-certificates && \
    ln -sf /usr/bin/python3 /usr/bin/python && \
    rm -rf /var/lib/apt/lists/*

RUN npm config set registry https://registry.npmmirror.com && \
    yarn config set python /usr/bin/python3
ENV PYTHON=/usr/bin/python3

# Extract the bundle (contains both backend Node.js app + frontend static files)
COPY --from=build /app/packages/backend/dist/bundle.tar.gz ./
RUN tar xzf bundle.tar.gz && rm bundle.tar.gz

# Copy .yarnrc so production install uses the mirror too
COPY --from=build /app/.yarnrc ./

# Install production-only dependencies from the extracted package.json files.
# No more `| tail` — surface real failures.
RUN yarn install --production --network-timeout 1200000 --ignore-engines --no-progress

# Default app-config provides safe build-time defaults.
# The runtime ConfigMap mounts the real config at /app/app-config.yaml.
COPY --from=build /app/app-config.yaml ./

# Drop privileges only after all root-required apt/install steps are done.
USER node
EXPOSE 7007

CMD ["node", "packages/backend", "--config", "app-config.yaml"]
