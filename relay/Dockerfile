# Upstream's relay (stablyai/orca cloud/apps/relay) built from a pinned commit.
# Build steps are upstream's apps/relay/Dockerfile verbatim; only the source
# fetch and the volume-ownership entrypoint are ours.
FROM node:24-alpine AS src
ARG ORCA_COMMIT=98584332a31acc0c0d60115edf03486068a35987
RUN apk add --no-cache git && mkdir /orca && cd /orca && git init -q \
 && git remote add origin https://github.com/stablyai/orca \
 && git sparse-checkout set cloud \
 && git fetch -q --depth 1 --filter=blob:none origin "$ORCA_COMMIT" && git checkout -q FETCH_HEAD

FROM node:24-alpine AS build
WORKDIR /app
RUN corepack enable
COPY --from=src /orca/cloud/package.json /orca/cloud/pnpm-lock.yaml /orca/cloud/pnpm-workspace.yaml /orca/cloud/tsconfig.base.json ./
COPY --from=src /orca/cloud/packages/relay-contract packages/relay-contract
COPY --from=src /orca/cloud/packages/postgres-schema packages/postgres-schema
COPY --from=src /orca/cloud/apps/relay apps/relay
RUN pnpm install --frozen-lockfile --filter @orca-cloud/relay... \
 && pnpm --filter @orca-cloud/postgres-schema build && pnpm --filter @orca-cloud/relay-contract build && pnpm --filter @orca-cloud/relay build

FROM node:24-alpine
WORKDIR /app
RUN corepack enable && apk add --no-cache su-exec
ENV NODE_ENV=production PORT=8080 ORCA_RELAY_DATA_DIR=/data/relay
COPY --from=src /orca/cloud/package.json /orca/cloud/pnpm-lock.yaml /orca/cloud/pnpm-workspace.yaml ./
COPY --from=build /app/packages/relay-contract/package.json packages/relay-contract/package.json
COPY --from=build /app/packages/postgres-schema/package.json packages/postgres-schema/package.json
COPY --from=build /app/apps/relay/package.json apps/relay/package.json
COPY --from=build /app/packages/relay-contract/dist packages/relay-contract/dist
COPY --from=build /app/packages/postgres-schema/dist packages/postgres-schema/dist
COPY --from=build /app/apps/relay/dist apps/relay/dist
RUN pnpm install --prod --frozen-lockfile --filter @orca-cloud/relay...
EXPOSE 8080
# Railway volumes mount root-owned; upstream runs as `node`.
CMD ["sh", "-c", "mkdir -p \"$ORCA_RELAY_DATA_DIR\" && chown -R node:node \"$ORCA_RELAY_DATA_DIR\" && exec su-exec node node apps/relay/dist/index.js"]
