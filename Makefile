# Makefile

up:
	docker-compose up -d --build

down:
	docker-compose down

restart:
	docker-compose down && docker-compose up -d --build

rebuild:
	docker-compose build --no-cache

logs:
	docker-compose logs -f --tail=100

app:
	docker-compose exec app bash

nginx:
	docker-compose exec nginx sh

mysql:
	docker-compose exec mysql bash

redis:
	docker-compose exec redis sh

kafka:
	docker-compose exec kafka bash

certs:
ifndef DOMAIN
	$(error DOMAIN is not set. Usage: make certs DOMAIN=yourdomain.com)
endif
	docker-compose run --rm certbot certonly \
		--webroot -w /var/www/certbot \
		-d $(DOMAIN) -d www.$(DOMAIN) \
		--email your@email.com \
		--agree-tos --no-eff-email

renew-certs:
	docker-compose exec certbot certbot renew

ps:
	docker-compose ps

regen-keys:
	bash ./regen-keys.sh

change-domain:
ifndef DOMAIN
	$(error DOMAIN is not set. Usage: make change-domain DOMAIN=example.com [PREFIX=v2])
endif
	bash ./change-domain.sh --domain=$(DOMAIN) $(if $(PREFIX),--prefix=$(PREFIX),)

clean:
	docker system prune -f
