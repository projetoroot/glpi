#!/bin/bash

################################################################################
# GLPI Agent Monitor
#
# Detecta computadores cujo GLPI Agent não comunica há X dias
# e cria automaticamente um chamado no GLPI.
#
# Requisitos:
#   - curl
#   - jq
#   - GLPI API habilitada
#
################################################################################

set -u

# ==============================================================================
# CONFIGURAÇÃO
# ==============================================================================

GLPI_URL="https://glpi.empresa.com.br"
APP_TOKEN="COLOQUE_SEU_APP_TOKEN_AQUI"
USER_TOKEN="COLOQUE_SEU_USER_TOKEN_AQUI"

# Dias sem comunicação para gerar o chamado
OFFLINE_DAYS=7

# Prioridade do chamado
# 1 = Muito baixa
# 2 = Baixa
# 3 = Média
# 4 = Alta
# 5 = Muito alta
TICKET_PRIORITY=3

# Urgência
# 1 = Muito baixa
# 2 = Baixa
# 3 = Média
# 4 = Alta
# 5 = Muito alta
TICKET_URGENCY=3

# Impacto
# 1 = Muito baixo
# 2 = Baixo
# 3 = Médio
# 4 = Alto
# 5 = Muito alto
TICKET_IMPACT=2

# Categoria do chamado.
# Coloque 0 para não definir categoria.
TICKET_CATEGORY_ID=0

# Entidade.
# 0 normalmente corresponde à entidade raiz.
TICKET_ENTITY_ID=0

# Grupo responsável.
# 0 = não atribuir grupo.
TICKET_GROUP_ID=0

# Arquivo de log
LOG_FILE="/var/log/glpi-agent-monitor.log"

# ==============================================================================
# FUNÇÕES
# ==============================================================================

log()
{
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"
}

die()
{
    log "ERRO: $*"
    exit 1
}

# ==============================================================================
# VERIFICAÇÕES
# ==============================================================================

command -v curl >/dev/null 2>&1 || die "curl não encontrado."

command -v jq >/dev/null 2>&1 || die "jq não encontrado."

if [[ "$APP_TOKEN" == "COLOQUE_SEU_APP_TOKEN_AQUI" ]]; then
    die "Configure APP_TOKEN no script."
fi

if [[ "$USER_TOKEN" == "COLOQUE_SEU_USER_TOKEN_AQUI" ]]; then
    die "Configure USER_TOKEN no script."
fi

# Remove barra final da URL
GLPI_URL="${GLPI_URL%/}"

API="${GLPI_URL}/apirest.php"

# ==============================================================================
# INICIA SESSÃO
# ==============================================================================

log "Iniciando sessão na API do GLPI..."

SESSION_RESPONSE=$(curl -sS \
    --fail \
    -X GET \
    -H "Content-Type: application/json" \
    -H "Authorization: user_token ${USER_TOKEN}" \
    -H "App-Token: ${APP_TOKEN}" \
    "${API}/initSession")

if [[ $? -ne 0 ]]; then
    die "Não foi possível iniciar sessão no GLPI."
fi

SESSION_TOKEN=$(echo "$SESSION_RESPONSE" | jq -r '.session_token // empty')

if [[ -z "$SESSION_TOKEN" ]]; then
    die "GLPI não retornou Session-Token."
fi

log "Sessão iniciada."

HEADERS=(
    -H "Content-Type: application/json"
    -H "App-Token: ${APP_TOKEN}"
    -H "Session-Token: ${SESSION_TOKEN}"
)

# ==============================================================================
# DATA LIMITE
# ==============================================================================

CUTOFF_DATE=$(date -d "-${OFFLINE_DAYS} days" '+%Y-%m-%d %H:%M:%S')

log "Considerando offline agentes sem contato desde: ${CUTOFF_DATE}"

# ==============================================================================
# BUSCA COMPUTADORES
# ==============================================================================

log "Consultando computadores..."

COMPUTERS_RESPONSE=$(curl -sS \
    --fail \
    "${HEADERS[@]}" \
    "${API}/search/Computer?range=0-9999")

if [[ $? -ne 0 ]]; then
    die "Erro ao consultar computadores."
fi

TOTAL=$(echo "$COMPUTERS_RESPONSE" | jq -r '.totalcount // 0')

log "Computadores encontrados: ${TOTAL}"

# ==============================================================================
# PROCESSAMENTO
# ==============================================================================

