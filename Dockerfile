FROM debian:bookworm-slim AS godot-download

ARG GODOT_VERSION=4.7.2
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates curl unzip \
    && rm -rf /var/lib/apt/lists/* \
    && curl -fsSL "https://godot-releases.nbg1.your-objectstorage.com/${GODOT_VERSION}-stable/Godot_v${GODOT_VERSION}-stable_linux.x86_64.zip" -o /tmp/godot.zip \
    && unzip /tmp/godot.zip -d /tmp/godot \
    && install -m 0755 /tmp/godot/Godot_v${GODOT_VERSION}-stable_linux.x86_64 /usr/local/bin/godot \
    && rm -rf /tmp/godot /tmp/godot.zip

FROM node:22-bookworm-slim
RUN apt-get update && apt-get install -y --no-install-recommends \
    libfontconfig1 libgl1 libasound2 libpulse0 libx11-6 libxcursor1 libxinerama1 libxrandr2 libxi6 libxrender1 libudev1 \
    && rm -rf /var/lib/apt/lists/* \
    && useradd --create-home --uid 10001 --shell /usr/sbin/nologin godot
COPY --from=godot-download /usr/local/bin/godot /usr/local/bin/godot
WORKDIR /app
COPY --chown=godot:godot . /app
USER godot
EXPOSE 10000
ENTRYPOINT ["node", "/app/server/render_proxy.js"]
