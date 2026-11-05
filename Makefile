SHELL := /bin/bash
export PATH := $(HOME)/.foundry/bin:$(PATH)

RPC_ANVIL ?= http://127.0.0.1:8545
ROOT := $(CURDIR)
APP_DIR := $(ROOT)/app
CONTRACTS := $(ROOT)/contracts

.PHONY: up down deploy seed publish claim-all test forge-test app-test

up:
	docker compose up -d --build
	@echo "Waiting for anvil..."
	@for i in $$(seq 1 60); do \
	  cast block-number --rpc-url $(RPC_ANVIL) >/dev/null 2>&1 && break; \
	  sleep 1; \
	done
	@cast block-number --rpc-url $(RPC_ANVIL) >/dev/null
	@echo "Stack is up."

down:
	docker compose down -v

deploy:
	cd $(APP_DIR) && npm run deploy

seed:
	cd $(APP_DIR) && npm run seed

publish:
	cd $(APP_DIR) && npm run publish

claim-all:
	cd $(APP_DIR) && npm run claim-all

forge-test:
	cd $(CONTRACTS) && forge test -vv

app-test:
	cd $(APP_DIR) && npm test

test: forge-test app-test
