# Docker Compose Auto-Updater & Notifier

Este script Bash automatiza o processo de atualização de aplicações gerenciadas por Docker Compose, notificando sobre sucessos e falhas através de um webhook do Discord.

## Funcionalidades

*   **Verificação Automática:** Percorre recursivamente um diretório especificado em busca de arquivos `docker-compose.yml` ou `docker-compose.yaml`.
*   **Pull de Imagens:** Executa `docker compose pull` para baixar as versões mais recentes das imagens definidas nos arquivos compose.
*   **Atualização Inteligente:** Se novas imagens forem baixadas, o script executa `docker compose up -d --remove-orphans --force-recreate` para reiniciar os serviços com as novas imagens.
*   **Notificações Detalhadas no Discord:** Envia mensagens formatadas para um webhook do Discord informando:
    *   Quais projetos (diretórios de compose) foram atualizados com sucesso.
    *   Quais serviços e imagens específicas foram alteradas em cada projeto atualizado.
    *   Quais erros ocorreram durante o processo (falha ao acessar diretório, falha no pull, falha no up, falha na limpeza de imagens).
*   **Limpeza Automática:** Executa `docker image prune -af` para remover imagens Docker não utilizadas após as atualizações.
*   **Logging:** Mantém um arquivo de log diário em `/var/log/docker-updater/` com detalhes de todas as operações.

## Pré-requisitos

Para utilizar este script, certifique-se de que os seguintes componentes estão instalados no seu sistema:

*   **Bash:** Versão 4 ou superior (devido ao uso de arrays associativos e `mapfile`). Verifique com `bash --version`.
*   **Docker:** O motor Docker precisa estar instalado e rodando. Verifique com `docker --version`.
*   **Docker Compose:** A versão V2 do Docker Compose (comando `docker compose`) é necessária. Verifique com `docker compose version`.
*   **curl:** Ferramenta para transferir dados com URLs, usada para enviar notificações ao Discord. Geralmente já vem instalado na maioria das distribuições Linux.
*   **jq:** Processador JSON leve de linha de comando, usado para formatar o payload da notificação do Discord. Instale via gerenciador de pacotes (ex: `sudo apt install jq` ou `sudo yum install jq`).
*   **find:** Utilitário padrão do Linux para buscar arquivos.

## Configuração

Antes de executar o script, ajuste as seguintes variáveis no início do arquivo `docker-update.sh`:

*   `COMPOSE_DIR`: Defina o caminho absoluto para o diretório principal que contém os subdiretórios com seus arquivos `docker-compose.yml`.
    ```bash
    COMPOSE_DIR="/app/docker"
    ```
*   `LOG_DIR`: O diretório onde os arquivos de log diários serão armazenados. O script tentará criar este diretório se ele não existir.
    ```bash
    LOG_DIR="/var/log/docker-updater"
    ```
*   `DISCORD_WEBHOOK`: Substitua pela URL completa do seu webhook do Discord.
    ```bash
    DISCORD_WEBHOOK="https://discord.com/api/webhooks/SEU_ID/SEU_TOKEN"
    ```

## Uso

1.  **Salve o Script:** Salve o conteúdo do script em um arquivo, por exemplo, `/app/cron/docker-update.sh`.
2.  **Dê Permissão de Execução:**
    ```bash
    chmod +x /app/cron/docker-update.sh
    ```
3.  **Execução Manual:**
    Você pode executar o script manualmente a qualquer momento:
    ```bash
    /bin/bash /app/cron/docker-update.sh
    ```
4.  **Agendamento com Cron:**
    Para executar o script periodicamente, adicione uma entrada ao crontab do usuário que deve executar o script (geralmente `root` se o script interage com o Docker daemon).

    *   Abra o editor de crontab:
        ```bash
        # Use 'sudo' se precisar rodar como root
        sudo crontab -e
        # Ou, para usar o editor nano:
        sudo EDITOR=nano crontab -e
        ```
    *   Adicione uma linha para definir o agendamento. Exemplos:
        *   **A cada 10 minutos:**
            ```cron
            */10 * * * * /bin/bash /app/cron/docker-update.sh >> /var/log/docker-updater/cron.log 2>&1
            ```
        *   **Diariamente às 04:05:**
            ```cron
            5 4 * * * /bin/bash /app/cron/docker-update.sh >> /var/log/docker-updater/cron.log 2>&1
            ```
        *   **Às 06:00, 12:00, 18:00 e 00:00:**
            ```cron
            0 6,12,18,0 * * * /bin/bash /app/cron/docker-update.sh >> /var/log/docker-updater/cron.log 2>&1
            ```
    *   Salve e feche o editor.

    **Nota:** O redirecionamento `>> /var/log/docker-updater/cron.log 2>&1` captura a saída padrão e de erro da execução do cron em um arquivo separado, útil para depuração. O script em si já loga suas operações internas no arquivo `$LOG_FILE`.

## Exemplo de Notificações no Discord

**Sucesso:**
```
🚀 **Atualizações aplicadas nos seguintes composes:** 

📁 **/app/docker/meu-app-legal**
*   webserver: 
    nginx:1.25-alpine
*   backend: 
    minha-api:v1.2.1

📁 **/app/docker/monitoramento**
*   prometheus: 
    prom/prometheus:v2.45.0
*   grafana: 
    grafana/grafana:9.5.3 (Novo)

```

**Erro:**
```
⚠️ **Erros durante atualização:** 
* Erro ao acessar /app/docker/projeto-antigo
* Erro no pull em /app/docker/servico-externo
* Erro ao atualizar /app/docker/banco-dados (Código de saída: 1)
* Erro durante docker image prune -af
```

## Considerações sobre Rolling Updates

Este script atualiza os serviços definidos em cada arquivo `docker-compose.yml` usando `docker compose up --force-recreate`. Isso geralmente para e recria os containers que precisam ser atualizados, o que pode causar uma breve interrupção para os serviços daquele compose específico.

O script processa um arquivo compose de cada vez, então diferentes projetos (em diferentes subdiretórios) não são atualizados simultaneamente.

Para implementações de rolling update mais sofisticadas (atualizar instâncias de um serviço uma por vez dentro do mesmo compose, com verificações de saúde), considere usar orquestradores como Docker Swarm ou Kubernetes.

## Licença

[Sinta-se à vontade para adicionar uma licença aqui, como a MIT License.]
