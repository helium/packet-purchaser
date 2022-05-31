.PHONY: compile clean test rel run docker-build docker-test docker-run docker-exec

REBAR=./rebar3

compile: src/grpc/compiled.txt
	$(REBAR) compile && $(REBAR) format

clean:
	git clean -dXfffffffffff

test:
	$(REBAR) fmt --verbose --check rebar.config
	$(REBAR) fmt --verbose --check "{src,include,test}/**/*.{hrl,erl,app.src}"
	$(REBAR) fmt --verbose --check "config/{test,sys}.{config,config.src}"
	$(REBAR) xref
	$(REBAR) eunit
	$(REBAR) ct
	$(REBAR) dialyzer

rel:
	$(REBAR) release

run:
	_build/default/rel/packet_purchaser/bin/packet_purchaser foreground

docker-build:
	docker build -f Dockerfile-CI --force-rm -t quay.io/team-helium/packet_purchaser:local .

docker-test:
	docker run --rm -it --init --name=helium_packet_purchaser_test quay.io/team-helium/packet_purchaser:local make test

docker-run: 
	docker run --rm -it --init --env-file=.env --network=host --mount "type=bind,source=$(CURDIR)/data,target=/var/data" --name=helium_packet_purchaser quay.io/team-helium/packet_purchaser:local

docker-exec: 
	docker exec -it helium_packet_purchaser _build/default/rel/packet_purchaser/bin/packet_purchaser remote_console

src/grpc/compiled.txt: config/grpc_*_gen.config
	echo "$$(date)" > src/grpc/compiled.txt
	REBAR_CONFIG="config/grpc_client_gen.config" $(REBAR) grpc gen
	REBAR_CONFIG="config/grpc_server_gen.config" $(REBAR) grpc gen
