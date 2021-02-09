FROM heliumsystems/builder-erlang:latest

WORKDIR /opt/packet_purchaser

ADD Makefile Makefile
ADD rebar3 rebar3
ADD rebar.config rebar.config
ADD rebar.lock rebar.lock
RUN ./rebar3 get-deps
RUN make

ADD include/ include/
ADD priv/ priv/
ADD src/ src/
ADD test/ test/
RUN make

ADD config/ config/
RUN make rel

CMD ["make", "run"]
