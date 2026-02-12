#!/bin/sh
set -e

# Mostra help
show_help() {
    cat << EOF
Uso: ./install.sh [OPZIONE]

Opzioni:
  (nessuna)      Crea ambiente di sviluppo completo
  --postgres     Installa container PostgreSQL
  --help, -h     Mostra questo messaggio

Esempi:
  ./install.sh              # Prima installazione
  ./install.sh --postgres   # Aggiungi PostgreSQL
EOF
    exit 0
}

# Funzione per generare .env se non esiste
generate_env_file() {
    project_dir=$(basename "$PWD")
    cat > .env << EOF
# Configurazione Progetto CRM C++
# Generato automaticamente da install.sh

# ========================================
# Configurazione Comune
# ========================================
PROJECT_NAME=PROJECT_DIR_PLACEHOLDER
CPP_VERSION=20
CMAKE_VERSION=3.16

# ========================================
# Configurazione Sviluppo (DEV_)
# ========================================
DEV_PORT=8080
DEV_PORT_HOST=2310
DEV_NETWORK_SUFFIX=-net
DEV_IMAGE=ubuntu:24.04

# Vite/Svelte GUI
VITE_PORT=5173
VITE_PORT_HOST=2350

# ========================================
# Configurazione Release (RELEASE_)
# ========================================
# Docker Image
RELEASE_IMAGE=ubuntu:24.04

# Container Resources
RELEASE_MEMORY_LIMIT=512m
RELEASE_MEMORY_RESERVATION=256m
RELEASE_CPU_LIMIT=1.0
RELEASE_CPU_RESERVATION=0.5

# Application Port
RELEASE_PORT=8080

# Container User (non-root)
RELEASE_APP_USER=appuser
RELEASE_APP_USER_UID=1001
RELEASE_APP_USER_GID=1001

# ========================================
# Database Containers
# ========================================
# PostgreSQL
PGSQL_ENABLED=n
PGSQL_IMAGE=postgres:16
PGSQL_PORT=5432
PGSQL_PORT_HOST=2340
PGSQL_ROOT_USER=postgres
PGSQL_ROOT_PASSWORD=postgres
PGSQL_NAME=crmdb
PGSQL_USER=crmuser
PGSQL_PASSWORD=crmpass

# ========================================
# Heroku Deploy
# ========================================
HEROKU_APP_NAME=
EOF

    # sostituzioni compatibili sh
    sed "s|PROJECT_DIR_PLACEHOLDER|$project_dir|g" .env > .env.tmp && mv .env.tmp .env

    echo "File .env generato con configurazione di default"
}

# Genera o carica .env
if [ ! -f .env ]; then
    echo "File .env non trovato, genero configurazione di default..."
    generate_env_file
    echo "File .env generato. Procedo con la creazione del container..."
    echo ""

    # Ricarica le variabili appena generate
    . ./.env
fi

# Carica variabili da .env se non già caricate
if [ -z "$PROJECT_NAME" ]; then
    . ./.env
    echo "Configurazione caricata da .env"
fi

# Variabili derivate per sviluppo
DEV_NETWORK="$PROJECT_NAME$DEV_NETWORK_SUFFIX"
DEV_CONTAINER="$PROJECT_NAME"

# Variabili derivate per database containers
PGSQL_CONTAINER="$PROJECT_NAME-postgres"
PGSQL_VOLUME="$PROJECT_NAME-postgres-data"

# Gestione opzione --help
if [ "$1" = "--help" ] || [ "$1" = "-h" ]; then
    show_help
fi

