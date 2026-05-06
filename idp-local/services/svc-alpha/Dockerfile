ARG BASE_IMAGE=node:20-alpine
FROM ${BASE_IMAGE} AS deps
WORKDIR /app
COPY package*.json ./
RUN npm ci --omit=dev

FROM ${BASE_IMAGE}
WORKDIR /app
COPY --from=deps /app/node_modules ./node_modules
COPY src/ ./src/
USER node
EXPOSE 3000
ARG VERSION=v1
ENV VERSION=$VERSION
CMD ["node", "src/index.js"]
