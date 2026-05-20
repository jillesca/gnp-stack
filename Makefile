CONTAINER_ENGINE := $(shell command -v podman >/dev/null 2>&1 && echo podman || echo docker)
COMPOSE          := $(CONTAINER_ENGINE) compose
COMPOSE_VM       := $(COMPOSE) -f compose.yaml -f compose.override.vm.yaml

.PHONY: help up up-vm down down-vm restart restart-vm logs ps validate

help:
	@echo "Usage:"
	@echo "  make up          Laptop mode: gNMI + Prometheus + Grafana + Loki (no syslog)"
	@echo "  make up-vm       VM mode: full stack + Alloy syslog + macvlan networking"
	@echo "  make down        Stop laptop-mode stack"
	@echo "  make down-vm     Stop VM-mode stack (required if started with make up-vm)"
	@echo "  make restart     Restart laptop-mode stack"
	@echo "  make restart-vm  Restart VM-mode stack"
	@echo "  make logs        Follow logs"
	@echo "  make ps          Show running containers"
	@echo "  make validate    Check Prometheus targets"
	@echo ""
	@echo "Container engine detected: $(CONTAINER_ENGINE)"

up:
	$(COMPOSE) up -d

up-vm:
	$(COMPOSE_VM) up -d

down:
	$(COMPOSE) down

down-vm:
	$(COMPOSE_VM) down

restart: down up

restart-vm: down-vm up-vm

logs:
	$(COMPOSE) logs -f

ps:
	$(COMPOSE) ps

validate:
	@echo "Container engine: $(CONTAINER_ENGINE)"
	@echo "Checking Prometheus targets..."
	@curl -s http://localhost:9090/api/v1/targets | python3 -m json.tool | grep -E '"health"|"job"'
