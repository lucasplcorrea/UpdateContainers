#!/bin/bash

# Diretório de composes
COMPOSE_DIR="/app/docker"

# Diretório de log
LOG_DIR="/var/log/docker-updater"
mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/$(date +'%Y-%m-%d').log"

# Webhook do Discord
DISCORD_WEBHOOK="SUA URL DISCORD AQUI"

# Função para registrar logs com timestamp
log() {
    echo "$(date +'%F %T') - $1" | tee -a "$LOG_FILE"
}

# Função para enviar mensagem ao Discord
send_discord() {
    local message="$1"
    curl -s -H "Content-Type: application/json" \
         -X POST \
         -d "{\"content\": \"$message\"}" \
         "$DISCORD_WEBHOOK" > /dev/null
}

log "🔄 Iniciando verificação de atualizações de containers Docker..."

UPDATED_CONTAINERS=()
ERRORS=()

# Procurar arquivos docker-compose.{yml,yaml}
find "$COMPOSE_DIR" -type f \( -name "docker-compose.yml" -o -name "docker-compose.yaml" \) | while read -r COMPOSE_FILE; do
    COMPOSE_PATH=$(dirname "$COMPOSE_FILE")
    log "📁 Verificando compose em: $COMPOSE_PATH"

    cd "$COMPOSE_PATH" || { log "❌ Falha ao acessar $COMPOSE_PATH"; ERRORS+=("Erro ao acessar $COMPOSE_PATH"); continue; }

    log "📥 Fazendo pull das imagens..."
    OUTPUT=$(docker compose pull 2>&1)
    echo "$OUTPUT" >> "$LOG_FILE"

    if echo "$OUTPUT" | grep -q "Downloaded newer image"; then
        log "🔄 Atualizações encontradas, subindo novos containers..."
        if docker compose up -d --remove-orphans >> "$LOG_FILE" 2>&1; then
            UPDATED_CONTAINERS+=("$COMPOSE_PATH")
            log "✅ Atualizado com sucesso: $COMPOSE_PATH"
        else
            ERRORS+=("Erro ao atualizar $COMPOSE_PATH")
            log "❌ Falha ao atualizar: $COMPOSE_PATH"
        fi
    else
        log "✅ Nenhuma atualização para: $COMPOSE_PATH"
    fi
done

log "🧹 Limpando imagens não utilizadas..."
docker image prune -af >> "$LOG_FILE" 2>&1

if [ ${#UPDATED_CONTAINERS[@]} -gt 0 ]; then
    msg="🚀 Atualizações aplicadas nos seguintes composes:\n$(printf '%s\n' "${UPDATED_CONTAINERS[@]}")"
    log "📣 $msg"
    send_discord "$msg"
fi

if [ ${#ERRORS[@]} -gt 0 ]; then
    msg="⚠️ Erros durante atualização:\n$(printf '%s\n' "${ERRORS[@]}")"
    log "📣 $msg"
    send_discord "$msg"
fi

log "✅ Script finalizado."
