FROM node:20-bookworm-slim
RUN mkdir -p /app && chown node:node /app && chmod 755 /app
RUN mkdir -p /app/packages/backend/dist && chown -R node:node /app
CMD ["sh", "-c", "ls -ld /app /app/packages /app/packages/backend /app/packages/backend/dist"]
