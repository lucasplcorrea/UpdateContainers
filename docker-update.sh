#!/bin/bash

# Adicionado para sair em caso de erro e falhar em pipelines
set -eo pipefail

COMPOSE_DIR="/app/docker"
LOG_DIR="/var/log/docker-updater"
mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/$(date +'%Y-%m-%d').log"

DISCORD_WEBHOOK="SUA URL DISCORD AQUI"

log() {
    # Usando printf para maior portabilidade e controle de formato
    printf '%s - %s\n' "$(date +'%F %T')" "$1" | tee -a "$LOG_FILE"
}

send_discord() {
    local message="$1"
    # Adicionado tratamento de erro básico para o curl
    if ! curl -s -f -H "Content-Type: application/json" \
         -X POST \
         -d "$(jq -nc --arg content "$message" '{content: $content}')" \
         "$DISCORD_WEBHOOK" > /dev/null; then
        log "❌ Falha ao enviar notificação para o Discord."
    fi
}

log "🔄 Iniciando verificação de atualizações de containers Docker..."

# Inicializa arrays fora do loop
UPDATED_CONTAINERS=()
ERRORS=()

# Usa process substitution para evitar subshell no loop while
while IFS= read -r COMPOSE_FILE; do
    # Usa pushd/popd para gerenciar diretórios de forma mais segura
    pushd "$(dirname "$COMPOSE_FILE")" > /dev/null || { log "❌ Falha ao acessar $(dirname "$COMPOSE_FILE")"; ERRORS+=("Erro ao acessar $(dirname "$COMPOSE_FILE")"); continue; }
    COMPOSE_PATH=$(pwd) # Pega o caminho absoluto após entrar no diretório

    log "📁 Verificando compose em: $COMPOSE_PATH"

    log "📥 Fazendo pull das imagens..."
    # Captura a saída e o status de saída do pull
    if OUTPUT=$(docker compose pull 2>&1); then
        log "Resultado do pull para $COMPOSE_PATH: Sucesso (verificar logs para detalhes)"
        echo "$OUTPUT" >> "$LOG_FILE"
    else
        pull_exit_code=$?
        log "❌ Falha no pull para $COMPOSE_PATH (Código de saída: $pull_exit_code)"
        echo "$OUTPUT" >> "$LOG_FILE"
        ERRORS+=("Erro no pull em $COMPOSE_PATH")
        popd > /dev/null # Garante o retorno ao diretório anterior em caso de falha no pull
        continue # Pula para o próximo arquivo compose
    fi

    # Verifica se houve download de novas imagens
    if echo "$OUTPUT" | grep -q -E 'Pull complete|Downloaded newer image|Newer image'; then # Ajustado grep para cobrir mais casos
        log "🔄 Atualizações encontradas para $COMPOSE_PATH, subindo novos containers com --force-recreate..."
        # Captura a saída e o status de saída do up
        if UP_OUTPUT=$(docker compose up -d --remove-orphans --force-recreate 2>&1); then
            UPDATED_CONTAINERS+=("$COMPOSE_PATH")
            log "✅ Atualizado com sucesso: $COMPOSE_PATH"
            echo "$UP_OUTPUT" >> "$LOG_FILE"
        else
            up_exit_code=$?
            ERRORS+=("Erro ao atualizar $COMPOSE_PATH (Código de saída: $up_exit_code)")
            log "❌ Falha ao atualizar: $COMPOSE_PATH (Código de saída: $up_exit_code)"
            echo "$UP_OUTPUT" >> "$LOG_FILE"
        fi
    else
        log "✅ Nenhuma atualização encontrada para: $COMPOSE_PATH"
    fi

    popd > /dev/null # Retorna ao diretório anterior

done < <(find "$COMPOSE_DIR" -type f \( -name "docker-compose.yml" -o -name "docker-compose.yaml" \))

log "🧹 Limpando imagens não utilizadas..."
# Adicionado tratamento de erro para prune
if ! docker image prune -af >> "$LOG_FILE" 2>&1; then
    log "⚠️ Erro ao limpar imagens não utilizadas."
    ERRORS+=("Erro durante docker image prune -af")
fi

# Verifica e envia notificações
if [ ${#UPDATED_CONTAINERS[@]} -gt 0 ]; then
    # Usando mapfile/readarray para construir a mensagem de forma mais segura (requer Bash 4+)
    mapfile -t updated_list < <(printf '%s\n' "${UPDATED_CONTAINERS[@]}")
    msg="🚀 Atualizações aplicadas nos seguintes composes:\n$(printf '* %s\n' "${updated_list[@]}")"
    log "📣 Enviando notificação de sucesso..."
    send_discord "$msg"
fi

if [ ${#ERRORS[@]} -gt 0 ]; then
    mapfile -t error_list < <(printf '%s\n' "${ERRORS[@]}")
    msg="⚠️ Erros durante atualização:\n$(printf '* %s\n' "${error_list[@]}")"
    log "📣 Enviando notificação de erro..."
    send_discord "$msg"
fi

log "✅ Script finalizado."
