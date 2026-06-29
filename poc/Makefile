.PHONY: preflight build up down logs clean channel contract deploy test all

preflight:
	bash scripts/preflight.sh

build: preflight
	docker compose build

up: preflight
	mkdir -p data && docker compose up -d

down:
	docker compose down

logs:
	docker compose logs -f

clean: down
	sudo rm -rf data || rm -rf data

channel:
	bash scripts/channel.sh

contract:
	docker run --rm -v $(PWD)/contracts/probe:/code \
	  -v $(PWD)/contracts/probe/.cache:/usr/local/cargo/registry \
	  cosmwasm/rust-optimizer:0.17.0

deploy:
	bash scripts/deploy.sh

test:
	bash scripts/run-all.sh

all: build up channel contract deploy test
