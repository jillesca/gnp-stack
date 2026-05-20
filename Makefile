CONTAINER_ENGINE := $(shell command -v podman >/dev/null 2>&1 && podman compose version >/dev/null 2>&1 && echo podman || echo docker)
COMPOSE          := $(shell command -v docker-compose >/dev/null 2>&1 && echo docker-compose || echo $(CONTAINER_ENGINE) compose)
COMPOSE_VM       := $(COMPOSE) -f compose.yaml -f compose.override.vm.yaml
COMPOSE_LAPTOP   := $(COMPOSE) -f compose.yaml -f compose.override.laptop.yaml

# Remote VM deployment (split mode: Alloy+Loki on VM, rest on laptop)
VM_HOST  ?= 10.10.20.15
VM_USER  ?= developer
VM_PATH  ?= /home/developer/gnp-syslog
VM_SSH   := ssh $(VM_USER)@$(VM_HOST)
VM_COMPOSE := docker compose -f $(VM_PATH)/vm/compose.yaml

.PHONY: help up up-vm up-laptop down down-vm down-laptop restart restart-vm restart-laptop \
        logs ps validate \
        vm-sync vm-start vm-stop vm-deploy vm-logs vm-status

help:
	@echo "Usage:"
	@echo "  make up              Laptop mode: full stack with local Loki (no syslog)"
	@echo "  make up-laptop       Laptop mode + Alloy syslog (XRd pushes to laptop — needs open port)"
	@echo "  make up-vm           VM mode: full stack + Alloy syslog + macvlan networking"
	@echo "  make down            Stop laptop-mode stack"
	@echo "  make down-laptop     Stop laptop+Alloy stack"
	@echo "  make down-vm         Stop VM-mode stack (required if started with make up-vm)"
	@echo "  make restart         Restart laptop-mode stack"
	@echo "  make restart-laptop  Restart laptop+Alloy stack"
	@echo "  make restart-vm      Restart VM-mode stack"
	@echo "  make logs            Follow logs"
	@echo "  make ps              Show running containers"
	@echo "  make validate        Check Prometheus targets"
	@echo ""
	@echo "Split mode (Alloy+Loki on VM, Grafana+Prometheus on laptop):"
	@echo "  make vm-sync         Rsync Alloy/Loki config files to VM"
	@echo "  make vm-start        Start Alloy+Loki on VM via SSH"
	@echo "  make vm-stop         Stop Alloy+Loki on VM via SSH"
	@echo "  make vm-deploy       vm-sync + vm-start (full deploy)"
	@echo "  make vm-logs         Follow VM syslog stack logs via SSH"
	@echo "  make vm-status       Show running containers on VM via SSH"
	@echo ""
	@echo "Container engine detected: $(CONTAINER_ENGINE)"
	@echo "Env vars:"
	@echo "  VM_HOST    Remote VM IP/hostname (default: $(VM_HOST))"
	@echo "  VM_USER    SSH user on VM        (default: $(VM_USER))"
	@echo "  VM_PATH    Remote working dir    (default: $(VM_PATH))"
	@echo "  LOKI_URL   Loki URL for Grafana  (default: http://loki:3100)"
	@echo "             Set to http://VM_HOST:3100 when using split mode"
	@echo "  SYSLOG_DESTINATION  XRd syslog target IP (default: 10.10.20.11)"

up:
	$(COMPOSE) up -d

up-vm:
	$(COMPOSE_VM) up -d

up-laptop:
	$(COMPOSE_LAPTOP) up -d

down:
	$(COMPOSE) down

down-vm:
	$(COMPOSE_VM) down

down-laptop:
	$(COMPOSE_LAPTOP) down

restart: down up

restart-vm: down-vm up-vm

restart-laptop: down-laptop up-laptop

logs:
	$(COMPOSE) logs -f

ps:
	$(COMPOSE) ps

validate:
	@echo "Container engine: $(CONTAINER_ENGINE)"
	@echo "Checking Prometheus targets..."
	@curl -s http://localhost:9090/api/v1/targets | python3 -m json.tool | grep -E '"health"|"job"'

# ── Remote VM targets ────────────────────────────────────────────────────────

vm-sync:
	@echo "Syncing config files to $(VM_USER)@$(VM_HOST):$(VM_PATH) ..."
	$(VM_SSH) "mkdir -p $(VM_PATH)/alloy $(VM_PATH)/loki $(VM_PATH)/vm"
	rsync -avz alloy/config.alloy   $(VM_USER)@$(VM_HOST):$(VM_PATH)/alloy/
	rsync -avz loki/loki-config.yaml $(VM_USER)@$(VM_HOST):$(VM_PATH)/loki/
	rsync -avz vm/                  $(VM_USER)@$(VM_HOST):$(VM_PATH)/vm/

vm-start:
	@echo "Starting Alloy+Loki on $(VM_HOST) ..."
	$(VM_SSH) "cd $(VM_PATH) && $(VM_COMPOSE) up -d"

vm-stop:
	@echo "Stopping Alloy+Loki on $(VM_HOST) ..."
	$(VM_SSH) "cd $(VM_PATH) && $(VM_COMPOSE) down"

vm-deploy: vm-sync vm-start

vm-logs:
	$(VM_SSH) "cd $(VM_PATH) && $(VM_COMPOSE) logs -f"

vm-status:
	$(VM_SSH) "cd $(VM_PATH) && $(VM_COMPOSE) ps"

up:
	$(COMPOSE) up -d

up-vm:
	$(COMPOSE_VM) up -d

up-laptop:
	$(COMPOSE_LAPTOP) up -d

down:
	$(COMPOSE) down

down-vm:
	$(COMPOSE_VM) down

down-laptop:
	$(COMPOSE_LAPTOP) down

restart: down up

restart-vm: down-vm up-vm

restart-laptop: down-laptop up-laptop

logs:
	$(COMPOSE) logs -f

ps:
	$(COMPOSE) ps

validate:
	@echo "Container engine: $(CONTAINER_ENGINE)"
	@echo "Checking Prometheus targets..."
	@curl -s http://localhost:9090/api/v1/targets | python3 -m json.tool | grep -E '"health"|"job"'
