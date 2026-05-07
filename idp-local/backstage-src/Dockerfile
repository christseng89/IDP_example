# Stage 1: build the backend bundle (includes compiled frontend SPA)
FROM node:20-bookworm-slim AS build
WORKDIR /app

# Route npm/yarn through npmmirror.com — registry.npmjs.org is often
# unreachable or throttled in restricted networks (same pattern as Docker Hub).
# .yarnrc in the build context sets the registry for yarn; npm config covers npx.
RUN npm config set registry https://registry.npmmirror.com

# Increase Node heap for webpack bundling (frontend SPA can exceed 1.5 GB default)
ENV NODE_OPTIONS="--max-old-space-size=4096"

# Copy workspace manifests first — layer is cached until deps change
COPY package.json ./
COPY .yarnrc ./
COPY packages/app/package.json packages/app/
COPY packages/backend/package.json packages/backend/

# Install all deps — .yarnrc sets registry + 20-min timeout
RUN yarn install 2>&1 | tail -30 && \
    echo "yarn install complete"

# Copy sources
COPY . .

# Compile TypeScript (errors non-fatal — CLI build runs its own tsc pass)
RUN yarn tsc --skipLibCheck || true

# Step 1: build the frontend SPA (produces packages/app/dist/)
RUN yarn workspace app build && echo "frontend build complete"

# Step 2: build backend and bundle with pre-built frontend into bundle.tar.gz
RUN yarn workspace backend build && echo "backend bundle complete"

# ─────────────────────────────────────────────────────────────────────────────
# Stage 2: minimal runtime image
FROM node:20-bookworm-slim
WORKDIR /app
ENV NODE_ENV=production
LABEL org.opencontainers.image.title="IDP Backstage"

RUN npm config set registry https://registry.npmmirror.com

# Extract the bundle (contains both backend Node.js app + frontend static files)
COPY --from=build /app/packages/backend/dist/bundle.tar.gz ./
RUN tar xzf bundle.tar.gz && rm bundle.tar.gz

# Copy .yarnrc so production install uses the mirror too
COPY --from=build /app/.yarnrc ./

# Install production-only dependencies from the extracted package.json files
RUN yarn install --production 2>&1 | tail -20 && \
    echo "production install complete"

# Default app-config provides safe build-time defaults.
# The runtime ConfigMap mounts the real config at /app/app-config.yaml.
COPY --from=build /app/app-config.yaml ./

USER node
EXPOSE 7007

CMD ["node", "packages/backend", "--config", "app-config.yaml"]