# Creates PostgreSQL container
# - Network: ${DEV_NETWORK} (<project>-dev)
# - Container: ${PGSQL_CONTAINER} (<project>-postgres)
# - Volume: ${PGSQL_VOLUME} (<project>-postgres-data)
# - Port: ${PGSQL_PORT_HOST}:5432
# - Database: ${PGSQL_NAME}, User: ${PGSQL_USER}
# - Starts existing container if present
create_pgsql_container() {
    if ! docker network ls --format "{{.Name}}" | grep -q "^${DEV_NETWORK}$"; then
        docker network create "$DEV_NETWORK" >/dev/null 2>&1 || true
    fi

    if docker ps -a --format "{{.Names}}" | grep -q "^${PGSQL_CONTAINER}$"; then
        if docker ps --format "{{.Names}}" | grep -q "^${PGSQL_CONTAINER}$"; then
            echo "PostgreSQL container già in esecuzione."
            return 0
        fi
        docker start "$PGSQL_CONTAINER" >/dev/null 2>&1 || {
            echo "Errore nell'avvio del container PostgreSQL."
            return 1
        }
        echo "Container PostgreSQL avviato."
        return 0
    fi

    if ! docker images --format "{{.Repository}}:{{.Tag}}" | grep -q "^${PGSQL_IMAGE}$"; then
        echo "Download immagine PostgreSQL..."
        docker pull "$PGSQL_IMAGE" >/dev/null 2>&1
    fi

    echo "Creazione container PostgreSQL..."
    docker run -d --name "$PGSQL_CONTAINER" --network "$DEV_NETWORK" \
        -e POSTGRES_USER="$PGSQL_ROOT_USER" \
        -e POSTGRES_PASSWORD="$PGSQL_ROOT_PASSWORD" \
        -e POSTGRES_DB="$PGSQL_NAME" \
        -p "$PGSQL_PORT_HOST:5432" \
        -v "$PGSQL_VOLUME:/var/lib/postgresql/data" \
        "$PGSQL_IMAGE" >/dev/null 2>&1 || {
            echo "Errore nella creazione del container PostgreSQL."
            return 1
        }

    echo "Container PostgreSQL creato e avviato."
    echo "  Host: localhost:$PGSQL_PORT_HOST"
    echo "  Database: $PGSQL_NAME"
    echo "  User: $PGSQL_ROOT_USER"
    echo "  Password: $PGSQL_ROOT_PASSWORD"
}

# Setup PostgreSQL database
setup_pgsql_database() {
    echo "  Attesa disponibilità PostgreSQL..."
    sleep 3

    # Install PostgreSQL client if not present
    if ! docker exec "$DEV_CONTAINER" sh -c "command -v psql >/dev/null 2>&1"; then
        echo "  Installazione client PostgreSQL nel container dev..."
        docker exec "$DEV_CONTAINER" sh -c "apt-get update -qq && apt-get install -y -qq postgresql-client >/dev/null 2>&1"
    fi

    # Wait for PostgreSQL to be ready
    echo "  Verifica connessione PostgreSQL..."
    for i in 1 2 3 4 5; do
        if docker exec "$DEV_CONTAINER" pg_isready -h"$PGSQL_CONTAINER" -U"$PGSQL_ROOT_USER" >/dev/null 2>&1; then
            echo "  PostgreSQL pronto"
            break
        fi
        echo "  Tentativo $i/5..."
        sleep 2
    done

    if ! docker exec "$DEV_CONTAINER" pg_isready -h"$PGSQL_CONTAINER" -U"$PGSQL_ROOT_USER" >/dev/null 2>&1; then
        echo "  [WARN] PostgreSQL non raggiungibile"
        return 1
    fi

    echo "  Configurazione database e permessi..."
    docker exec "$DEV_CONTAINER" sh -c "PGPASSWORD=\"$PGSQL_ROOT_PASSWORD\" psql -h\"$PGSQL_CONTAINER\" -U\"$PGSQL_ROOT_USER\" -d \"$PGSQL_NAME\" \
        -c \"GRANT ALL ON SCHEMA public TO \\\"$PGSQL_USER\\\";\"" 2>/dev/null || true

    echo "  Setup PostgreSQL completato"
}

