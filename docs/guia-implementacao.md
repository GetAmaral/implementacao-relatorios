# IMPLEMENTAÇÃO — Sistema de Nudge Relatório Mensal v2

**Data:** 2026-03-30
**Versão:** 2.0 — Copy-paste ready

---

## MAPA DO FLUXO COMPLETO

```
                    ┌─────────────────────────────────────────┐
                    │          DIA 1 DO MÊS (00:05 BRT)       │
                    │                                         │
                    │  pg_cron OU N8N Schedule Trigger         │
                    │    → mark_monthly_report_eligible()      │
                    │    → UPDATE profiles                     │
                    │       SET pending = true                 │
                    │           nudge_month = '2026-03-01'     │
                    │       WHERE premium + ativo + gastos     │
                    └──────────────────┬──────────────────────┘
                                       │
                    ┌──────────────────▼──────────────────────┐
                    │      USER MANDA MENSAGEM QUALQUER       │
                    │                                         │
                    │  Main Workflow recebe no webhook         │
                    │    → Edit Fields extrai texto/button     │
                    └──────────────────┬──────────────────────┘
                                       │
                          ┌────────────▼────────────┐
                          │  É resposta de botão     │
                          │  de relatório?           │
                          │  (Switch node)           │
                          └─┬──────────┬──────────┬─┘
                            │          │          │
                  ┌─────────▼──┐  ┌───▼────┐  ┌──▼─────────────┐
                  │ report_sim │  │report_  │  │ default        │
                  │ _YYYY-MM   │  │nao     │  │ (não é botão   │
                  │            │  │        │  │  de relatório) │
                  └─────┬──────┘  └───┬────┘  └──┬─────────────┘
                        │             │           │
                        ▼             ▼           ▼
                  Busca profile  "Sem          FLUXO NORMAL
                  Calcula mês   problemas!"   If → If3 → Get a row
                  POST /report                → If8 → If9 → setar_user
                  "Gerando..."                         │
                  Log aceito                           │
                                              ┌───────▼───────────┐
                                              │    setar_user      │
                                              │  (2 saídas em     │
                                              │   paralelo)       │
                                              └──┬─────────────┬──┘
                                                 │             │
                                    ┌────────────▼──┐    ┌────▼──────────────┐
                                    │ Premium User   │    │ Consume Nudge RPC │
                                    │ (Fire&Forget   │    │ (atômico)         │
                                    │  ao Fix        │    │                   │
                                    │  Conflito v2)  │    │ consumed=true?    │
                                    │                │    │   → Fire nudge    │
                                    │ ZERO MUDANÇAS  │    │     webhook       │
                                    └────────────────┘    │ consumed=false?   │
                                           │              │   → nada          │
                                           │              └────────┬──────────┘
                                           │                       │
                                           ▼                       ▼
                                    Fix Conflito v2          Nudge Workflow
                                    processa msg             (separado)
                                    normalmente                    │
                                           │                       │
                                           ▼                  Wait 10s
                                    Resposta WhatsApp              │
                                    "✅ Gasto registrado"          ▼
                                    (t = ~5s)              Interactive Button
                                                           "📊 Relatório de
                                                            Março disponível?"
                                                           [Sim] [Agora não]
                                                           (t = ~10s)
```

---

## ONDE PODE TER COMPLICAÇÃO

### Nível 1 — Simples (SQL no Supabase)

| Passo | Risco | Cuidado |
|-------|-------|---------|
| ALTER TABLE profiles | Nenhum | Colunas com DEFAULT, sem downtime |
| CREATE FUNCTION mark_monthly_report_eligible | Nenhum | Testar com SELECT antes de agendar |
| CREATE FUNCTION consume_monthly_nudge | Nenhum | Testar com UUID real |
| CREATE FUNCTION clear_nudge_on_report | Nenhum | Simples UPDATE |

### Nível 2 — Moderado (Novo Workflow Nudge)

| Passo | Risco | Cuidado |
|-------|-------|---------|
| Criar workflow novo | Nenhum | Workflow isolado, não afeta nada existente |
| Webhook node | Baixo | Lembrar de ativar o workflow e copiar o path gerado |
| Wait node | Nenhum | Apenas delay |
| HTTP Request WhatsApp | **MÉDIO** | Usar credential `"z-api marcio"` (httpHeaderAuth ID: `nuraEsunXXhjSpGT`). É o Bearer token do WhatsApp |
| Code node | Baixo | Copiar código exatamente como está |

### Nível 3 — Precisa atenção (Main Workflow)

