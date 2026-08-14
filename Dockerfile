FROM archlinux:latest

ENV JULIA_VERSION=1.12.6 \
    JULIA_DIR=/opt/julia \
    JULIA_PROJECT=/kamila \
    TERM=xterm-256color \
    PATH=/opt/julia/bin:/usr/local/bin:$PATH \
    JULIA_PKG_PRECOMPILE_AUTO=1

RUN pacman -Syu --noconfirm \
        wget curl ca-certificates git base-devel nodejs npm \
    && wget -q https://julialang-s3.julialang.org/bin/linux/x64/1.12/julia-${JULIA_VERSION}-linux-x86_64.tar.gz \
    && mkdir -p "$JULIA_DIR" \
    && tar -C "$JULIA_DIR" -xzf julia-${JULIA_VERSION}-linux-x86_64.tar.gz \
        --strip-components=1 \
    && ln -s "$JULIA_DIR/bin/julia" /usr/local/bin/julia \
    && rm julia-${JULIA_VERSION}-linux-x86_64.tar.gz \
    && julia --version

WORKDIR /kamila

COPY . .

RUN julia --project=. -e 'using Pkg; Pkg.instantiate(); Pkg.precompile()' \
    && (cd tui && npm install --no-audit --no-fund) \
    && chmod +x bin/kamila bin/entrypoint.sh

STOPSIGNAL SIGINT

CMD ["/kamila/bin/entrypoint.sh"]