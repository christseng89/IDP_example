FROM node:20-alpine AS deps
WORKDIR /app
COPY package.json .
RUN npm ci --omit=dev

FROM node:20-alpine
WORKDIR /app
COPY --from=deps /app/node_modules ./node_modules
COPY src/ ./src/
RUN addgroup -g 1000 appgroup && adduser -u 1000 -G appgroup -S appuser
USER appuser
EXPOSE 3000
ARG VERSION=v1
ENV VERSION=$VERSION
CMD ["node", "src/index.js"]