| Passo | Risco | Cuidado |
|-------|-------|---------|
| Inserir Switch após Edit Fields | **ALTO** | Precisa DESCONECTAR Edit Fields → If e RECONECTAR via Switch. Se errar a reconexão, todo o fluxo quebra |
| Referências $('trigger-whatsapp') | **MÉDIO** | O button_reply.id pode ser undefined se msg não for interactive. Usar optional chaining `?.` |
| Branch paralela do setar_user | **MÉDIO** | Adicionar SEGUNDA conexão de saída. Não remover a existente (Premium User) |
| HTTP POST ao Supabase RPC | Baixo | Usar service_role key, Content-Type application/json |
| HTTP POST ao webhook-report | **MÉDIO** | Usar credential `"Basic Auth Google"` (httpBasicAuth ID: `f031WiARtCEWQuVs`). Sem isso = 401 |
| Buscar profile para report_sim | Baixo | Precisamos do UUID, mas na path do button só temos phone |

### Nível 4 — Delicado (Modificar Report Workflow)

| Passo | Risco | Cuidado |
|-------|-------|---------|
| Inserir node entre buscar-perfil e Update a row8 | **MÉDIO** | Precisa desconectar e reconectar. Testar que o fluxo continua funcionando |

### Nível 5 — Opcional (Desativar sistema antigo)

| Passo | Risco | Cuidado |
|-------|-------|---------|
| Alterar Set nodes WT-MT/WF-MF/WT-MF/WF-MT | Baixo | Só muda o texto. Reversível |

---

## FASE 1: SQL (Supabase SQL Editor)

Abrir o Supabase Dashboard → SQL Editor → New Query → Colar e executar:

```sql
-- ==========================================================
-- FASE 1: ESTRUTURA
-- Executar no Supabase SQL Editor (banco Principal)
-- URL: https://supabase.com/dashboard/project/ldbdtakddxznfridsarn/sql
-- ==========================================================

-- 1.1 Novas colunas na tabela profiles
ALTER TABLE profiles
ADD COLUMN IF NOT EXISTS pending_monthly_report boolean DEFAULT false,
ADD COLUMN IF NOT EXISTS nudge_report_month date DEFAULT NULL;


-- 1.2 Function: marcar users elegíveis (roda todo dia 1)
CREATE OR REPLACE FUNCTION mark_monthly_report_eligible()
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  affected integer;
  target_month date;
BEGIN
  -- Forçar timezone brasileiro para cálculos corretos
  PERFORM set_config('timezone', 'America/Sao_Paulo', true);

  -- Mês-alvo = primeiro dia do mês anterior
  target_month := date_trunc('month', now() - interval '1 month')::date;

  -- Resetar flags antigas (users que não mandaram msg no ciclo anterior)
  UPDATE profiles
  SET pending_monthly_report = false, nudge_report_month = NULL
  WHERE pending_monthly_report = true;

  -- Marcar elegíveis
  UPDATE profiles
  SET pending_monthly_report = true, nudge_report_month = target_month
  WHERE id IN (
    SELECT DISTINCT fk_user FROM spent
    WHERE date_spent >= target_month
      AND date_spent < (target_month + interval '1 month')
  )
  AND plan_type = 'premium'
  AND plan_status = true;

  GET DIAGNOSTICS affected = ROW_COUNT;
  RETURN affected;
END;
$$;


-- 1.3 Function: consumir nudge (atômico — impede race condition)
CREATE OR REPLACE FUNCTION consume_monthly_nudge(p_user_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  result_month date;
BEGIN
  UPDATE profiles
  SET pending_monthly_report = false
  WHERE id = p_user_id AND pending_monthly_report = true
  RETURNING nudge_report_month INTO result_month;

  IF NOT FOUND THEN
    RETURN '{"consumed": false}'::jsonb;
  END IF;

  RETURN jsonb_build_object('consumed', true, 'report_month', result_month);
END;
$$;


-- 1.4 Function: limpar flag quando relatório gerado por qualquer caminho
CREATE OR REPLACE FUNCTION clear_nudge_on_report(p_user_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
  UPDATE profiles
  SET pending_monthly_report = false, nudge_report_month = NULL
  WHERE id = p_user_id AND pending_monthly_report = true;
END;
$$;
```

### Teste manual (rodar DEPOIS do SQL acima):

```sql
-- Ver quantos users seriam marcados agora
SELECT COUNT(DISTINCT s.fk_user) as elegiveis
FROM spent s
JOIN profiles p ON p.id = s.fk_user
WHERE s.date_spent >= date_trunc('month', now() - interval '1 month')
  AND s.date_spent < date_trunc('month', now())
  AND p.plan_type = 'premium'
  AND p.plan_status = true;

-- Executar marcação manual para testar
SELECT mark_monthly_report_eligible();

-- Verificar quem foi marcado
SELECT id, name, phone, pending_monthly_report, nudge_report_month
FROM profiles
WHERE pending_monthly_report = true;

-- Testar consume atômico (substituir UUID real)
-- SELECT consume_monthly_nudge('2eb4065b-280c-4a50-8b54-4f9329bda0ff');
```

