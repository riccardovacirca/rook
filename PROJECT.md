Di seguito il **file progetto.md** richiesto.

---

# CRM – Ambiente di Sviluppo Dockerizzato + Deploy Heroku

## Obiettivo

Ambiente completamente containerizzato dove:

* Host richiede solo:

  * Docker
  * Git
* Tutti gli strumenti di sviluppo sono nel container:

  * g++
  * cmake
  * make
  * node
  * npm
  * vite
  * claude code
  * client postgres
* Produzione su Heroku tramite Docker container.

---

# 1️⃣ Struttura Progetto

```
crm/
├── backend/
│   ├── src/
│   ├── CMakeLists.txt
│   └── main.cpp
│
├── frontend/
│   ├── src/
│   ├── package.json
│   └── vite.config.js
│
├── docker/
│   ├── Dockerfile.dev
│   └── Dockerfile.prod
│
├── scripts/
│   ├── install.sh
│   └── release.sh
│
├── docker-compose.dev.yml
├── Makefile
└── progetto.md
```

---

# 2️⃣ Dockerfile.dev

Container con TUTTI gli strumenti di sviluppo.

`docker/Dockerfile.dev`

```dockerfile
FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

RUN apt update && apt install -y \
    build-essential \
    cmake \
    git \
    curl \
    vim \
    nodejs \
    npm \
    libpq-dev \
    postgresql-client

# Installazione claude code (placeholder)
RUN npm install -g @anthropic-ai/claude-code || true

WORKDIR /workspace
```

---

# 3️⃣ docker-compose.dev.yml

```
version: "3.9"

services:
  dev:
    build:
      context: .
      dockerfile: docker/Dockerfile.dev
    container_name: crm-dev
    volumes:
      - .:/workspace
    ports:
      - "5173:5173"
      - "8080:8080"
    environment:
      DATABASE_URL: postgres://dev:dev@db:5432/crm
    depends_on:
      - db
    tty: true

  db:
    image: postgres:16
    container_name: crm-db
    environment:
      POSTGRES_USER: dev
      POSTGRES_PASSWORD: dev
      POSTGRES_DB: crm
    volumes:
      - ./volumes/db:/var/lib/postgresql/data
    ports:
      - "5432:5432"
```

---

# 4️⃣ Script install.sh

`scripts/install.sh`

```bash
#!/bin/bash
set -e

echo "Build container sviluppo..."
docker compose -f docker-compose.dev.yml build

echo "Avvio ambiente..."
docker compose -f docker-compose.dev.yml up -d

echo "Ambiente pronto."
echo "Entra con:"
echo "docker exec -it crm-dev bash"
```

---

# 5️⃣ Makefile

Permette build backend + frontend dal container.

```
APP=crm_app

build-backend:
	mkdir -p build
	cd build && cmake ../backend && make

build-frontend:
	cd frontend && npm install && npm run build

dev-frontend:
	cd frontend && npm run dev

run:
	./build/$(APP)

clean:
	rm -rf build
```

Uso dentro container:

```
make build-backend
make build-frontend
```

---

# 6️⃣ Dockerfile Produzione

`docker/Dockerfile.prod`

```dockerfile
# ---- frontend build ----
FROM node:20 AS frontend-build
WORKDIR /app/frontend
COPY frontend/ .
RUN npm install
RUN npm run build

# ---- backend build ----
FROM ubuntu:24.04 AS backend-build
RUN apt update && apt install -y \
    build-essential cmake libpq-dev

WORKDIR /app
COPY backend/ backend/
RUN mkdir build && cd build && \
    cmake ../backend && \
    make

# ---- runtime ----
FROM ubuntu:24.04
RUN apt update && apt install -y libpq5

WORKDIR /app
COPY --from=backend-build /app/build/crm_app .
COPY --from=frontend-build /app/frontend/dist ./dist

ENV PORT=8080
CMD ["./crm_app"]
```

---

# 7️⃣ release.sh (Deploy Heroku)

`scripts/release.sh`

```bash
#!/bin/bash
set -e

APP_NAME=$1

if [ -z "$APP_NAME" ]; then
  echo "Uso: ./release.sh nome-app-heroku"
  exit 1
fi

echo "Login Heroku..."
heroku container:login

echo "Build immagine..."
docker build -t registry.heroku.com/$APP_NAME/web \
    -f docker/Dockerfile.prod .

echo "Push..."
docker push registry.heroku.com/$APP_NAME/web

echo "Release..."
heroku container:release web -a $APP_NAME

echo "Deploy completato."
```

---

# 8️⃣ Requisiti Applicazione

Il backend deve:

* Leggere `PORT`
* Leggere `DATABASE_URL`
* Non usare filesystem persistente

Esempio C++:

```cpp
int port = std::stoi(std::getenv("PORT"));
app.port(port).multithreaded().run();
```

---

# 9️⃣ Workflow

### Prima configurazione

```
git clone ...
cd crm
./scripts/install.sh
docker exec -it crm-dev bash
```

---

### Sviluppo

Dentro container:

```
make build-backend
make build-frontend
make run
```

Oppure:

```
make dev-frontend
```

---

### Deploy produzione

```
heroku create crm-cliente1
heroku addons:create heroku-postgresql:essential-0
./scripts/release.sh crm-cliente1
```

---

# 🔟 Architettura Finale

Per ogni cliente:

```
Heroku App (1 dyno)
 ├── Crow backend
 ├── Frontend buildato
 └── ENV config

Heroku Postgres (1 DB)
```

Costo medio: ~12–18 €/mese per cliente.

---

Se vuoi posso generare una variante ottimizzata per:

* multi-cliente
* staging separato
* oppure migrazione futura a VPS mantenendo stessa struttura Docker.
