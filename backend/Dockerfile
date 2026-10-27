# syntax=docker/dockerfile:1

# ── base: shared by every stage ─────────────────────────────────────────────
FROM node:24-alpine AS base
WORKDIR /app
COPY package.json package-lock.json ./

# ── development: all dependencies, hot reload ───────────────────────────────
FROM base AS development
RUN npm ci
COPY . .
EXPOSE 3000
CMD ["npx", "nodemon", "--legacy-watch", "src/server.js"]

# ── production dependencies only ────────────────────────────────────────────
FROM base AS prod-deps
RUN npm ci --omit=dev

# ── production: small image, non-root user ──────────────────────────────────
FROM node:24-alpine AS production
ENV NODE_ENV=production
WORKDIR /app
COPY --from=prod-deps --chown=node:node /app/node_modules ./node_modules
COPY --chown=node:node package.json ./
COPY --chown=node:node src ./src
# Migrations ship with the image so `npm run db:migrate` works at deploy time.
# Seeds and SQL tests stay out of production.
COPY --chown=node:node db/migrations ./db/migrations
USER node
EXPOSE 3000
HEALTHCHECK --interval=30s --timeout=5s --start-period=20s --retries=3 \
  CMD node -e "fetch('http://localhost:3000/api/health').then(r => process.exit(r.ok ? 0 : 1)).catch(() => process.exit(1))"
CMD ["node", "src/server.js"]