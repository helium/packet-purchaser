FROM heliumsystems/builder-erlang:1

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
