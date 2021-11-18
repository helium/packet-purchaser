FROM erlang:22
ENV DEBIAN_FRONTEND noninteractive
RUN apt update
RUN apt-get install -y -q \
        build-essential \
        bison \
        flex \
        git \
        gzip \
        autotools-dev \
        automake \
        libtool \
        pkg-config \
        cmake \
        libsodium-dev

RUN curl https://sh.rustup.rs -sSf | sh -s -- -y --default-toolchain stable
ENV PATH="/root/.cargo/bin:${PATH}"
RUN rustup update

WORKDIR /opt/packet_purchaser

COPY Makefile Makefile
COPY rebar3 rebar3
COPY rebar.config rebar.config
COPY rebar.lock rebar.lock
RUN ./rebar3 get-deps
RUN make

COPY include/ include/
COPY priv/ priv/
COPY src/ src/
RUN make

COPY config/ config/
RUN make rel

CMD ["make", "run"]