# Gestione opzione --postgres
if [ "$1" = "--postgres" ]; then
    if [ "$PGSQL_ENABLED" != "y" ]; then
        echo "ERRORE: PostgreSQL non è abilitato nel file .env"
        echo "Imposta PGSQL_ENABLED=y nel file .env per continuare"
        exit 1
    fi

    echo "Configurazione PostgreSQL..."

    # Check if dev container is running
    if ! docker ps --format '{{.Names}}' | grep -q "^$DEV_CONTAINER$"; then
        echo "ERRORE: Container dev '$DEV_CONTAINER' non in esecuzione."
        echo "Esegui prima './install.sh --dev' per avviare il container dev."
        exit 1
    fi

    # Create PostgreSQL container
    create_pgsql_container

    # Setup database
    setup_pgsql_database

    echo ""
    echo "=========================================="
    echo "PostgreSQL configurato e pronto!"
    echo "=========================================="
    echo "  Host: localhost:$PGSQL_PORT_HOST"
    echo "  Database: $PGSQL_NAME"
    echo "  User: $PGSQL_USER"
    echo ""
    exit 0
fi

# Creazione container di sviluppo (prima esecuzione o --dev)
if [ "$1" = "--dev" ] || [ -z "$1" ]; then
    # Verifica se il container esiste già
    if docker ps -a --format '{{.Names}}' | grep -q "^$DEV_CONTAINER$"; then
        echo "Container '$DEV_CONTAINER' già esistente."
        if ! docker ps --format '{{.Names}}' | grep -q "^$DEV_CONTAINER$"; then
            echo "Avvio container..."
            docker start "$DEV_CONTAINER"
        else
            echo "Container già in esecuzione."
        fi
    else
        # Crea la rete se non esiste
        if ! docker network ls --format '{{.Name}}' | grep -q "^$DEV_NETWORK$"; then
            docker network create "$DEV_NETWORK"
            echo "Docker network '$DEV_NETWORK' creata."
        fi

        # Crea Dockerfile.dev se non esiste
        if [ ! -f docker/Dockerfile.dev ]; then
            echo "Creazione Dockerfile.dev..."
            mkdir -p docker
            cat > docker/Dockerfile.dev << 'DOCKERFILE'
FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

RUN apt update && apt install -y \
    build-essential \
    cmake \
    git \
    curl \
    vim \
    libpq-dev \
    postgresql-client \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Installa Node.js 20
RUN curl -fsSL https://deb.nodesource.com/setup_20.x | bash - \
    && apt-get install -y nodejs \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /workspace
DOCKERFILE
            echo "Dockerfile.dev creato in docker/Dockerfile.dev"
        fi

        # Build immagine dev
        echo "Build immagine di sviluppo..."
        docker build -t "$PROJECT_NAME-dev:latest" -f docker/Dockerfile.dev .

        # Avvia container di sviluppo
        echo "Creazione container di sviluppo..."
        docker run -it -d \
            --name "$DEV_CONTAINER" \
            -v "$PWD":/workspace \
            -w /workspace \
            -p "$DEV_PORT_HOST:$DEV_PORT" \
            -p "$VITE_PORT_HOST:$VITE_PORT" \
            --network "$DEV_NETWORK" \
            "$PROJECT_NAME-dev:latest" \
            tail -f /dev/null

        echo "Container '$DEV_CONTAINER' creato e avviato."
    fi

    # Crea Makefile se non esiste
    if [ ! -f Makefile ]; then
        echo "Creazione Makefile..."
        cat > Makefile << 'MAKEFILE'
APP=service

all: build-frontend build-backend

build-backend:
	@mkdir -p build
	@cd build && cmake ../api >/dev/null && make >/dev/null
	@echo "✓ backend"

build-frontend:
	@cd gui && npm install >/dev/null 2>&1 && npm run build >/dev/null 2>&1
	@echo "✓ frontend"

dev-frontend:
	@cd gui && npm run dev -- --host 0.0.0.0

run:
	@if [ ! -f build/$(APP) ]; then \
		echo "✗ run 'make build-backend' first"; \
		exit 1; \
	fi
	@./build/$(APP)

clean:
	@rm -rf build gui/dist gui/node_modules
	@echo "✓ clean"

