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

# Função revisada para enviar notificações ao Discord, tratando melhor as quebras de linha
send_discord() {
    local message="$1"
    # Escapa aspas duplas e barras invertidas na mensagem para o JSON
    local json_message
    json_message=$(echo "$message" | sed 's/\\/\\\\/g' | sed 's/"/\\"/g')
    # Substitui novas linhas literais por \n para o JSON
    json_message=$(echo "$json_message" | awk '{printf "%s\\n", $0}' | sed 's/\\n$//')

    # Monta o payload JSON manualmente com printf para garantir a formatação correta
    local payload
    payload=$(printf '{"content": "%s"}' "$json_message")

    # Envia usando curl, passando o payload via stdin
    if ! echo "$payload" | curl -s -f -H "Content-Type: application/json" \
         -X POST \
         -d @- \
         "$DISCORD_WEBHOOK" > /dev/null; then
        log "❌ Falha ao enviar notificação para o Discord."
    fi
}

log "🔄 Iniciando verificação de atualizações de containers Docker..."

# Inicializa arrays e array associativo (requer Bash 4+)
UPDATED_COMPOSE_PATHS=()
ERRORS=()
declare -A PULLED_IMAGES_MAP # Armazena imagens que foram efetivamente puxadas/atualizadas

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
        # Não continua aqui, ainda pode haver atualizações parciais ou necessidade de 'up'
    else
        log "Resultado do pull para $COMPOSE_PATH: Sucesso (verificar logs para detalhes)"
        echo "$PULL_OUTPUT" >> "$LOG_FILE"
    fi

    # --- Extrair imagens atualizadas/puxadas da saída do PULL --- 
    pulled_images_list=""
    # Procura por linhas indicando download ou pull completo
    # Ajuste o padrão grep/awk conforme necessário para sua versão do Docker Compose
    while IFS= read -r line; do
        # Exemplo: Extrair de linhas como "Pulled meu-servico" ou "Downloaded newer image for minha/imagem:tag"
        # Este grep/awk é um exemplo, pode precisar de ajuste fino
        image_name=$(echo "$line" | grep -oE '([a-zA-Z0-9./_-]+:[a-zA-Z0-9._-]+|[a-zA-Z0-9./_-]+@sha256:[a-f0-9]+)$' || true)
        if [[ -z "$image_name" ]]; then
             # Tenta extrair de linhas como 'Pulled <serviço>' pegando a imagem do compose file (mais complexo)
             # Ou simplesmente pega a linha inteira como indicação
             image_name=$(echo "$line" | awk '{print $NF}') # Pega a última palavra como fallback
        fi
        if [[ -n "$image_name" ]]; then
             # Evita duplicatas simples
             if ! echo "$pulled_images_list" | grep -qF "$image_name"; then
                 pulled_images_list+="* $image_name\n"
             fi
        fi
    done < <(echo "$PULL_OUTPUT" | grep -E 'Downloaded newer image|Pulled|Layer already exists|Digest:')
    # --- Fim da extração --- 

    # Verifica se o PULL teve sucesso E se houve output indicando novas imagens
    # A condição `grep -q` é uma heurística, pode precisar de ajuste
    NEEDS_UP=false
    if $PULL_SUCCESS && echo "$PULL_OUTPUT" | grep -q -E 'Downloaded newer image|Pulled'; then
        NEEDS_UP=true
        log "🔄 Novas imagens detectadas para $COMPOSE_PATH, subindo containers..."
    elif ! $PULL_SUCCESS; then
        # Mesmo se o pull falhou, tenta um 'up' para garantir que os serviços estejam rodando (opcional)
        # NEEDS_UP=true
        # log "⚠️ Pull falhou, tentando 'up -d' para garantir estado..."
        log "⚠️ Pull falhou para $COMPOSE_PATH. Pulando 'up'."
    else
        log "✅ Nenhuma atualização de imagem encontrada para: $COMPOSE_PATH"
    fi

    if $NEEDS_UP; then
        log "🚀 Executando 'docker compose up -d --remove-orphans --force-recreate' para $COMPOSE_PATH..."
        # Captura a saída e o status de saída do up
        if UP_OUTPUT=$(docker compose up -d --remove-orphans --force-recreate 2>&1); then
            log "✅ Atualizado com sucesso: $COMPOSE_PATH"
            echo "$UP_OUTPUT" >> "$LOG_FILE"
            UPDATED_COMPOSE_PATHS+=("$COMPOSE_PATH")
            # Armazena a lista de imagens puxadas para este compose
            if [[ -n "$pulled_images_list" ]]; then
                PULLED_IMAGES_MAP["$COMPOSE_PATH"]="$pulled_images_list"
            else
                # Se não conseguiu extrair, coloca uma mensagem genérica
                PULLED_IMAGES_MAP["$COMPOSE_PATH"]="*(Nenhuma imagem específica detectada na saída do pull)*\n"
            fi
        else
            up_exit_code=$?
            ERRORS+=("Erro ao atualizar $COMPOSE_PATH (Código de saída: $up_exit_code)")
            log "❌ Falha ao atualizar: $COMPOSE_PATH (Código de saída: $up_exit_code)"
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

# Verifica e envia notificações
if [ ${#UPDATED_COMPOSE_PATHS[@]} -gt 0 ]; then
    # Usa printf para construir a mensagem com quebras de linha literais
    msg=$(printf "🚀 **Atualizações aplicadas nos seguintes composes:**\n\n")
    for path in "${UPDATED_COMPOSE_PATHS[@]}"; do
        msg+=$(printf "📁 **%s**\n" "$path")
        if [[ -v PULLED_IMAGES_MAP["$path"] ]]; then
             # Adiciona a lista de imagens, garantindo que termine com newline
             images_info=$(printf "%s" "${PULLED_IMAGES_MAP["$path"]}")
             msg+=$(printf "%s\n" "$images_info")
        else
             msg+=$(printf "  *(Detalhes da imagem não capturados)*\n\n")
        fi
    done
    log "📣 Enviando notificação de sucesso..."
    send_discord "$msg"
fi

if [ ${#ERRORS[@]} -gt 0 ]; then
    mapfile -t error_list < <(printf '%s\n' "${ERRORS[@]}")
    # Usa printf para construir a mensagem de erro
    error_items=$(printf '* %s\n' "${error_list[@]}")
    msg=$(printf "⚠️ **Erros durante atualização:**\n%s" "$error_items")
    log "📣 Enviando notificação de erro..."
    send_discord "$msg"
fi

log "✅ Script finalizado."