---

## FASE 2: NOVO WORKFLOW "Nudge Relatório Mensal"

No N8N DEV (http://76.13.172.17:5678), criar um **novo workflow**.

**Nome:** `Nudge Relatório Mensal`
**Tags:** nudge, relatório, mensal

### Node 1: Schedule Trigger

```
Tipo: Schedule Trigger
Nome: trigger-mensal-nudge

Configuração:
  Rule → Interval:
    Field: months
    Months Between Triggers: 1
    Trigger at Day of Month: 1
    Trigger at Hour: 0
    Trigger at Minute: 5
```

### Node 2: Marcar Elegíveis (HTTP Request)

```
Tipo: HTTP Request
Nome: Marcar Elegíveis

Method: POST
URL: https://ldbdtakddxznfridsarn.supabase.co/rest/v1/rpc/mark_monthly_report_eligible
Authentication: Generic Credential Type → HTTP Header Auth
  Credential: *** (criar um Header Auth com name="apikey" value="{SERVICE_ROLE_KEY}")

  ⚠️ ALTERNATIVA MAIS FÁCIL: Sem usar credencial do N8N, enviar headers manuais:

Send Headers: ON
Headers:
  apikey = eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImxkYmR0YWtrZHh6bmZyaWRzYXJuIiwicm9sZSI6InNlcnZpY2Vfcm9sZSIsImlhdCI6MTc1MzgxMTU3OCwiZXhwIjoyMDY5Mzg3NTc4fQ.sgZAmagW59WkngAIbI5QX5X05sfdmRF-PPsdxO1mwTE
  Authorization = Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImxkYmR0YWtrZHh6bmZyaWRzYXJuIiwicm9sZSI6InNlcnZpY2Vfcm9sZSIsImlhdCI6MTc1MzgxMTU3OCwiZXhwIjoyMDY5Mzg3NTc4fQ.sgZAmagW59WkngAIbI5QX5X05sfdmRF-PPsdxO1mwTE
  Content-Type = application/json

Send Body: ON
Body Content Type: JSON
JSON Body: {}

Options: (vazio)
```

**Conexão:** `trigger-mensal-nudge` → `Marcar Elegíveis`

### Node 3: Log Marcação (HTTP Request)

```
Tipo: HTTP Request
Nome: Log Marcação

Method: POST
URL: https://hkzgttizcfklxfafkzfl.supabase.co/rest/v1/log_total

Send Headers: ON
Headers:
  apikey = eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Imhremd0dGl6Y2ZrbHhmYWZremZsIiwicm9sZSI6InNlcnZpY2Vfcm9sZSIsImlhdCI6MTc3MDIwODYwMSwiZXhwIjoyMDg1Nzg0NjAxfQ._DkH_9A7E1xe6WXOsWNKSWgsRcYJfxjhyTvpXFm23ok
  Authorization = Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Imhremd0dGl6Y2ZrbHhmYWZremZsIiwicm9sZSI6InNlcnZpY2Vfcm9sZSIsImlhdCI6MTc3MDIwODYwMSwiZXhwIjoyMDg1Nzg0NjAxfQ._DkH_9A7E1xe6WXOsWNKSWgsRcYJfxjhyTvpXFm23ok
  Content-Type = application/json
  Prefer = return=minimal

Send Body: ON
Specify Body: JSON
```

JSON Body:
```json
={{ {
  user_id: 'system',
  acao: 'nudge_mensal_marcados',
  mensagem: $json + ' users marcados para nudge de relatório mensal',
  categoria: 'sistema'
} }}
```

**Conexão:** `Marcar Elegíveis` → `Log Marcação`

---

### Node 4: Webhook (Entry 2)

```
Tipo: Webhook
Nome: webhook-nudge

HTTP Method: POST
Path: nudge-relatorio
Authentication: Basic Auth
  Credential: "Basic Auth Google" (ID: f031WiARtCEWQuVs)
```

⚠️ **IMPORTANTE:** Após salvar, o N8N gera um path completo. Anote-o: será algo como `http://76.13.172.17:5678/webhook/nudge-relatorio`. Se o path mudar para um UUID, use esse UUID na chamada do Main workflow.

### Node 5: Wait

```
Tipo: Wait
Nome: Esperar Resposta

Resume: After Time Interval
Amount: 10
Unit: Seconds
```

**Conexão:** `webhook-nudge` → `Esperar Resposta`

### Node 6: Formatar Mês (Code)

```
Tipo: Code
Nome: Formatar Mês
Language: JavaScript
```

Código:

```javascript
const body = $input.first().json.body || $input.first().json;
const reportMonth = body.report_month; // "2026-03-01"

const mesesPt = [
  'janeiro', 'fevereiro', 'março', 'abril', 'maio', 'junho',
  'julho', 'agosto', 'setembro', 'outubro', 'novembro', 'dezembro'
];

// Parse da data
const date = new Date(reportMonth + 'T12:00:00Z');
const mesIdx = date.getMonth(); // 0-indexed
const ano = date.getFullYear();
const mesNome = mesesPt[mesIdx];
const mesFormatado = mesNome.charAt(0).toUpperCase() + mesNome.slice(1) + ' de ' + ano;

// ID para o botão: YYYY-MM
const mesId = ano + '-' + String(mesIdx + 1).padStart(2, '0');

return [{
  json: {
    phone: body.phone,
    nome: body.nome,
    user_id: body.user_id,
    mesFormatado,  // "Março de 2026"
    mesId          // "2026-03"
  }
}];
```

**Conexão:** `Esperar Resposta` → `Formatar Mês`

### Node 7: Enviar Nudge WhatsApp (HTTP Request)

```
Tipo: HTTP Request
Nome: Enviar Nudge WhatsApp

Method: POST
URL: https://graph.facebook.com/v23.0/744582292082931/messages
Authentication: Generic Credential Type → HTTP Header Auth
  Credential: "z-api marcio" (ID: nuraEsunXXhjSpGT)

Send Headers: ON
Headers:
  Content-Type = application/json

Send Body: ON
Specify Body: JSON
```

JSON Body (copiar EXATAMENTE):

```
={{ {
  messaging_product: 'whatsapp',
  to: $json.phone,
  type: 'interactive',
  interactive: {
    type: 'button',
    body: {
      text: '📊 Seu resumo financeiro de ' + $json.mesFormatado + ' está pronto!\n\nDeseja receber o relatório completo em PDF?'
    },
    action: {
      buttons: [
        {
          type: 'reply',
          reply: { id: 'report_sim_' + $json.mesId, title: 'Sim, quero!' }
        },
        {
          type: 'reply',
          reply: { id: 'report_nao', title: 'Agora não' }
        }
      ]
    }
  }
} }}
```

**Conexão:** `Formatar Mês` → `Enviar Nudge WhatsApp`

### Node 8: Log Nudge Enviado (HTTP Request)

```
Tipo: HTTP Request
Nome: Log Nudge Enviado

Method: POST
URL: https://hkzgttizcfklxfafkzfl.supabase.co/rest/v1/log_total

Send Headers: ON
Headers:
  apikey = eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Imhremd0dGl6Y2ZrbHhmYWZremZsIiwicm9sZSI6InNlcnZpY2Vfcm9sZSIsImlhdCI6MTc3MDIwODYwMSwiZXhwIjoyMDg1Nzg0NjAxfQ._DkH_9A7E1xe6WXOsWNKSWgsRcYJfxjhyTvpXFm23ok
  Authorization = Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Imhremd0dGl6Y2ZrbHhmYWZremZsIiwicm9sZSI6InNlcnZpY2Vfcm9sZSIsImlhdCI6MTc3MDIwODYwMSwiZXhwIjoyMDg1Nzg0NjAxfQ._DkH_9A7E1xe6WXOsWNKSWgsRcYJfxjhyTvpXFm23ok
  Content-Type = application/json
  Prefer = return=minimal

Send Body: ON
Specify Body: JSON
```

JSON Body:

```
={{ {
  user_id: $('Formatar Mês').item.json.user_id,
  acao: 'nudge_mensal_enviado',
  mensagem: 'Nudge relatório ' + $('Formatar Mês').item.json.mesFormatado + ' enviado',
  categoria: 'nudge'
} }}
```

**Conexão:** `Enviar Nudge WhatsApp` → `Log Nudge Enviado`

### Ativar workflow

Após criar todos os nodes e conexões, clicar no toggle para **ativar** o workflow.

---

## FASE 3: MAIN WORKFLOW — Parte A (Interceptar Button Reply)

Abrir o workflow **Main - Total Assistente** (hLwhn94JSHonwHzl).

### Passo 3.1 — Desconectar Edit Fields → If

1. Localizar o node `Edit Fields` (posição [-2448, 528])
2. Localizar o node `If` que checa "Resuma para mim" (posição [-2096, 544])
3. **Clicar na linha de conexão** entre eles e **deletar** (tecla Delete ou clique direito → Delete)

### Passo 3.2 — Criar node "É Nudge Report?" (Switch)

```
Tipo: Switch
Nome: É Nudge Report?
Posição sugerida: [-2280, 528] (entre Edit Fields e If)

Mode: Rules

Regra 0 (Output 0 — "report_sim"):
  Valor esquerdo: {{ $('trigger-whatsapp').item.json.messages[0].interactive?.button_reply?.id || '' }}
  Operação: starts with
  Valor direito: report_sim_

Regra 1 (Output 1 — "report_nao"):
  Valor esquerdo: {{ $('trigger-whatsapp').item.json.messages[0].interactive?.button_reply?.id || '' }}
  Operação: equals
  Valor direito: report_nao

Fallback Output: ON (output 2 = default)
```

### Passo 3.3 — Conectar

```
Edit Fields → É Nudge Report?
É Nudge Report? [output 2 / default] → If ("Resuma para mim")
```

**Resultado:** Todas as mensagens que NÃO são button reply de relatório seguem o fluxo normal exatamente como antes.

### Passo 3.4 — Criar caminho report_sim (Output 0)

#### Node: Buscar Profile Report (Supabase)

```
Tipo: Supabase
Nome: Buscar Profile Report
Credential: "Total Supabase" (ID: IKPzp0SrhjoEMH0z)

Operation: Get
Table: profiles
Filter:
  phone = {{ $('trigger-whatsapp').item.json.messages[0].from }}
```

#### Node: Calcular Período (Code)

```
Tipo: Code
Nome: Calcular Período
Language: JavaScript
```

Código:

```javascript
const buttonId = $('trigger-whatsapp').item.json
  .messages[0].interactive.button_reply.id;
// Ex: "report_sim_2026-03"

const monthStr = buttonId.replace('report_sim_', '');
const [ano, mes] = monthStr.split('-').map(Number);

const mesesPt = [
  'janeiro', 'fevereiro', 'março', 'abril', 'maio', 'junho',
  'julho', 'agosto', 'setembro', 'outubro', 'novembro', 'dezembro'
];

const pad2 = n => String(n).padStart(2, '0');
const lastDay = new Date(ano, mes, 0).getDate();

return [{
  json: {
    user_id: $('Buscar Profile Report').item.json.id,
    phone: $('trigger-whatsapp').item.json.messages[0].from,
    tipo: 'mensal',
    label: mesesPt[mes - 1].charAt(0).toUpperCase() + mesesPt[mes - 1].slice(1) + ' de ' + ano,
    startDate: ano + '-' + pad2(mes) + '-01T00:00:00-03:00',
    endDate: ano + '-' + pad2(mes) + '-' + pad2(lastDay) + 'T23:59:59-03:00',
    mesNome: mesesPt[mes - 1]
  }
}];
```

#### Node: Gerar Relatório (HTTP Request)

```
Tipo: HTTP Request
Nome: Gerar Relatório Nudge

Method: POST
URL: http://76.13.172.17:5678/webhook/report
Authentication: Generic Credential Type → HTTP Basic Auth
  Credential: "Basic Auth Google" (ID: f031WiARtCEWQuVs)

Send Body: ON
Body Content Type: JSON
Specify Body: JSON
```

JSON Body:

```
={{ {
  user_id: $json.user_id,
  tipo: $json.tipo,
  label: $json.label,
  startDate: $json.startDate,
  endDate: $json.endDate
} }}
```

#### Node: Msg Gerando (WhatsApp)

```
Tipo: WhatsApp
Nome: Msg Relatório Gerando
Credential: "WhatsApp account 2" (ID: OiRJwFsREONcxZdW)

Operation: Send
Phone Number ID: 744582292082931
Recipient Phone Number: +{{ $('trigger-whatsapp').item.json.messages[0].from }}
Text Body: Gerando seu relatório de {{ $('Calcular Período').item.json.label }}... 📊
           Você receberá o PDF em instantes.
```

#### Node: Log Aceito (HTTP Request)

```
Tipo: HTTP Request
Nome: Log Nudge Aceito

Method: POST
URL: https://hkzgttizcfklxfafkzfl.supabase.co/rest/v1/log_total

Send Headers: ON
Headers:
  apikey = eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Imhremd0dGl6Y2ZrbHhmYWZremZsIiwicm9sZSI6InNlcnZpY2Vfcm9sZSIsImlhdCI6MTc3MDIwODYwMSwiZXhwIjoyMDg1Nzg0NjAxfQ._DkH_9A7E1xe6WXOsWNKSWgsRcYJfxjhyTvpXFm23ok
  Authorization = Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Imhremd0dGl6Y2ZrbHhmYWZremZsIiwicm9sZSI6InNlcnZpY2Vfcm9sZSIsImlhdCI6MTc3MDIwODYwMSwiZXhwIjoyMDg1Nzg0NjAxfQ._DkH_9A7E1xe6WXOsWNKSWgsRcYJfxjhyTvpXFm23ok
  Content-Type = application/json
  Prefer = return=minimal

Send Body: ON
Specify Body: JSON
```

JSON Body:

```
={{ {
  user_id: $('Calcular Período').item.json.user_id,
  acao: 'nudge_mensal_aceito',
  mensagem: 'User aceitou nudge, relatório de ' + $('Calcular Período').item.json.label + ' solicitado',
  categoria: 'nudge'
} }}
```

#### Conexões do caminho report_sim:

```
É Nudge Report? [output 0] → Buscar Profile Report
Buscar Profile Report → Calcular Período
Calcular Período → Gerar Relatório Nudge
Gerar Relatório Nudge → Msg Relatório Gerando
Msg Relatório Gerando → Log Nudge Aceito
```

### Passo 3.5 — Criar caminho report_nao (Output 1)

#### Node: Msg Nudge Dispensado (WhatsApp)

```
Tipo: WhatsApp
Nome: Msg Nudge Dispensado
Credential: "WhatsApp account 2" (ID: OiRJwFsREONcxZdW)

Operation: Send
Phone Number ID: 744582292082931
Recipient Phone Number: +{{ $('trigger-whatsapp').item.json.messages[0].from }}
Text Body: Sem problemas! Quando quiser, é só pedir "gera meu relatório". 📊
```

#### Node: Log Recusado (HTTP Request)

```
Tipo: HTTP Request
Nome: Log Nudge Recusado

Method: POST
URL: https://hkzgttizcfklxfafkzfl.supabase.co/rest/v1/log_total

Send Headers: ON
Headers:
  apikey = eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Imhremd0dGl6Y2ZrbHhmYWZremZsIiwicm9sZSI6InNlcnZpY2Vfcm9sZSIsImlhdCI6MTc3MDIwODYwMSwiZXhwIjoyMDg1Nzg0NjAxfQ._DkH_9A7E1xe6WXOsWNKSWgsRcYJfxjhyTvpXFm23ok
  Authorization = Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Imhremd0dGl6Y2ZrbHhmYWZremZsIiwicm9sZSI6InNlcnZpY2Vfcm9sZSIsImlhdCI6MTc3MDIwODYwMSwiZXhwIjoyMDg1Nzg0NjAxfQ._DkH_9A7E1xe6WXOsWNKSWgsRcYJfxjhyTvpXFm23ok
  Content-Type = application/json
  Prefer = return=minimal

Send Body: ON
Specify Body: JSON
```

JSON Body:

```
={{ {
  user_id: 'unknown',
  acao: 'nudge_mensal_recusado',
  mensagem: 'User recusou nudge de relatório mensal',
  categoria: 'nudge'
} }}
```

#### Conexões do caminho report_nao:

```
É Nudge Report? [output 1] → Msg Nudge Dispensado
Msg Nudge Dispensado → Log Nudge Recusado
```

---

## FASE 3: MAIN WORKFLOW — Parte B (Disparar Nudge em Paralelo)

### Passo 3.6 — Criar node "Consume Nudge" (HTTP Request)

```
Tipo: HTTP Request
Nome: Consume Nudge

Method: POST
URL: https://ldbdtakddxznfridsarn.supabase.co/rest/v1/rpc/consume_monthly_nudge

Send Headers: ON
Headers:
  apikey = eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImxkYmR0YWtrZHh6bmZyaWRzYXJuIiwicm9sZSI6InNlcnZpY2Vfcm9sZSIsImlhdCI6MTc1MzgxMTU3OCwiZXhwIjoyMDY5Mzg3NTc4fQ.sgZAmagW59WkngAIbI5QX5X05sfdmRF-PPsdxO1mwTE
  Authorization = Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImxkYmR0YWtrZHh6bmZyaWRzYXJuIiwicm9sZSI6InNlcnZpY2Vfcm9sZSIsImlhdCI6MTc1MzgxMTU3OCwiZXhwIjoyMDY5Mzg3NTc4fQ.sgZAmagW59WkngAIbI5QX5X05sfdmRF-PPsdxO1mwTE
  Content-Type = application/json

Send Body: ON
Specify Body: JSON

Posição sugerida: [-80, 480] (abaixo de setar_user)
```

JSON Body:

```
={{ { p_user_id: $('setar_user').item.json.id_user } }}
```

### Passo 3.7 — Criar node "Nudge Consumido?" (IF)

```
Tipo: IF
Nome: Nudge Consumido?

Condição:
  Valor esquerdo: {{ $json.consumed }}
  Operação: is true (boolean → true)

Posição sugerida: [128, 480]
```

### Passo 3.8 — Criar node "Disparar Nudge" (HTTP Request)

```
Tipo: HTTP Request
Nome: Disparar Nudge

Method: POST
URL: http://76.13.172.17:5678/webhook/nudge-relatorio
  ⚠️ SUBSTITUIR pelo path real do webhook criado na Fase 2, Node 4
Authentication: Generic Credential Type → HTTP Basic Auth
  Credential: "Basic Auth Google" (ID: f031WiARtCEWQuVs)

Send Body: ON
Body Content Type: JSON
Specify Body: JSON

Posição sugerida: [368, 440]
```

JSON Body:

```
={{ {
  phone: $('setar_user').item.json.telefone,
  nome: $('setar_user').item.json.nome,
  user_id: $('setar_user').item.json.id_user,
  report_month: $json.report_month
} }}
```

### Passo 3.9 — Conectar branch nudge

```
setar_user → Consume Nudge                    ← SEGUNDA saída (manter Premium User)
Consume Nudge → Nudge Consumido?
Nudge Consumido? [true] → Disparar Nudge
Nudge Consumido? [false] → (nada, deixar desconectado)
```

⚠️ **COMO ADICIONAR SEGUNDA CONEXÃO:**
1. Passar o mouse sobre a **bolinha de saída** do node `setar_user`
2. A conexão para `Premium User` já existe — NÃO remover
3. Clicar e arrastar uma **nova linha** da mesma bolinha para `Consume Nudge`
4. Agora `setar_user` tem 2 conexões de saída, ambas executam em paralelo

---

## FASE 4: WORKFLOW RELATÓRIOS — Limpar Flag

Abrir o workflow **Relatórios Mensais-Semanais** (0erjX5QpI9IJEmdi).

### Passo 4.1 — Desconectar buscar-perfil → Update a row8

1. Localizar `buscar-perfil` (posição [304, 1264])
2. Localizar `Update a row8` (posição [432, 1264])
3. Deletar a conexão entre eles

### Passo 4.2 — Criar node "Limpar Nudge Flag" (HTTP Request)

```
Tipo: HTTP Request
Nome: Limpar Nudge Flag

Method: POST
URL: https://ldbdtakddxznfridsarn.supabase.co/rest/v1/rpc/clear_nudge_on_report

Send Headers: ON
Headers:
  apikey = eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImxkYmR0YWtrZHh6bmZyaWRzYXJuIiwicm9sZSI6InNlcnZpY2Vfcm9sZSIsImlhdCI6MTc1MzgxMTU3OCwiZXhwIjoyMDY5Mzg3NTc4fQ.sgZAmagW59WkngAIbI5QX5X05sfdmRF-PPsdxO1mwTE
  Authorization = Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImxkYmR0YWtrZHh6bmZyaWRzYXJuIiwicm9sZSI6InNlcnZpY2Vfcm9sZSIsImlhdCI6MTc1MzgxMTU3OCwiZXhwIjoyMDY5Mzg3NTc4fQ.sgZAmagW59WkngAIbI5QX5X05sfdmRF-PPsdxO1mwTE
  Content-Type = application/json

Send Body: ON
Specify Body: JSON

Posição sugerida: [368, 1264] (entre buscar-perfil e Update a row8)
```

JSON Body:

```
={{ { p_user_id: $('webhook-report').item.json.body.user_id } }}
```

### Passo 4.3 — Reconectar

```
buscar-perfil → Limpar Nudge Flag → Update a row8
```

---

## FASE 5: DESATIVAR SISTEMA ANTIGO (Opcional)

Abrir o workflow **Fix Conflito v2** (ImW2P52iyCS0bGbQ).

### Passo 5.1 — Alterar Set nodes

Localizar e editar estes 4 nodes (NÃO deletar, apenas mudar o valor):

**Node `WT-MT`** (posição [-6272, 688]):
```
Campo "relatorio" → novo valor:
"Nenhum relatório pendente."
```

**Node `WF-MT`** (posição [-6272, 1104]):
```
Campo "relatorio" → novo valor:
"Nenhum relatório pendente."
```

Os nodes `WF-MF` e `WT-MF` já dizem "Nenhum relatório" — não precisam de mudança.

---

## FASE 6: TESTE END-TO-END

### 6.1 — Validar SQL

```sql
-- Rodar no Supabase SQL Editor

-- Marcar manualmente
SELECT mark_monthly_report_eligible();

-- Verificar user de teste
SELECT id, name, phone, pending_monthly_report, nudge_report_month
FROM profiles
WHERE phone = '554391936205';
-- Deve mostrar pending=true se Luiz Felipe teve gastos no mês passado
```

### 6.2 — Testar nudge via webhook DEV

Enviar mensagem de texto simples no webhook:

```bash
curl -X POST http://76.13.172.17:5678/webhook/dev-whatsapp \
  -H "Content-Type: application/json" \
  -d '{
    "object": "whatsapp_business_account",
    "entry": [{
      "changes": [{
        "value": {
          "messaging_product": "whatsapp",
          "contacts": [{ "wa_id": "554391936205", "profile": { "name": "Luiz Felipe" } }],
          "messages": [{
            "from": "554391936205",
            "id": "test_nudge_001",
            "timestamp": "'$(date +%s)'",
            "type": "text",
            "text": { "body": "oi" }
          }]
        }
      }]
    }]
  }'
```

**Esperado:**
1. Fix Conflito v2 responde "oi" normalmente (~5s)
2. Nudge chega ~10s depois com botões [Sim, quero!] [Agora não]

### 6.3 — Testar clique "Sim"

```bash
curl -X POST http://76.13.172.17:5678/webhook/dev-whatsapp \
  -H "Content-Type: application/json" \
  -d '{
    "object": "whatsapp_business_account",
    "entry": [{
      "changes": [{
        "value": {
          "messaging_product": "whatsapp",
          "contacts": [{ "wa_id": "554391936205", "profile": { "name": "Luiz Felipe" } }],
          "messages": [{
            "from": "554391936205",
            "id": "test_nudge_002",
            "timestamp": "'$(date +%s)'",
            "type": "interactive",
            "interactive": {
              "type": "button_reply",
              "button_reply": {
                "id": "report_sim_2026-03",
                "title": "Sim, quero!"
              }
            }
          }]
        }
      }]
    }]
  }'
```

**Esperado:**
1. "Gerando seu relatório de Março de 2026... 📊"
2. PDF chega via WhatsApp ~30s depois

### 6.4 — Verificar que nudge não repete

```bash
# Enviar outra mensagem
curl -X POST http://76.13.172.17:5678/webhook/dev-whatsapp \
  -H "Content-Type: application/json" \
  -d '{
    "object": "whatsapp_business_account",
    "entry": [{
      "changes": [{
        "value": {
          "messaging_product": "whatsapp",
          "contacts": [{ "wa_id": "554391936205", "profile": { "name": "Luiz Felipe" } }],
          "messages": [{
            "from": "554391936205",
            "id": "test_nudge_003",
            "timestamp": "'$(date +%s)'",
            "type": "text",
            "text": { "body": "gastei 25 no almoço" }
          }]
        }
      }]
    }]
  }'
```

**Esperado:**
1. "✅ Gasto registrado" (normal)
2. SEM nudge (flag já consumida)

### 6.5 — Verificar logs

```sql
-- No Supabase AI Messages (hkzgttizcfklxfafkzfl)
SELECT * FROM log_total
WHERE acao LIKE 'nudge_%'
ORDER BY created_at DESC
LIMIT 10;
```

---

## CHECKLIST FINAL

```
FASE 1 — SQL
  [ ] ALTER TABLE profiles executado
  [ ] Function mark_monthly_report_eligible criada
  [ ] Function consume_monthly_nudge criada
  [ ] Function clear_nudge_on_report criada
  [ ] Teste: SELECT mark_monthly_report_eligible() retorna número > 0

FASE 2 — Novo Workflow
  [ ] Workflow "Nudge Relatório Mensal" criado
  [ ] Schedule Trigger configurado (dia 1)
  [ ] Webhook node criado e path anotado
  [ ] Wait + Code + HTTP WhatsApp + Log conectados
  [ ] Workflow ATIVADO

FASE 3A — Main (Button Reply)
  [ ] Switch "É Nudge Report?" criado
  [ ] Edit Fields desconectado do If antigo
  [ ] Edit Fields → Switch → If reconectado
  [ ] Caminho report_sim completo (5 nodes)
  [ ] Caminho report_nao completo (2 nodes)

FASE 3B — Main (Disparar Nudge)
  [ ] Consume Nudge criado
  [ ] Nudge Consumido? (IF) criado
  [ ] Disparar Nudge criado com URL do webhook correto
  [ ] setar_user com DUAS saídas (Premium User + Consume Nudge)

FASE 4 — Report Workflow
  [ ] Limpar Nudge Flag criado
  [ ] buscar-perfil → Limpar Nudge Flag → Update a row8 reconectado

FASE 5 — Desativar Antigo (opcional)
  [ ] WT-MT alterado para "Nenhum relatório pendente"
  [ ] WF-MT alterado para "Nenhum relatório pendente"

FASE 6 — Testes
  [ ] Enviar msg com user marcado → nudge aparece
  [ ] Clicar Sim → PDF chega
  [ ] Enviar msg de novo → sem nudge
  [ ] Clicar Não → mensagem de dispensa
  [ ] Logs em log_total corretos
```

---

## RESUMO DE CREDENTIALS USADAS

| Credential | ID | Tipo | Usado em |
|------------|-----|------|----------|
| Total Supabase | IKPzp0SrhjoEMH0z | supabaseApi | Buscar Profile Report |
| WhatsApp account 2 | OiRJwFsREONcxZdW | whatsAppApi | Msg Gerando, Msg Dispensado |
| z-api marcio | nuraEsunXXhjSpGT | httpHeaderAuth | Enviar Nudge WhatsApp (graph.facebook) |
| Basic Auth Google | f031WiARtCEWQuVs | httpBasicAuth | Gerar Relatório, webhook-nudge, Disparar Nudge |

---

*Implementação gerada por Lupa (auditor-360) — Constatando com precisão 🔎*
