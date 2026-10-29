# The tick budget harness (VMC-081c) in a Linux container, to run with
# `--cpus=2` as a stand-in for the two-vCPU host:
#
#   docker build -f bench/tick_budget.Dockerfile --build-arg REVISION=$(git rev-parse HEAD) -t valimc-bench .
#   docker run --rm --cpus=2 -v "$PWD/.local/tick-budget:/app/.local/tick-budget" valimc-bench \
#     mix run bench/tick_budget.exs run TEMPLATE OUTPUT explore
#
# It builds the working tree as copied (uncommitted changes included).
ARG ELIXIR_VERSION=1.20.4
ARG OTP_VERSION=29.1.1
ARG DEBIAN_VERSION=trixie-20261005-slim

FROM docker.io/hexpm/elixir:${ELIXIR_VERSION}-erlang-${OTP_VERSION}-debian-${DEBIAN_VERSION}

ARG CARGO_BUILD_JOBS=8
ENV CARGO_BUILD_JOBS=${CARGO_BUILD_JOBS}

RUN apt-get update \
  && apt-get install -y --no-install-recommends build-essential ca-certificates curl git \
  && rm -rf /var/lib/apt/lists/*

ENV PATH="/root/.cargo/bin:${PATH}"
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs -o /tmp/rustup-init.sh \
  && sh /tmp/rustup-init.sh -y --profile minimal --default-toolchain stable --no-modify-path \
  && rm /tmp/rustup-init.sh

WORKDIR /app
RUN mix local.hex --force && mix local.rebar --force
ENV MIX_ENV="bench"

COPY mix.exs mix.lock ./
RUN mix deps.get
COPY config config
RUN mix deps.compile

COPY priv priv
COPY native native
COPY lib lib
RUN mix compile

COPY bench bench
ARG REVISION=unknown
ENV HARNESS_REVISION=${REVISION}
