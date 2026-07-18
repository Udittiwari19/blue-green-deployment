COMPOSE  = docker compose
ANSIBLE  = ansible-playbook -i ansible/inventory/hosts.ini
PLAYBOOK = ansible

.PHONY: help init blue-up green-up blue-stop green-stop deploy rollback \
        switch-green switch-blue status health load-test load-test-prewarm \
        baseline clean

help:
	@echo ""
	@echo "  Blue-Green Deployment Framework — Make targets"
	@echo "  ─────────────────────────────────────────────"
	@echo "  make init          Build images + start BLUE + Nginx"
	@echo "  make blue-up       Start BLUE environment"
	@echo "  make green-up      Start GREEN environment (alongside blue)"
	@echo "  make blue-stop     Stop BLUE containers"
	@echo "  make green-stop    Stop GREEN containers"
	@echo "  make deploy        Run Ansible deploy playbook (blue→green)"
	@echo "  make rollback      Run Ansible rollback playbook (green→blue)"
	@echo "  make switch-green  Nginx upstream swap to GREEN only"
	@echo "  make switch-blue   Nginx upstream swap to BLUE only"
	@echo "  make status        Show running containers"
	@echo "  make health        Hit gateway health endpoint"
	@echo "  make load-test     Run wrk2 load test with mid-flight switchover"
	@echo "  make baseline      Run wrk2 against blue only (no switchover) — get reference p50/p99"
	@echo "  make clean         Stop all containers + remove volumes"
	@echo ""

init:
	@echo ">>> Building images and starting BLUE environment..."
	$(COMPOSE) up -d nginx
	$(COMPOSE) --profile blue up -d --build
	@echo ">>> Ready. Hit: curl http://localhost/health"

blue-up:
	$(COMPOSE) --profile blue up -d --build

green-up:
	$(COMPOSE) --profile green up -d --build

blue-stop:
	$(COMPOSE) --profile blue stop

green-stop:
	$(COMPOSE) --profile green stop

deploy:
	$(ANSIBLE) $(PLAYBOOK)/deploy.yml

rollback:
	$(ANSIBLE) $(PLAYBOOK)/rollback.yml

switch-green:
	$(ANSIBLE) $(PLAYBOOK)/switchover.yml -e "target=green"

switch-blue:
	$(ANSIBLE) $(PLAYBOOK)/switchover.yml -e "target=blue"

status:
	$(COMPOSE) ps

health:
	@curl -s http://localhost/health | python3 -m json.tool

load-test:
	chmod +x load-test/run_wrk2.sh
	cd load-test && ./run_wrk2.sh

baseline:
	chmod +x load-test/run_baseline.sh
	cd load-test && ./run_baseline.sh

load-test-prewarm:
	@echo ">>> Step 1/3 — Building GREEN images (so Ansible skips rebuild during test)..."
	$(COMPOSE) --profile green build
	@echo ">>> Step 2/3 — Starting GREEN containers..."
	$(COMPOSE) --profile green up -d
	@echo ">>> Step 3/3 — Waiting 30s for GREEN JVMs to reach steady state..."
	@sleep 30
	@echo ">>> GREEN is warm and images are current. Starting load test..."
	chmod +x load-test/run_wrk2_prewarm.sh
	cd load-test && ./run_wrk2_prewarm.sh

clean:
	$(COMPOSE) --profile blue --profile green down -v
	$(COMPOSE) down -v
