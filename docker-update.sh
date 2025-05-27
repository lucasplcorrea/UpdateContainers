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

# Função revisada para enviar notificações ao Discord usando jq
send_discord() {
    local message="$1"
    # Usa jq para construir o payload JSON corretamente, tratando novas linhas e caracteres especiais
    local payload
    payload=$(jq -nc --arg content "$message" '{content: $content}')

    # Envia usando curl
    if ! curl -s -f -H "Content-Type: application/json" \
         -X POST \
         -d "$payload" \
         "$DISCORD_WEBHOOK" > /dev/null; then
        log "❌ Falha ao enviar notificação para o Discord."
    fi
}

log "🔄 Iniciando verificação de atualizações de containers Docker..."

# Inicializa arrays e array associativo (requer Bash 4+)
UPDATED_COMPOSE_INFO=()
ERRORS=()
declare -A ACTUAL_UPDATES_MAP # Armazena apenas composes com imagens realmente atualizadas

# Usa process substitution para evitar subshell no loop while
while IFS= read -r COMPOSE_FILE; do
    # Usa pushd/popd para gerenciar diretórios de forma mais segura
    if ! pushd "$(dirname "$COMPOSE_FILE")" > /dev/null; then
        log "❌ Falha ao acessar $(dirname "$COMPOSE_FILE")"
        ERRORS+=("Erro ao acessar $(dirname "$COMPOSE_FILE")")
        continue
    fi
    COMPOSE_PATH=$(pwd) # Pega o caminho absoluto após entrar no diretório

    log "📁 Verificando compose em: $COMPOSE_PATH"

    log "📥 Fazendo pull das imagens..."
    # Captura a saída e o status de saída do pull
    PULL_OUTPUT=""
    PULL_SUCCESS=true
    if ! PULL_OUTPUT=$(docker compose pull 2>&1); then
        PULL_SUCCESS=false
        pull_exit_code=$?
        log "❌ Falha no pull para $COMPOSE_PATH (Código de saída: $pull_exit_code)"
        echo "$PULL_OUTPUT" >> "$LOG_FILE"
        ERRORS+=("Erro no pull em $COMPOSE_PATH")
        # Mesmo com falha no pull, continua para o popd
    else
        log "Resultado do pull para $COMPOSE_PATH: Sucesso (verificar logs para detalhes)"
        echo "$PULL_OUTPUT" >> "$LOG_FILE"
    fi

    # --- Verifica se HOUVE REALMENTE atualização de imagem --- 
    IMAGE_WAS_UPDATED=false
    if $PULL_SUCCESS && echo "$PULL_OUTPUT" | grep -q -E 'Downloaded newer image|Newer image'; then
        IMAGE_WAS_UPDATED=true
        log "✅ Novas imagens baixadas para $COMPOSE_PATH."
    elif $PULL_SUCCESS; then
        log "✅ Nenhuma imagem nova baixada para $COMPOSE_PATH (apenas verificado/pull completo)."
    fi
    # --- Fim da verificação --- 

    # Só executa 'up' se uma imagem foi realmente atualizada
    if $IMAGE_WAS_UPDATED; then
        log "🚀 Executando 'docker compose up -d --remove-orphans --force-recreate' para $COMPOSE_PATH..."
        # Captura a saída e o status de saída do up
        if UP_OUTPUT=$(docker compose up -d --remove-orphans --force-recreate 2>&1); then
            log "✅ Atualizado com sucesso via 'up': $COMPOSE_PATH"
            echo "$UP_OUTPUT" >> "$LOG_FILE"
            
            # Extrai as imagens que foram efetivamente atualizadas (puxadas)
            updated_images_list=""
            while IFS= read -r line; do
                # Tenta extrair nomes de imagem da saída do pull que indicam atualização
                image_name=$(echo "$line" | grep -oE '([a-zA-Z0-9./_-]+:[a-zA-Z0-9._-]+|[a-zA-Z0-9./_-]+@sha256:[a-f0-9]+)$' || true)
                 if [[ -n "$image_name" ]]; then
                     # Evita duplicatas simples
                     if ! echo "$updated_images_list" | grep -qF "$image_name"; then
                         updated_images_list+="- $image_name\n"
                     fi
                 fi
            done < <(echo "$PULL_OUTPUT" | grep -E 'Downloaded newer image|Newer image')

            if [[ -z "$updated_images_list" ]]; then
                 updated_images_list="*(Não foi possível extrair nomes específicos das imagens atualizadas)*\n"
            fi
            ACTUAL_UPDATES_MAP["$COMPOSE_PATH"]="$updated_images_list"
            UPDATED_COMPOSE_INFO+=("$COMPOSE_PATH") # Adiciona à lista geral de sucessos

        else
            up_exit_code=$?
            ERRORS+=("Erro ao executar 'up' em $COMPOSE_PATH (Código de saída: $up_exit_code)")
            log "❌ Falha ao executar 'up': $COMPOSE_PATH (Código de saída: $up_exit_code)"
            echo "$UP_OUTPUT" >> "$LOG_FILE"
        fi
    fi

    popd > /dev/null # Retorna ao diretório anterior

done < <(find "$COMPOSE_DIR" -type f \( -name "docker-compose.yml" -o -name "docker-compose.yaml" \))

log "🧹 Limpando imagens não utilizadas..."
# Adicionado tratamento de erro para prune
if ! docker image prune -af >> "$LOG_FILE" 2>&1; then
    log "⚠️ Erro ao limpar imagens não utilizadas."
    ERRORS+=("Erro durante docker image prune -af")
fi

# --- Envio de Notificações --- 

# Notificação de SUCESSO (Apenas se houve atualizações REAIS)
if [ ${#UPDATED_COMPOSE_INFO[@]} -gt 0 ]; then
    # Usa printf para construir a mensagem com quebras de linha duplas para Markdown
    msg=$(printf "🚀 **Atualizações aplicadas com sucesso:**\n\n") 
    for path in "${UPDATED_COMPOSE_INFO[@]}"; do
        msg+=$(printf "📁 **%s**\n" "$path")
        if [[ -v ACTUAL_UPDATES_MAP["$path"] ]]; then
             # Adiciona a lista de imagens, garantindo que termine com newline
             images_info=$(printf "%s" "${ACTUAL_UPDATES_MAP["$path"]}")
             msg+=$(printf "%s\n" "$images_info") # Adiciona uma linha extra em branco após a lista de imagens
        else
             # Este caso não deveria ocorrer se entrou aqui, mas por segurança
             msg+=$(printf "  *(Detalhes da imagem não capturados)*\n\n")
        fi
    done
    log "📣 Enviando notificação de sucesso..."
    send_discord "$msg"
fi

# Notificação de ERRO (Sempre envia se houver erros)
if [ ${#ERRORS[@]} -gt 0 ]; then
    mapfile -t error_list < <(printf '%s\n' "${ERRORS[@]}")
    # Usa printf para construir a mensagem de erro com itens de lista Markdown
    error_items=$(printf -- '- %s\n' "${error_list[@]}")
    msg=$(printf "⚠️ **Erros encontrados durante a atualização:**\n%s" "$error_items")
    log "📣 Enviando notificação de erro..."
    send_discord "$msg"
fi

# Mensagem final no log se não houve atualizações nem erros
if [ ${#UPDATED_COMPOSE_INFO[@]} -eq 0 ] && [ ${#ERRORS[@]} -eq 0 ]; then
    log "✅ Verificação concluída. Nenhuma atualização de imagem encontrada e nenhum erro reportado."
fi

log "🏁 Script finalizado."
