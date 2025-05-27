#!/bin/bash

# Configurações
DISCORD_WEBHOOK="SUA URL DISCORD AQUI"
LOG_FILE="/var/log/docker_rolling_update.log"
COMPOSE_BASE_DIR="/app/docker"
TEMP_DIR="/tmp/docker_rolling_update"
mkdir -p "$TEMP_DIR"

message_log="### Atualização de containers - $(date '+%Y-%m-%d %H:%M:%S')\n"

# Função para enviar mensagem para o Discord
send_discord_message() {
    local content="$1"
    curl -s -H "Content-Type: application/json" \
        -X POST \
        -d "{\"content\": \"$content\"}" \
        "$DISCORD_WEBHOOK" > /dev/null
}

# Verifica todos os subdiretórios em /app/docker que possuem docker-compose.yml
updated_services=()
error_services=()

for compose_file in $(find "$COMPOSE_BASE_DIR" -type f -name "docker-compose.yml"); do
    compose_dir=$(dirname "$compose_file")
    cd "$compose_dir" || continue

    echo "Verificando $compose_dir" | tee -a "$LOG_FILE"

    # Lista imagens atuais
    current_images=$(docker compose images --quiet)

    # Puxa novas imagens
    docker compose pull &>> "$LOG_FILE"
    if [ $? -ne 0 ]; then
        message_log+=":x: Falha ao executar 'docker compose pull' em ${compose_dir}\n"
        error_services+=("$compose_dir")
        continue
    fi

    # Lista novamente as imagens para detectar mudanças
    new_images=$(docker compose images --quiet)

    if [[ "$current_images" != "$new_images" ]]; then
        # Atualização detectada
        message_log+=":arrow_up: Atualização detectada em ${compose_dir}\n"

        # Atualiza os containers (modo rolling)
        docker compose up -d --remove-orphans &>> "$LOG_FILE"
        if [ $? -eq 0 ]; then
            updated_services+=("$compose_dir")
        else
            message_log+=":x: Erro ao atualizar containers em ${compose_dir}\n"
            error_services+=("$compose_dir")
        fi
    else
        echo "Sem mudanças em $compose_dir"
    fi
done

# Aguarda containers ficarem UP
sleep 5
if docker ps | grep -q Exited; then
    message_log+=":warning: Há containers em estado *Exited* após atualização.\n"
    docker ps -a | grep Exited >> "$LOG_FILE"
fi

# Limpa imagens não utilizadas
docker image prune -af --filter "until=24h" &>> "$LOG_FILE"
message_log+=":recycle: Limpeza de imagens antigas realizada.\n"

# Envia relatório se houve mudanças ou erros
if [[ ${#updated_services[@]} -gt 0 || ${#error_services[@]} -gt 0 ]]; then
    send_discord_message "$message_log"
fi