echo "$COMPUTERS_RESPONSE" |
jq -c '.data[]?' |
while read -r COMPUTER
do

    COMPUTER_ID=$(echo "$COMPUTER" | jq -r '.id // empty')

    if [[ -z "$COMPUTER_ID" ]]; then
        continue
    fi

    # --------------------------------------------------------------------------
    # Consulta informações completas do computador
    # --------------------------------------------------------------------------

    COMPUTER_DATA=$(curl -sS \
        --fail \
        "${HEADERS[@]}" \
        "${API}/Computer/${COMPUTER_ID}")

    if [[ $? -ne 0 ]]; then
        log "Não foi possível consultar computador ID ${COMPUTER_ID}."
        continue
    fi

    COMPUTER_NAME=$(echo "$COMPUTER_DATA" | jq -r '.name // "SEM_NOME"')

    # --------------------------------------------------------------------------
    # Consulta os agentes associados ao computador
    # --------------------------------------------------------------------------

    AGENTS=$(curl -sS \
        --fail \
        "${HEADERS[@]}" \
        "${API}/Computer/${COMPUTER_ID}/Agent")

    if [[ $? -ne 0 ]]; then
        log "Não foi possível consultar Agent do computador ${COMPUTER_NAME}."
        continue
    fi

    # Alguns computadores podem não possuir Agent.
    AGENT_COUNT=$(echo "$AGENTS" | jq 'length')

    if [[ "$AGENT_COUNT" -eq 0 ]]; then
        continue
    fi

    # --------------------------------------------------------------------------
    # Pega o agente mais recente
    # --------------------------------------------------------------------------

    AGENT_DATA=$(echo "$AGENTS" |
        jq -c 'sort_by(.last_contact // "") | last')

    LAST_CONTACT=$(echo "$AGENT_DATA" |
        jq -r '.last_contact // empty')

    AGENT_ID=$(echo "$AGENT_DATA" |
        jq -r '.id // empty')

    AGENT_VERSION=$(echo "$AGENT_DATA" |
        jq -r '.version // "desconhecida"')

    # --------------------------------------------------------------------------
    # Se não houver último contato
    # --------------------------------------------------------------------------

    if [[ -z "$LAST_CONTACT" || "$LAST_CONTACT" == "null" ]]; then
        log "[$COMPUTER_NAME] Agent sem informação de último contato."
        continue
    fi

    # --------------------------------------------------------------------------
    # Converte datas para timestamp
    # --------------------------------------------------------------------------

    LAST_TIMESTAMP=$(date -d "$LAST_CONTACT" '+%s' 2>/dev/null)

    if [[ -z "$LAST_TIMESTAMP" ]]; then
        log "[$COMPUTER_NAME] Não foi possível interpretar: $LAST_CONTACT"
        continue
    fi

    CUTOFF_TIMESTAMP=$(date -d "$CUTOFF_DATE" '+%s')

    # --------------------------------------------------------------------------
    # Agent ainda está ativo
    # --------------------------------------------------------------------------

    if (( LAST_TIMESTAMP > CUTOFF_TIMESTAMP )); then

        log "[$COMPUTER_NAME] OK - último contato: $LAST_CONTACT"

        continue
    fi

    # --------------------------------------------------------------------------
    # Agent está offline há mais de X dias
    # --------------------------------------------------------------------------

    log "[$COMPUTER_NAME] OFFLINE - último contato: $LAST_CONTACT"

    # --------------------------------------------------------------------------
    # Procura chamado existente para este computador
    #
    # A consulta usa a associação Ticket -> Computer.
    # --------------------------------------------------------------------------

    EXISTING_TICKETS=$(curl -sS \
        --fail \
        "${HEADERS[@]}" \
        "${API}/Computer/${COMPUTER_ID}?with_tickets=true")

    if [[ $? -ne 0 ]]; then
        log "[$COMPUTER_NAME] Não foi possível verificar chamados existentes."
        continue
    fi

    # --------------------------------------------------------------------------
    # Verifica chamados abertos
    #
    # Status:
    # 1 = Novo
    # 2 = Em atendimento
    # 3 = Planejado
    # 4 = Pendente
    #
    # 5 = Solucionado
    # 6 = Fechado
    # --------------------------------------------------------------------------

    OPEN_TICKET_COUNT=$(echo "$EXISTING_TICKETS" |
        jq '[.tickets[]? | select(.status == 1 or .status == 2 or .status == 3 or .status == 4)] | length')

    if [[ "$OPEN_TICKET_COUNT" -gt 0 ]]; then

        log "[$COMPUTER_NAME] Já existe chamado aberto. Nenhum novo chamado será criado."

        continue
    fi

    # --------------------------------------------------------------------------
    # Calcula há quantos dias está offline
    # --------------------------------------------------------------------------

    NOW_TIMESTAMP=$(date '+%s')

    OFFLINE_SECONDS=$((NOW_TIMESTAMP - LAST_TIMESTAMP))

    OFFLINE_DAYS_CALCULATED=$((OFFLINE_SECONDS / 86400))

    # --------------------------------------------------------------------------
    # Monta descrição
    # --------------------------------------------------------------------------

    TICKET_CONTENT=$(cat <<EOF
<p><strong>Alerta automático do GLPI Agent</strong></p>

<p>O computador abaixo não realiza comunicação com o servidor GLPI há ${OFFLINE_DAYS_CALCULATED} dias.</p>

<table>
<tr>
<td><strong>Computador</strong></td>
<td>${COMPUTER_NAME}</td>
</tr>

<tr>
<td><strong>ID GLPI</strong></td>
<td>${COMPUTER_ID}</td>
</tr>

<tr>
<td><strong>Agent ID</strong></td>
<td>${AGENT_ID}</td>
</tr>

<tr>
<td><strong>Versão do GLPI Agent</strong></td>
<td>${AGENT_VERSION}</td>
</tr>

<tr>
<td><strong>Último contato</strong></td>
<td>${LAST_CONTACT}</td>
</tr>

<tr>
<td><strong>Dias sem comunicação</strong></td>
<td>${OFFLINE_DAYS_CALCULATED}</td>
</tr>
</table>

<p><strong>Verificações recomendadas:</strong></p>

<ul>
<li>Verificar se o computador está ligado.</li>
<li>Verificar conectividade de rede.</li>
<li>Verificar se o serviço GLPI Agent está em execução.</li>
<li>Verificar o acesso ao servidor GLPI.</li>
<li>Verificar firewall local.</li>
</ul>

<p>Chamado criado automaticamente pelo monitoramento do GLPI Agent.</p>
EOF
)

    # --------------------------------------------------------------------------
    # Monta JSON do chamado
    # --------------------------------------------------------------------------

    if [[ "$TICKET_CATEGORY_ID" -gt 0 ]]; then

        TICKET_JSON=$(jq -n \
            --arg name "[GLPI Agent] Computador sem comunicação - ${COMPUTER_NAME}" \
            --arg content "$TICKET_CONTENT" \
            --argjson entity "$TICKET_ENTITY_ID" \
            --argjson priority "$TICKET_PRIORITY" \
            --argjson urgency "$TICKET_URGENCY" \
            --argjson impact "$TICKET_IMPACT" \
            --argjson category "$TICKET_CATEGORY_ID" \
            '{
                input: {
                    name: $name,
                    content: $content,
                    entities_id: $entity,
                    priority: $priority,
                    urgency: $urgency,
                    impact: $impact,
                    itilcategories_id: $category
                }
            }')

    else

        TICKET_JSON=$(jq -n \
            --arg name "[GLPI Agent] Computador sem comunicação - ${COMPUTER_NAME}" \
            --arg content "$TICKET_CONTENT" \
            --argjson entity "$TICKET_ENTITY_ID" \
            --argjson priority "$TICKET_PRIORITY" \
            --argjson urgency "$TICKET_URGENCY" \
            --argjson impact "$TICKET_IMPACT" \
            '{
                input: {
                    name: $name,
                    content: $content,
                    entities_id: $entity,
                    priority: $priority,
                    urgency: $urgency,
                    impact: $impact
                }
            }')

    fi

    # --------------------------------------------------------------------------
    # CRIA CHAMADO
    # --------------------------------------------------------------------------

    log "[$COMPUTER_NAME] Criando chamado..."

    TICKET_RESPONSE=$(curl -sS \
        --fail \
        -X POST \
        "${HEADERS[@]}" \
        -d "$TICKET_JSON" \
        "${API}/Ticket")

    if [[ $? -ne 0 ]]; then

        log "[$COMPUTER_NAME] ERRO ao criar chamado."

        continue
    fi

    TICKET_ID=$(echo "$TICKET_RESPONSE" |
        jq -r '.id // empty')

    if [[ -z "$TICKET_ID" ]]; then

        log "[$COMPUTER_NAME] GLPI não retornou ID do chamado."
        log "Resposta: $TICKET_RESPONSE"

        continue
    fi

    log "[$COMPUTER_NAME] Chamado criado: #${TICKET_ID}"

    # --------------------------------------------------------------------------
    # VINCULA COMPUTADOR AO CHAMADO
    # --------------------------------------------------------------------------

    ITEM_JSON=$(jq -n \
        --argjson item_id "$COMPUTER_ID" \
        --argjson ticket_id "$TICKET_ID" \
        '{
            input: {
                itemtype: "Computer",
                items_id: $item_id,
                tickets_id: $ticket_id
            }
        }')

    ITEM_RESPONSE=$(curl -sS \
        --fail \
        -X POST \
        "${HEADERS[@]}" \
        -d "$ITEM_JSON" \
        "${API}/Ticket/${TICKET_ID}/Item_Ticket")

    if [[ $? -eq 0 ]]; then

        log "[$COMPUTER_NAME] Computador associado ao chamado #${TICKET_ID}."

    else

        log "[$COMPUTER_NAME] AVISO: não foi possível associar o computador ao chamado."

    fi

done

# ==============================================================================
# ENCERRA SESSÃO
# ==============================================================================

curl -sS \
    -X GET \
    "${HEADERS[@]}" \
    "${API}/killSession" >/dev/null 2>&1

log "Processamento concluído."
