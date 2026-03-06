ARG BUILD_FROM=ghcr.io/home-assistant/aarch64-base:latest
FROM $BUILD_FROM

RUN apk add --no-cache \
    bash \
    curl \
    ffmpeg \
    psmisc \
    python3 \
    py3-pip \
    && pip3 install --no-cache-dir awscli --break-system-packages

COPY run.sh /run.sh
RUN chmod +x /run.sh

CMD ["/run.sh"]