help:
	@echo "all              build everything"
	@echo "build-backend    compile C++"
	@echo "build-frontend   build Svelte"
	@echo "dev-frontend     start Vite dev server"
	@echo "run              start service"
	@echo "clean            remove build artifacts"

.PHONY: all build-backend build-frontend dev-frontend run clean help
MAKEFILE
        echo "Makefile creato"
    fi

    # Crea struttura progetto se non esiste
    if [ ! -d api ]; then
        echo "Creazione struttura progetto..."
        mkdir -p api/src
        mkdir -p gui/src

        # Crea main.cpp di esempio
        cat > api/src/main.cpp << 'MAINCPP'
#include <crow.h>
#include <iostream>
#include <fstream>
#include <sstream>

std::string read_file(const std::string& path) {
    std::ifstream file(path);
    if (!file.is_open()) {
        return "";
    }
    std::stringstream buffer;
    buffer << file.rdbuf();
    return buffer.str();
}

int main() {
    crow::SimpleApp app;

    // API endpoint /api/hello
    CROW_ROUTE(app, "/api/hello")
    ([]{
        crow::json::wvalue response;
        response["message"] = "Hello World from C++ Crow!";
        response["status"] = "success";
        return response;
    });

    // Serve file statici da gui/dist/
    CROW_ROUTE(app, "/<path>")
    ([](const std::string& path){
        std::string file_path = "gui/dist/" + path;
        std::string content = read_file(file_path);

        if (content.empty()) {
            // Se il file non esiste, prova index.html (SPA routing)
            content = read_file("gui/dist/index.html");
            if (content.empty()) {
                return crow::response(404, "File not found");
            }
        }

        auto resp = crow::response(content);

        // Imposta Content-Type in base all'estensione
        if (path.ends_with(".html")) {
            resp.set_header("Content-Type", "text/html");
        } else if (path.ends_with(".js")) {
            resp.set_header("Content-Type", "application/javascript");
        } else if (path.ends_with(".css")) {
            resp.set_header("Content-Type", "text/css");
        } else if (path.ends_with(".json")) {
            resp.set_header("Content-Type", "application/json");
        }

        return resp;
    });

    // Route principale serve index.html
    CROW_ROUTE(app, "/")
    ([]{
        std::string content = read_file("gui/dist/index.html");
        if (content.empty()) {
            return crow::response(500, "Frontend not built. Run 'make build-frontend' first.");
        }
        auto resp = crow::response(content);
        resp.set_header("Content-Type", "text/html");
        return resp;
    });

    // Leggi porta da ENV o usa default
    const char* port_env = std::getenv("PORT");
    int port = port_env ? std::stoi(port_env) : 8080;

    std::cout << "==================================" << std::endl;
    std::cout << "Server starting on port " << port << std::endl;
    std::cout << "API endpoints: /api/hello" << std::endl;
    std::cout << "Frontend: http://localhost:" << port << std::endl;
    std::cout << "==================================" << std::endl;

    app.port(port).multithreaded().run();
}
MAINCPP

        # Crea CMakeLists.txt
        cat > api/CMakeLists.txt << 'CMAKE'
cmake_minimum_required(VERSION 3.16)
project(service)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# Trova librerie
find_package(Threads REQUIRED)

# Scarica ASIO standalone
include(FetchContent)
FetchContent_Declare(
  asio
  GIT_REPOSITORY https://github.com/chriskohlhoff/asio.git
  GIT_TAG asio-1-28-0
)
FetchContent_MakeAvailable(asio)

# Scarica Crow
FetchContent_Declare(
  crow
  GIT_REPOSITORY https://github.com/CrowCpp/Crow.git
  GIT_TAG v1.0+5
)
FetchContent_MakeAvailable(crow)

# Eseguibile
add_executable(service src/main.cpp)

# Include ASIO standalone
target_include_directories(service PRIVATE ${asio_SOURCE_DIR}/asio/include)

# Definizioni per usare ASIO standalone (non Boost)
target_compile_definitions(service PRIVATE
    ASIO_STANDALONE
    CROW_USE_ASIO
)

