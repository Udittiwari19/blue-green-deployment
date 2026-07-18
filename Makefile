COMPOSE  = docker compose
ANSIBLE  = ansible-playbook -i ansible/inventory/hosts.ini
PLAYBOOK = ansible

.PHONY: help init blue-up green-up blue-stop green-stop deploy rollback \
        switch-green switch-blue status health load-test clean

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

clean:
	$(COMPOSE) --profile blue --profile green down -v
	$(COMPOSE) down -v
