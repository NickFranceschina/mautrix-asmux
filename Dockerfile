FROM docker.io/alpine:3.20

RUN apk add --no-cache \
      python3 py3-pip py3-virtualenv \
      ca-certificates \
      su-exec

# Create virtual environment
RUN python3 -m venv /opt/venv
ENV PATH="/opt/venv/bin:$PATH"

COPY requirements.txt /opt/mautrix-asmux/requirements.txt
WORKDIR /opt/mautrix-asmux

RUN apk add --no-cache --virtual .build-deps build-base python3-dev libffi-dev \
    && pip install --no-cache-dir -r requirements.txt \
    && apk del .build-deps

COPY . /opt/mautrix-asmux
RUN pip install --no-cache-dir .

ENV UID=1337 GID=1337
VOLUME /data

HEALTHCHECK --interval=30s --timeout=10s --start-period=5s --retries=3 \
    CMD wget -q -O /dev/null http://127.0.0.1:29326/_matrix/asmux/public/health || exit 1

CMD ["/opt/mautrix-asmux/docker-run.sh"]