target_link_libraries(service Crow::Crow Threads::Threads)
CMAKE

        # Crea package.json per Svelte
        cat > gui/package.json << 'PACKAGEJSON'
{
  "name": "gui",
  "private": true,
  "version": "0.0.0",
  "type": "module",
  "scripts": {
    "dev": "vite --host 0.0.0.0",
    "build": "vite build",
    "preview": "vite preview"
  },
  "devDependencies": {
    "@sveltejs/vite-plugin-svelte": "^3.0.0",
    "svelte": "^4.2.0",
    "vite": "^5.0.0"
  }
}
PACKAGEJSON

        # Crea vite.config.js
        cat > gui/vite.config.js << 'VITECONFIG'
import { defineConfig } from 'vite'
import { svelte } from '@sveltejs/vite-plugin-svelte'

export default defineConfig({
  plugins: [svelte()],
  server: {
    port: 5173,
    host: '0.0.0.0'
  }
})
VITECONFIG

        # Crea App.svelte di esempio
        cat > gui/src/App.svelte << 'APPSVELTE'
<script>
  let message = 'Loading...';

  async function fetchHello() {
    try {
      const response = await fetch('/api/hello');
      const data = await response.json();
      message = data.message;
    } catch (error) {
      message = 'Error: ' + error.message;
    }
  }

  fetchHello();
</script>

<main>
  <h1>Hello World - Svelte + Crow</h1>
  <p>Message from backend: <strong>{message}</strong></p>
</main>

<style>
  main {
    text-align: center;
    padding: 2em;
    font-family: Arial, sans-serif;
  }

  h1 {
    color: #ff3e00;
  }
</style>
APPSVELTE

        # Crea main.js
        cat > gui/src/main.js << 'MAINJS'
import './app.css'
import App from './App.svelte'

const app = new App({
  target: document.getElementById('app'),
})

export default app
MAINJS

        # Crea app.css
        cat > gui/src/app.css << 'APPCSS'
:root {
  font-family: Inter, system-ui, Avenir, Helvetica, Arial, sans-serif;
  line-height: 1.5;
  font-weight: 400;
}

body {
  margin: 0;
  padding: 0;
  min-height: 100vh;
}

#app {
  max-width: 1280px;
  margin: 0 auto;
  padding: 2rem;
}
APPCSS

        # Crea index.html
        cat > gui/index.html << 'INDEXHTML'
<!doctype html>
<html lang="en">
  <head>
    <meta charset="UTF-8" />
    <meta name="viewport" content="width=device-width, initial-scale=1.0" />
    <title>Svelte + Crow</title>
  </head>
  <body>
    <div id="app"></div>
    <script type="module" src="/src/main.js"></script>
  </body>
</html>
INDEXHTML

        echo "File di progetto HelloWorld creati"
    fi

    # Installa dipendenze npm nel container
    echo "Installazione dipendenze frontend..."
    docker exec "$DEV_CONTAINER" sh -c "cd gui && npm install" 2>/dev/null || true

    echo ""
    echo "=========================================="
    echo "Ambiente di sviluppo pronto!"
    echo "=========================================="
    echo ""
    echo "Container: $DEV_CONTAINER"
    echo "Network: $DEV_NETWORK"
    echo ""
    echo "Porte esposte:"
    echo "  Backend:  localhost:$DEV_PORT_HOST -> container:$DEV_PORT"
    echo "  Frontend: localhost:$VITE_PORT_HOST -> container:$VITE_PORT"
    echo ""
    echo "Entra nel container con:"
    echo "  docker exec -it $DEV_CONTAINER bash"
    echo ""
    echo "Comandi disponibili nel container:"
    echo "  make build-backend    # Compila il backend C++"
    echo "  make build-frontend   # Build frontend Svelte"
    echo "  make dev-frontend     # Avvia Vite dev server"
    echo "  make run              # Esegue l'applicazione"
    echo ""
    echo "Altri comandi:"
    echo "  ./install.sh --postgres   # Installa PostgreSQL"
    echo ""
    exit 0
fi
