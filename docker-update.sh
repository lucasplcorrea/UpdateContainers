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

# Inicializa arrays e array associativo (requer Bash 4+)
UPDATED_COMPOSE_PATHS=()
ERRORS=()
declare -A UPDATED_IMAGES_MAP

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

    # --- Capturar imagens atuais ANTES do pull --- 
    declare -A current_images
    log "🔎 Capturando imagens atuais para $COMPOSE_PATH..."
    # Usar 'docker compose ps' para obter serviços e suas imagens atuais
    # O estado pode ser 'running', 'exited', etc. Incluímos todos.
    while IFS= read -r line; do
        # Ignora linha de cabeçalho ou linhas vazias
        [[ -z "$line" || "$line" == NAME* ]] && continue
        # Extrai nome do serviço e imagem (ajuste os índices se necessário)
        service_name=$(echo "$line" | awk '{print $1}') # Assume que o nome do serviço é a primeira coluna
        image_name=$(echo "$line" | awk '{print $2}')   # Assume que a imagem é a segunda coluna
        if [[ -n "$service_name" && -n "$image_name" ]]; then
            current_images["$service_name"]="$image_name"
            # log "  -> Serviço: $service_name, Imagem Atual: $image_name" # Log detalhado (opcional)
        fi
    done < <(docker compose ps --format "{{.Name}} {{.Image}}" 2>/dev/null || true) # Ignora erro se não houver containers rodando
    # --- Fim da captura de imagens atuais --- 

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
    if echo "$OUTPUT" | grep -q -E 'Pull complete|Downloaded newer image|Newer image'; then
        log "🔄 Atualizações encontradas para $COMPOSE_PATH, subindo novos containers com --force-recreate..."
        # Captura a saída e o status de saída do up
        if UP_OUTPUT=$(docker compose up -d --remove-orphans --force-recreate 2>&1); then
            log "✅ Atualizado com sucesso: $COMPOSE_PATH"
            echo "$UP_OUTPUT" >> "$LOG_FILE"
            UPDATED_COMPOSE_PATHS+=("$COMPOSE_PATH")

            # --- Comparar imagens após 'up' --- 
            log "🔎 Verificando imagens atualizadas para $COMPOSE_PATH..."
            updated_images_list=""
            while IFS= read -r line; do
                [[ -z "$line" || "$line" == NAME* ]] && continue
                service_name=$(echo "$line" | awk '{print $1}')
                new_image_name=$(echo "$line" | awk '{print $2}')
                if [[ -n "$service_name" && -n "$new_image_name" ]]; then
                    current_image=${current_images["$service_name"]}
                    # Compara imagem antiga com a nova. Adiciona à lista se diferente.
                    if [[ -n "$current_image" && "$current_image" != "$new_image_name" ]]; then
                        log "  -> Serviço atualizado: $service_name ( $current_image -> $new_image_name )"
                        updated_images_list+="* $service_name: 
    $new_image_name\n"
                    elif [[ -z "$current_image" && -n "$new_image_name" ]]; then
                         # Caso o serviço não existia antes (novo serviço ou primeiro 'up')
                         log "  -> Novo serviço/imagem: $service_name ($new_image_name)"
                         updated_images_list+="* $service_name: 
    $new_image_name (Novo)\n"
                    fi
                fi
            done < <(docker compose ps --format "{{.Name}} {{.Image}}" 2>/dev/null || true)
            
            if [[ -n "$updated_images_list" ]]; then
                 UPDATED_IMAGES_MAP["$COMPOSE_PATH"]="$updated_images_list"
            fi
            # --- Fim da comparação --- 

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
if [ ${#UPDATED_COMPOSE_PATHS[@]} -gt 0 ]; then
    msg="🚀 **Atualizações aplicadas nos seguintes composes:** \n\n"
    for path in "${UPDATED_COMPOSE_PATHS[@]}"; do
        msg+="📁 **$path**\n"
        if [[ -v UPDATED_IMAGES_MAP["$path"] ]]; then
             msg+="${UPDATED_IMAGES_MAP["$path"]}\n"
        else
             msg+="  *(Detalhes da imagem não capturados)*\n\n"
        fi
    done
    log "📣 Enviando notificação de sucesso..."
    send_discord "$msg"
fi

if [ ${#ERRORS[@]} -gt 0 ]; then
    # Usando mapfile/readarray para construir a mensagem de forma mais segura (requer Bash 4+)
    mapfile -t error_list < <(printf '%s\n' "${ERRORS[@]}")
    # Adicionado espaço antes do \n
    msg="⚠️ **Erros durante atualização:** \n$(printf '* %s\n' "${error_list[@]}")"
    log "📣 Enviando notificação de erro..."
    send_discord "$msg"
fi

log "✅ Script finalizado."
