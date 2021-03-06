FROM heliumsystems/builder-erlang:latest

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
COPY test/utils/pp_lns.erl src/pp_lns.erl
RUN make

COPY config/ config/
RUN make rel

CMD ["make", "run"]
