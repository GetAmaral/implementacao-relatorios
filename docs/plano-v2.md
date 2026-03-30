# PLANO v2: Sistema de Nudge Relatório Mensal (Livre de Falhas)

**Data:** 2026-03-30
**Auditor:** Lupa (auditor-360)
**Versão:** 2.0 (reescrita total baseada na auditoria de 20 falhas)
**Referência de falhas:** `AUDITORIA-FALHAS-RELATORIO-MENSAL-2026-03-30.md`

---

## 1. PRINCÍPIOS DA v2

| Princípio | Motivo |
|-----------|--------|
| **Nunca bloquear a mensagem do user** | F1: gasto perdido é inaceitável |
| **Não tocar no Fix Conflito v2** | 148 nodes, 6 pontos de saída — risco alto |
| **Operação atômica no banco** | F5/F6: race conditions e flag que não reseta |
| **Mês-alvo armazenado, não calculado** | F17: cálculo de "mês passado" falha se nudge atrasa |
| **Nudge com delay, nunca antes da resposta** | Garantir que user recebe resposta + nudge |
| **Um sistema só, sem conflito** | F9: desativar o antigo "possui relatórios?" |
| **Logging completo** | F15: tudo rastreável |

---

## 2. ARQUITETURA v2

### Diferença fundamental da v1

| Aspecto | v1 (falha) | v2 (corrigido) |
|---------|------------|-----------------|
| Onde o nudge é enviado | Fix Conflito v2 (ANTES do classificador) | Workflow separado (DEPOIS da resposta) |
| Mensagem original | PERDIDA | Processada normalmente |
| Mudanças no Fix Conflito v2 | 5 nodes novos | ZERO mudanças |
| Atomicidade da flag | UPDATE separado | RPC atômico com RETURNING |
| Mês-alvo | Calculado em runtime | Armazenado no banco |
| Button reply | Tratado no Fix Conflito v2 | Tratado no Main workflow |

### Diagrama geral

```
═══════════════════════════════════════════════════════════
  CAMADA 1: BANCO (Supabase)
═══════════════════════════════════════════════════════════

  pg_cron OU N8N Schedule (dia 1, 00:05 BRT)
    → mark_monthly_report_eligible()
      → UPDATE profiles SET
          pending_monthly_report = true,
          nudge_report_month = '2026-03-01'
        WHERE has spending last month AND premium AND plan active

═══════════════════════════════════════════════════════════
  CAMADA 2: MAIN WORKFLOW (intercepta APENAS button replies)
═══════════════════════════════════════════════════════════

  WhatsApp → webhook-receiver → trigger-whatsapp → Check Message Age → If4
    → Edit Fields (extrai texto/button)

    → [NOVO] Switch: É resposta de nudge?
       ├─ button_reply.id = "report_sim_YYYY-MM" → Gerar relatório
       ├─ button_reply.id = "report_nao" → Dispensar
       └─ default → fluxo normal (If → If3 → Get a row → ...)

  ... fluxo normal continua ...

    → Get a row (profiles) ← já tem pending_monthly_report
    → If8 → If9 → setar_user

    → Premium User (fire & forget ao Fix Conflito v2) ← SEM MUDANÇAS
    → [NOVO] IF pending = true (em paralelo)
       → Consume Nudge (RPC atômico)
       → IF consumed → Fire nudge webhook

═══════════════════════════════════════════════════════════
  CAMADA 3: FIX CONFLITO v2 — ZERO MUDANÇAS
═══════════════════════════════════════════════════════════

  Processa a mensagem normalmente.
  Envia resposta ao user via WhatsApp.
  Loga em log_users_messages.
  Nenhum node adicionado, nenhuma conexão alterada.

═══════════════════════════════════════════════════════════
  CAMADA 4: NOVO WORKFLOW "Nudge Relatório Mensal"
═══════════════════════════════════════════════════════════

  Webhook (/nudge-relatorio) recebe dados do user + mês
    → Wait 10 segundos (garante que Fix Conflito respondeu)
    → Code (formata nome do mês em português)
    → HTTP Request (envia interactive button via Meta API)
    → Supabase (log em log_total: nudge_mensal_enviado)
```

---

## 3. CAMADA 1 — BANCO DE DADOS (Supabase)

### 3.1 — Novas colunas na tabela `profiles`

```sql
ALTER TABLE profiles
ADD COLUMN pending_monthly_report boolean DEFAULT false,
ADD COLUMN nudge_report_month date DEFAULT NULL;
```

| Coluna | Tipo | Default | Propósito |
|--------|------|---------|-----------|
| `pending_monthly_report` | boolean | false | Flag: user tem nudge pendente? |
| `nudge_report_month` | date | null | Qual mês o relatório cobre (primeiro dia) |

**Por que `nudge_report_month`?** (fix F17)
Se o user não manda mensagem por 2 semanas, `now() - 1 month` não dá mais o mês certo. Armazenando a data-alvo no momento da marcação, o nudge sempre mostra o mês correto.

### 3.2 — Function para marcar users elegíveis

```sql
CREATE OR REPLACE FUNCTION mark_monthly_report_eligible()
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  affected integer;
  target_month date;
BEGIN
  -- Forçar timezone brasileiro
  PERFORM set_config('timezone', 'America/Sao_Paulo', true);

  -- Mês-alvo = primeiro dia do mês anterior
  target_month := date_trunc('month', now() - interval '1 month')::date;

  -- 1) Resetar flags antigas (quem não mandou mensagem no ciclo anterior)
  UPDATE profiles
  SET pending_monthly_report = false,
      nudge_report_month = NULL
  WHERE pending_monthly_report = true;

  -- 2) Marcar elegíveis: premium + plano ativo + pelo menos 1 gasto no mês anterior
  UPDATE profiles
  SET pending_monthly_report = true,
      nudge_report_month = target_month
  WHERE id IN (
    SELECT DISTINCT fk_user
    FROM spent
    WHERE date_spent >= target_month
      AND date_spent < (target_month + interval '1 month')
  )
  AND plan_type = 'premium'    -- fix F2: apenas premium
  AND plan_status = true;

  GET DIAGNOSTICS affected = ROW_COUNT;
  RETURN affected;
END;
$$;
```

**Correções aplicadas:**
- **F2:** `AND plan_type = 'premium'` — Standard users nunca são marcados
- **F3:** `set_config('timezone', ...)` — operação em BRT, não UTC
- **F17:** `nudge_report_month = target_month` — mês correto armazenado

### 3.3 — RPC atômico para consumir nudge (fix F5, F6)

```sql
CREATE OR REPLACE FUNCTION consume_monthly_nudge(p_user_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  result_month date;
BEGIN
  -- UPDATE atômico: só 1 processo pode consumir
  UPDATE profiles
  SET pending_monthly_report = false
  WHERE id = p_user_id
    AND pending_monthly_report = true
  RETURNING nudge_report_month INTO result_month;

  -- Se nenhuma row foi afetada, outro processo já consumiu
  IF NOT FOUND THEN
    RETURN jsonb_build_object('consumed', false);
  END IF;

  RETURN jsonb_build_object(
    'consumed', true,
    'report_month', result_month
  );
END;
$$;
```

**Por que RPC atômico?**
- **F5 (race condition):** Se 2 mensagens chegam simultâneas, apenas UMA consome o nudge. O UPDATE com WHERE `pending = true` + `RETURNING` é atômico no PostgreSQL.
- **F6 (flag não reseta):** A flag é consumida ANTES de enviar o nudge. Se o envio falhar, o pior caso é perder 1 nudge (aceitável). Nunca causa nudge infinito.

### 3.4 — Limpar flag quando relatório for gerado por qualquer caminho (fix F16)

```sql
CREATE OR REPLACE FUNCTION clear_nudge_on_report(p_user_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
  UPDATE profiles
  SET pending_monthly_report = false,
      nudge_report_month = NULL
  WHERE id = p_user_id
    AND pending_monthly_report = true;
END;
$$;
```

**Onde usar:** No workflow `webhook-report`, adicionar chamada a esta RPC ANTES de buscar gastos. Se o user pediu "gera meu relatório mensal" manualmente, a flag é limpa e ele não recebe nudge redundante.

### 3.5 — Agendamento

**Opção A — pg_cron (se disponível):**
```sql
CREATE EXTENSION IF NOT EXISTS pg_cron;

SELECT cron.schedule(
  'mark-monthly-report-eligible',
  '5 3 1 * *',   -- 03:05 UTC = 00:05 BRT (fix F3)
  $$SELECT mark_monthly_report_eligible()$$
);
```

**Opção B — N8N Schedule Trigger (se pg_cron não disponível) (fix F14):**

Criar um Schedule Trigger NOVO (NÃO reutilizar o `trigger-mensal1` que está bugado):

```
[NOVO] Schedule Trigger: dia 1, 00:05 BRT
  → [NOVO] HTTP Request: POST Supabase RPC
    URL: https://ldbdtakddxznfridsarn.supabase.co/rest/v1/rpc/mark_monthly_report_eligible
    Headers:
      apikey: {SUPABASE_PRINCIPAL_SERVICE_KEY}
      Authorization: Bearer {SUPABASE_PRINCIPAL_SERVICE_KEY}
      Content-Type: application/json
    Body: {}
  → [NOVO] Log resultado (quantos users marcados)
```

**Onde colocar:** No NOVO workflow "Nudge Relatório Mensal" (seção 5), como segundo entry point.

---

## 4. CAMADA 2 — MAIN WORKFLOW (Mudanças Mínimas)

### 4.1 — Interceptar button replies (ANTES do fluxo normal)

**Posição:** Entre `Edit Fields` e `If` ("Resuma para mim")

**Conexão atual:**
```
Edit Fields → If ("Resuma para mim"?)
```

**Conexão nova:**
```
Edit Fields → [NOVO] Switch: Tipo de Button Reply
  [0] report_sim → [NOVO] Gerar Relatório via Nudge
  [1] report_nao → [NOVO] Dispensar Nudge
  [2] default   → If ("Resuma para mim"?) ← fluxo existente
```

#### Node: "Tipo de Button Reply" (Switch)

```
Tipo: Switch
Mode: rules

Regra 0 (report_sim):
  leftValue: {{ $('trigger-whatsapp').item.json.messages[0].interactive?.button_reply?.id || '' }}
  operation: startsWith
  rightValue: "report_sim_"

Regra 1 (report_nao):
  leftValue: {{ $('trigger-whatsapp').item.json.messages[0].interactive?.button_reply?.id || '' }}
  operation: equals
  rightValue: "report_nao"

Fallback (output 2): default → fluxo normal
```

**Por que `startsWith("report_sim_")` em vez de `equals("report_sim")`?**
O ID do botão contém o mês: `report_sim_2026-03`. Isso resolve F17 — o mês viaja embutido no próprio botão.

#### Caminho report_sim (output 0):

```
[NOVO] Switch output 0
  → [NOVO] Code: Extrair Período do Button ID
  → [NOVO] HTTP Request: POST webhook-report (gera relatório)
  → [NOVO] Send WhatsApp: "Gerando seu relatório de {mês}... 📊"
  → [NOVO] Log: Supabase log_total (nudge_mensal_aceito)
```

**Code "Extrair Período do Button ID":**
```javascript
const buttonId = $('trigger-whatsapp').item.json
  .messages[0].interactive.button_reply.id;
// buttonId = "report_sim_2026-03"

const monthStr = buttonId.replace('report_sim_', '');
// monthStr = "2026-03"

const [ano, mes] = monthStr.split('-').map(Number);

const mesesPt = [
  'janeiro','fevereiro','março','abril','maio','junho',
  'julho','agosto','setembro','outubro','novembro','dezembro'
];

const pad2 = n => String(n).padStart(2, '0');
const lastDay = new Date(ano, mes, 0).getDate(); // último dia do mês

return [{
  json: {
    user_id: $('trigger-whatsapp').item.json.contacts[0].wa_id,
    // Para buscar o profile ID, referenciar o Get a row se disponível,
    // ou usar o phone para lookup
    phone: $('trigger-whatsapp').item.json.contacts[0].wa_id,
    tipo: 'mensal',
    label: `${mesesPt[mes - 1]} de ${ano}`,
    startDate: `${ano}-${pad2(mes)}-01T00:00:00-03:00`,
    endDate: `${ano}-${pad2(mes)}-${pad2(lastDay)}T23:59:59-03:00`,
    mesNome: mesesPt[mes - 1],
    ano: ano
  }
}];
```

**HTTP Request "POST webhook-report":**
```
Method: POST
URL: http://76.13.172.17:5678/webhook/report (DEV)
Authentication: Basic Auth (avelum:2007)   ← fix F7
Body (JSON):
{
  "user_id": "={{ $json.user_id }}",
  "tipo": "mensal",
  "label": "={{ $json.label }}",
  "startDate": "={{ $json.startDate }}",
  "endDate": "={{ $json.endDate }}"
}
```

**ATENÇÃO:** O webhook-report espera `user_id` como UUID (ID do profiles), mas aqui temos apenas o phone do `trigger-whatsapp`. Precisamos buscar o UUID.

**Solução:** Adicionar um node `Supabase GET profiles WHERE phone = {phone}` ANTES do HTTP Request:

```
Code (Extrair Período)
  → Supabase GET profiles (WHERE phone = $json.phone)
  → HTTP Request POST webhook-report (user_id = $json.id do profiles)
  → Send WhatsApp "Gerando relatório..."
  → Log
```

**Send WhatsApp:**
```
POST https://graph.facebook.com/v23.0/744582292082931/messages
Authorization: Bearer {WHATSAPP_TOKEN}
Body:
{
  "messaging_product": "whatsapp",
  "to": "{{ phone }}",
  "type": "text",
  "text": {
    "body": "Gerando seu relatório de {{ mesNome }}... 📊\nVocê receberá o PDF em instantes."
  }
}
```

#### Caminho report_nao (output 1):

```
[NOVO] Switch output 1
  → [NOVO] Send WhatsApp: "Sem problemas! Quando quiser, é só pedir 'gera meu relatório'."
  → [NOVO] Log: Supabase log_total (nudge_mensal_recusado)
```

### 4.2 — Disparar nudge em paralelo (APÓS processar normalmente)

**Posição:** No node `setar_user`, adicionar segunda conexão de saída.

**Conexão atual:**
```
setar_user → Premium User
```

**Conexão nova:**
```
setar_user → Premium User (existente, não muda)
setar_user → [NOVO] Consume Nudge (em paralelo)
```

Ambas as branches executam simultaneamente a partir de `setar_user`.

#### Branch nudge:

```
setar_user
  → [NOVO] Consume Nudge (HTTP POST Supabase RPC)
    URL: https://ldbdtakddxznfridsarn.supabase.co/rest/v1/rpc/consume_monthly_nudge
    Headers:
      apikey: {SERVICE_KEY}
      Authorization: Bearer {SERVICE_KEY}
      Content-Type: application/json
    Body: { "p_user_id": "={{ $('setar_user').item.json.id_user }}" }

  → [NOVO] IF consumed = true
    (leftValue: {{ $json.consumed }}, operation: equals, rightValue: true)

    → TRUE: [NOVO] Fire Nudge Webhook (HTTP POST)
      URL: http://76.13.172.17:5678/webhook/{nudge-relatorio-path}
      Auth: Basic Auth
      Body:
      {
        "phone": "={{ $('setar_user').item.json.telefone }}",
        "nome": "={{ $('setar_user').item.json.nome }}",
        "user_id": "={{ $('setar_user').item.json.id_user }}",
        "report_month": "={{ $json.report_month }}"
      }

    → FALSE: No Operation (nada a fazer)
```

**Sequência temporal:**
1. `setar_user` completa
2. Em paralelo:
   - `Premium User` envia dados ao Fix Conflito v2 → processa → responde em ~3-7s
   - `Consume Nudge` chama RPC (~200ms) → se consumed → `Fire Nudge Webhook` (~100ms)
3. O Nudge Webhook recebe a request mas ESPERA 10 segundos antes de enviar
4. Fix Conflito v2 responde ao user em ~3-7s
5. Nudge chega ~10s depois → user vê resposta PRIMEIRO, nudge SEGUNDO

---

## 5. CAMADA 4 — NOVO WORKFLOW "Nudge Relatório Mensal"

### 5.1 — Visão geral

Workflow simples e isolado com 2 entry points:

```
Entry 1: Schedule Trigger (dia 1 do mês) ← alternativa ao pg_cron
  → HTTP POST RPC mark_monthly_report_eligible
  → Log quantidade de users marcados

Entry 2: Webhook (/nudge-relatorio) ← chamado pelo Main workflow
  → Wait 10 segundos
  → Code (formata mês em português)
  → HTTP Request (envia interactive button via Meta API)
  → Log (nudge_mensal_enviado)
```

### 5.2 — Entry 1: Schedule Trigger (backup do pg_cron)

```
Node: Schedule Trigger
  Rule: Monthly, Day 1, 00:05

Node: HTTP Request - Mark Eligible
  Method: POST
  URL: https://ldbdtakddxznfridsarn.supabase.co/rest/v1/rpc/mark_monthly_report_eligible
  Headers:
    apikey: {SERVICE_KEY}
    Authorization: Bearer {SERVICE_KEY}
    Content-Type: application/json
  Body: {}

Node: Log Marcação
  Type: Supabase INSERT
  Table: log_total (banco AI Messages)
  Fields:
    user_id: "system"
    acao: "nudge_mensal_marcados"
    mensagem: "{{ $json }} users marcados para nudge de relatório mensal"
    categoria: "sistema"
```

### 5.3 — Entry 2: Webhook do Nudge

```
Node: Webhook
  Path: nudge-relatorio
  Method: POST
  Authentication: Basic Auth

  Body esperado:
  {
    "phone": "554391936205",
    "nome": "Luiz Felipe",
    "user_id": "2eb4065b-...",
    "report_month": "2026-03-01"
  }
```

### 5.4 — Wait (delay de segurança)

```
Node: Wait
  Resume: After Time Interval
  Amount: 10
  Unit: Seconds
```

**Por que 10 segundos?**
- Fix Conflito v2 leva ~3-7s para processar e responder
- 10s garante margem suficiente
- User vê a resposta da sua mensagem original ANTES do nudge
- Se Fix Conflito v2 demorar mais (edge case), o nudge pode chegar antes, mas sem prejuízo (são mensagens independentes)

### 5.5 — Code: Formatar mês

```javascript
const body = $json.body || $json;
const reportMonth = body.report_month; // "2026-03-01"

const mesesPt = [
  'janeiro','fevereiro','março','abril','maio','junho',
  'julho','agosto','setembro','outubro','novembro','dezembro'
];

const date = new Date(reportMonth + 'T12:00:00Z');
const mesIdx = date.getMonth(); // 0-indexed
const ano = date.getFullYear();
const mesNome = mesesPt[mesIdx];
const mesFormatado = `${mesNome.charAt(0).toUpperCase() + mesNome.slice(1)} de ${ano}`;

// Mês no formato YYYY-MM para embutir no button ID
const mesId = `${ano}-${String(mesIdx + 1).padStart(2, '0')}`;

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

### 5.6 — HTTP Request: Enviar Interactive Button

```
Method: POST
URL: https://graph.facebook.com/v23.0/744582292082931/messages
Authentication: HTTP Header Auth (Bearer {WHATSAPP_TOKEN})
Headers:
  Content-Type: application/json
Body (JSON):
```

```json
{
  "messaging_product": "whatsapp",
  "to": "={{ $json.phone }}",
  "type": "interactive",
  "interactive": {
    "type": "button",
    "body": {
      "text": "={{ '📊 Seu resumo financeiro de ' + $json.mesFormatado + ' está pronto!\\n\\nDeseja receber o relatório completo em PDF?' }}"
    },
    "action": {
      "buttons": [
        {
          "type": "reply",
          "reply": {
            "id": "={{ 'report_sim_' + $json.mesId }}",
            "title": "Sim, quero!"
          }
        },
        {
          "type": "reply",
          "reply": {
            "id": "report_nao",
            "title": "Agora não"
          }
        }
      ]
    }
  }
}
```

**Detalhe do button ID:**
- `report_sim_2026-03` → contém o mês-alvo embutido
- `report_nao` → sem mês (não precisa, apenas dispensa)

Quando o user clica "Sim, quero!", o Main workflow recebe `button_reply.id = "report_sim_2026-03"` e extrai o mês diretamente do ID. Não precisa consultar banco, Redis, ou calcular "mês passado".

### 5.7 — Log: Nudge enviado

```
Type: Supabase INSERT
Table: log_total (banco AI Messages)
Fields:
  user_id: "={{ $json.user_id }}"
  acao: "nudge_mensal_enviado"
  mensagem: "Nudge relatório {{ $json.mesFormatado }} enviado"
  categoria: "nudge"
```

---

## 6. MUDANÇA NO WORKFLOW "RELATÓRIOS MENSAIS-SEMANAIS" (fix F16)

### 6.1 — Limpar flag quando relatório gerado por qualquer caminho

No workflow existente, o `webhook-report` já é o entry point para geração on-demand. Adicionar UMA chamada RPC após `buscar-perfil`:

```
webhook-report
  → buscar-perfil (GET profiles WHERE id = user_id)  ← existente
  → [NOVO] Limpar Nudge Flag (HTTP POST RPC clear_nudge_on_report)
  → Update a row8 (SET monthly = false)  ← existente
  → buscar-gastos  ← existente
  → ... resto do fluxo ...
```

**Node: Limpar Nudge Flag**
```
Method: POST
URL: https://ldbdtakddxznfridsarn.supabase.co/rest/v1/rpc/clear_nudge_on_report
Body: { "p_user_id": "={{ $('webhook-report').item.json.body.user_id }}" }
```

**Resultado:** Se o user disse "gera meu relatório mensal" antes de receber o nudge, a flag é limpa e ele não recebe um nudge redundante.

---

## 7. DESATIVAR SISTEMA ANTIGO (fix F9)

### O que desativar

O switch "possui relatórios?" no Fix Conflito v2 e a lógica associada:

```
ANTES (atual):
  setar_user → buscar_relatorios → possui relatórios? → WT-MT/WF-MF/WT-MF/WF-MT → Aggregate3

DEPOIS (proposto):
  setar_user → buscar_relatorios → Aggregate3
  (bypass do switch — todas as branches setam "Nenhum relatório")
```

**Como desativar sem remover nodes (seguro):**

Alterar os 4 Set nodes (WT-MT, WF-MF, WT-MF, WF-MT) para TODOS setarem o mesmo valor:
```
relatorio = "Sistema de relatórios opera por nudge interativo. Não mencione relatórios proativamente."
```

Isso neutraliza o switch sem deletar nodes — reversível se necessário.

**Alternativa mais limpa:** Desconectar `buscar_relatorios` do switch e conectar direto ao `Aggregate3`. Mas isso requer edição de connections no Fix Conflito v2.

---

## 8. LISTA COMPLETA DE MUDANÇAS

### Banco de dados (Supabase SQL Editor):

| # | Tipo | SQL |
|---|------|-----|
| 1 | ALTER TABLE | Adicionar `pending_monthly_report` + `nudge_report_month` em profiles |
| 2 | FUNCTION | `mark_monthly_report_eligible()` |
| 3 | FUNCTION | `consume_monthly_nudge(uuid)` |
| 4 | FUNCTION | `clear_nudge_on_report(uuid)` |
| 5 | CRON (se disponível) | Schedule dia 1, 03:05 UTC |

### Main Workflow (5 nodes novos + 1 reconexão):

| # | Node | Tipo | Conexão |
|---|------|------|---------|
| 1 | Tipo de Button Reply | Switch | Edit Fields → este → [default] → If existente |
| 2 | Buscar Profile (Report) | Supabase GET | Switch[0] → este |
| 3 | Gerar Relatório Nudge | HTTP Request | Profile → este |
| 4 | Msg Gerando Relatório | WhatsApp Send | HTTP → este |
| 5 | Msg Nudge Dispensado | WhatsApp Send | Switch[1] → este |
| 6 | Consume Nudge | HTTP Request | setar_user → este (paralelo com Premium User) |
| 7 | IF Consumed | IF | Consume → este |
| 8 | Fire Nudge Webhook | HTTP Request | IF[true] → este |
| 9 | Log Aceito | Supabase INSERT | Msg Gerando → este |
| 10 | Log Recusado | Supabase INSERT | Msg Dispensado → este |

### Novo Workflow "Nudge Relatório Mensal" (7 nodes):

| # | Node | Tipo |
|---|------|------|
| 1 | Schedule Trigger | scheduleTrigger (dia 1) |
| 2 | Mark Eligible | HTTP Request (RPC) |
| 3 | Log Marcação | Supabase INSERT |
| 4 | Webhook Nudge | webhook (/nudge-relatorio) |
| 5 | Wait 10s | wait |
| 6 | Formatar Mês | code |
| 7 | Enviar Button | HTTP Request (WhatsApp API) |
| 8 | Log Nudge Enviado | Supabase INSERT |

### Workflow "Relatórios Mensais-Semanais" (1 node novo):

| # | Node | Tipo |
|---|------|------|
| 1 | Limpar Nudge Flag | HTTP Request (RPC) |

### Fix Conflito v2:

**ZERO MUDANÇAS.** (Opcional: neutralizar os 4 Set nodes do switch "possui relatórios?")

---

## 9. VERIFICAÇÃO CONTRA TODAS AS 20 FALHAS

| Falha | Status | Como foi resolvida |
|-------|--------|-------------------|
| **F1** Mensagem perdida | **RESOLVIDO** | Nudge vai DEPOIS da resposta, em paralelo. Mensagem processada normalmente. |
| **F2** Standard users marcados | **RESOLVIDO** | SQL tem `AND plan_type = 'premium'` |
| **F3** UTC vs BRT | **RESOLVIDO** | Cron `5 3 1 * *` (UTC) = 00:05 BRT + `set_config('timezone')` na function |
| **F4** User digita em vez de clicar | **ACEITO** | Risco baixo (~10%). User pode pedir "gera relatório" manualmente. Não justifica complexidade extra. |
| **F5** Race condition | **RESOLVIDO** | RPC `consume_monthly_nudge` é atômico (UPDATE WHERE true RETURNING). Apenas 1 processo consome. |
| **F6** Flag não reseta | **RESOLVIDO** | Flag é consumida ANTES de enviar nudge (invertido). Se envio falha, perde 1 nudge (aceitável). |
| **F7** Basic Auth | **RESOLVIDO** | Documentado: `avelum:2007` para webhook-report. HTTP Request usa httpBasicAuth. |
| **F8** Query redundante | **RESOLVIDO** | Main já faz GET profiles (Get a row). O consume é via RPC (não precisa de GET). Apenas 1 query extra (RPC). |
| **F9** Dois sistemas conflitando | **RESOLVIDO** | Switch "possui relatórios?" neutralizado. Novo sistema opera independente. |
| **F10** User já gerou relatório manual | **RESOLVIDO** | `clear_nudge_on_report` no webhook-report limpa flag quando relatório é gerado por qualquer caminho. |
| **F11** Gastos deletados | **ACEITO** | Probabilidade <1%. Relatório vazio mas funcional. |
| **F12** Duplo nudge (Google + relatório) | **RESOLVIDO** | Google nudge é no Fix Conflito v2 (DEPOIS de processar). Relatório nudge é no Main (ANTES de enviar ao Fix Conflito). Timing diferente. Se ambos ocorrem, relatório chega ~10s depois da resposta normal, Google chega dentro da resposta. São mensagens separadas e claras. |
| **F13** Button expira 24h | **ACEITO** | User pode pedir manualmente. Nudge é conveniência. |
| **F14** pg_cron indisponível | **RESOLVIDO** | Schedule Trigger no novo workflow como backup. Ambos chamam a mesma function. |
| **F15** Sem logging | **RESOLVIDO** | 4 eventos logados: marcados, enviado, aceito, recusado. Todos em log_total. |
| **F16** Conflito com gerar_relatorio | **RESOLVIDO** | `clear_nudge_on_report` limpa flag quando qualquer relatório é gerado. Se user pediu manual antes, não recebe nudge. |
| **F17** Mês atrasado | **RESOLVIDO** | `nudge_report_month` armazenado no banco. Button ID contém `YYYY-MM`. Mês correto em qualquer timing. |
| **F18** button_reply.id não passado | **N/A** | Button reply é tratado no Main, nunca chega ao Fix Conflito v2. |
| **F19** Sem retry/feedback de erro | **PARCIAL** | Se webhook-report falhar, user recebe "Gerando..." mas não o PDF. Fix completo exigiria polling — complexidade não justifica para MVP. Recomendação: adicionar no webhook-report um node de erro que envia "Desculpe, houve um erro" via WhatsApp. |
| **F20** User sem recurrency_report | **N/A** | Novo sistema usa profiles, não recurrency_report. |

---

## 10. CENÁRIOS SIMULADOS (Teste Mental)

### Cenário 1: Happy path completo
```
Dia 1/abr 00:05 BRT:
  pg_cron → mark_monthly_report_eligible()
  → Luiz Felipe tem 15 gastos em março + premium + ativo
  → UPDATE profiles SET pending=true, nudge_month='2026-03-01'
  → 47 users marcados (log)

Dia 3/abr 14:30:
  Luiz: "gastei 30 no almoço"
  → Main: webhook → Edit Fields → Switch (não é button) → If → If3
  → Get a row (profiles): {pending: true, nudge_month: "2026-03-01", ...}
  → If8 (exists) → If9 (plan active) → setar_user

  [PARALELO A] setar_user → Premium User → Fix Conflito v2
    → Classificador → criar_gasto → AI Agent → "✅ Gasto registrado"
    → WhatsApp: "✅ Gasto de R$30 em Alimentação registrado!"  (t=5s)

  [PARALELO B] setar_user → Consume Nudge RPC
    → {consumed: true, report_month: "2026-03-01"}
    → Fire Nudge Webhook (t=0.3s)

  Nudge Webhook:
    → Wait 10s
    → Formatar: "Março de 2026"
    → Enviar button: "📊 Seu resumo de Março de 2026 está pronto!" (t=10.3s)

  Luiz vê no WhatsApp:
    14:30:05 - "✅ Gasto de R$30 em Alimentação registrado!"
    14:30:10 - "📊 Seu resumo de Março de 2026 está pronto! [Sim, quero!] [Agora não]"

  Luiz clica [Sim, quero!]:
  → Main: webhook → Edit Fields → Switch → report_sim_2026-03
    → Code: extrair período março 2026 (01/03 a 31/03)
    → Supabase GET profiles (buscar UUID)
    → HTTP POST /webhook/report {user_id, tipo:mensal, startDate, endDate}
    → WhatsApp: "Gerando seu relatório de março... 📊"
    → Log: nudge_mensal_aceito

  Report Workflow:
    → buscar-perfil → clear_nudge_on_report → buscar-gastos (março)
    → gerar-html → gotenberg → upload → enviar PDF
    → WhatsApp: [documento] relatorio-mensal.pdf

  Luiz vê:
    14:30:15 - "Gerando seu relatório de março... 📊"
    14:30:45 - [PDF] relatorio-mensal.pdf
```

**Resultado: PASS** ✅ Gasto registrado + nudge + relatório. Nada perdido.

---

### Cenário 2: User clica "Agora não"
```
Luiz: "oi"
  → Fix Conflito v2: "Olá! Como posso ajudar?" (t=3s)
  → Nudge: "📊 Relatório de Março disponível!" (t=10s)

Luiz clica [Agora não]:
  → Main: Switch → report_nao
  → WhatsApp: "Sem problemas! Quando quiser, é só pedir 'gera meu relatório'."
  → Log: nudge_mensal_recusado

Luiz: "gastei 20 no uber"
  → Fix Conflito v2 processa normalmente
  → Consume Nudge RPC: {consumed: false} (já consumido)
  → Nenhum nudge enviado
  → "✅ Gasto registrado!"
```

**Resultado: PASS** ✅ Nudge dispensado, fluxo normal depois.

---

### Cenário 3: Duas mensagens rápidas (race condition)
```
Luiz envia "oi" (msg1) e "gastei 50" (msg2) com 0.5s de diferença

msg1 (t=0):
  → setar_user → Premium User + Consume Nudge RPC
  → RPC: UPDATE WHERE pending=true RETURNING → {consumed: true}
  → Fire Nudge Webhook

msg2 (t=0.5):
  → setar_user → Premium User + Consume Nudge RPC
  → RPC: UPDATE WHERE pending=true → NOT FOUND (msg1 já consumiu)
  → {consumed: false} → No Operation

Resultado:
  msg1: Fix Conflito responde "Olá!" + nudge chega 10s depois
  msg2: Fix Conflito registra gasto "✅ R$50" + sem nudge

1 nudge, 2 respostas. Correto.
```

**Resultado: PASS** ✅ RPC atômico previne nudge duplicado.

---

### Cenário 4: User pede relatório manual ANTES de receber nudge
```
Dia 1/abr: Luiz marcado (pending=true)

Dia 2/abr:
Luiz: "gera meu relatório mensal"
  → Fix Conflito v2 → classificador → gerar_relatorio → tool HTTP
  → Report Workflow: webhook-report
    → buscar-perfil
    → clear_nudge_on_report RPC → pending=false ← LIMPO AQUI
    → buscar-gastos → gerar PDF → enviar

Dia 3/abr:
Luiz: "oi"
  → Consume Nudge RPC: {consumed: false} (já limpo no dia 2)
  → Sem nudge
  → Fix Conflito: "Olá!"
```

**Resultado: PASS** ✅ Sem nudge redundante após relatório manual.

---

### Cenário 5: User Standard com gastos
```
Dia 1/abr: pg_cron roda
  → Maria (Standard) tem gastos em março
  → SQL: WHERE plan_type = 'premium' → Maria NÃO é marcada
  → pending_monthly_report continua false

Dia 5/abr:
Maria: "quanto gastei?"
  → Main: Get a row → If8 → If9 (plan active) → Standard User flow
  → Nenhum Consume Nudge (branch nudge só existe após setar_user, que é após If9 premium)
```

**Resultado: PASS** ✅ Standard users não são afetados.

---

### Cenário 6: pg_cron indisponível
```
pg_cron não está instalado no Supabase.

Dia 1/abr 00:05:
  → N8N Schedule Trigger dispara
  → HTTP POST RPC mark_monthly_report_eligible
  → Function roda normalmente (não depende de pg_cron, só de plpgsql)
  → 47 users marcados
  → Log: "47 users marcados"
```

**Resultado: PASS** ✅ N8N como backup funciona.

---

### Cenário 7: User não manda mensagem por 2 meses
```
Dia 1/mar: Luiz marcado (pending=true, month='2026-02-01')
Luiz não manda mensagem em março inteiro.

Dia 1/abr: pg_cron roda
  → Reseta pending=false (Luiz tinha true)
  → Luiz tem gastos em março → marca pending=true, month='2026-03-01'

Dia 15/abr:
Luiz: "oi"
  → Consume Nudge: {consumed: true, report_month: "2026-03-01"}
  → Nudge: "📊 Relatório de Março de 2026 disponível!"
  → Correto! É março, não fevereiro (nudge_report_month armazenado)
```

**Resultado: PASS** ✅ Relatório de fevereiro perdido (aceitável — 2 meses sem uso), março correto.

---

### Cenário 8: Nudge + Google Calendar nudge na mesma sessão
```
Luiz: "agenda de amanhã"

  [PARALELO A] Premium User → Fix Conflito v2
    → Classificador → buscar_evento_agenda → Checar Google Connect
    → Google desconectado → Buscar Nudge → Pode enviar?
    → Enviar Nudge Google: "📅 Quer conectar Google Calendar?"  (t=5s)

  [PARALELO B] Consume Nudge → consumed=true
    → Nudge Webhook → Wait 10s
    → "📊 Relatório de Março disponível!"  (t=10s)

Luiz vê:
  14:30:05 - "📅 Quer conectar Google Calendar? [✅ Sim] [❌ Não]"
  14:30:10 - "📊 Relatório de Março disponível! [Sim, quero!] [Agora não]"
```

**Resultado: ACEITÁVEL** ⚠️ 2 nudges seguidos. Não é ideal, mas são nudges diferentes com propósitos claros. Acontece raramente (user sem Google + com gastos no mês anterior). O espaçamento de 5s entre eles ajuda.

---

### Cenário 9: Falha no envio do nudge WhatsApp
```
Luiz: "oi"
  → Consume Nudge RPC: {consumed: true} → pending=false ← JÁ CONSUMIDO
  → Fire Nudge Webhook
  → Wait 10s
  → HTTP Request WhatsApp → FALHA (Meta API fora)
  → Nudge não enviado

Resultado: Luiz não recebe nudge. pending=false. Não receberá outro nudge até dia 1 do próximo mês.
```

**Resultado: ACEITÁVEL** ⚠️ Perde 1 nudge. Melhor que nudge infinito (F6). User sempre pode pedir manualmente.

---

### Cenário 10: Falha na geração do relatório
```
Luiz clica [Sim, quero!]
  → Code extrai mês
  → HTTP POST webhook-report → Report Workflow
  → Gotenberg container está down → PDF falha
  → Luiz recebe "Gerando seu relatório..." mas PDF nunca chega
```

**Resultado: FALHA RESIDUAL** ⚠️ User fica esperando. Mas isso é um bug do Report Workflow existente, não do sistema de nudge.

**Recomendação futura:** Adicionar no Report Workflow um catch de erro que envia "Desculpe, houve um problema. Tente novamente com 'gera meu relatório'."

---

## 11. ORDEM DE IMPLEMENTAÇÃO

```
FASE 1: Banco (30 min)
  ├─ 1.1 ALTER TABLE profiles (2 colunas)
  ├─ 1.2 CREATE FUNCTION mark_monthly_report_eligible
  ├─ 1.3 CREATE FUNCTION consume_monthly_nudge
  ├─ 1.4 CREATE FUNCTION clear_nudge_on_report
  └─ 1.5 Testar: SELECT mark_monthly_report_eligible()

FASE 2: Novo workflow (45 min)
  ├─ 2.1 Criar workflow "Nudge Relatório Mensal"
  ├─ 2.2 Entry 1: Schedule Trigger + RPC
  ├─ 2.3 Entry 2: Webhook + Wait + Code + HTTP WhatsApp + Log
  └─ 2.4 Testar: POST manual no webhook com dados de teste

FASE 3: Main workflow (60 min)
  ├─ 3.1 Adicionar Switch "Tipo de Button Reply" após Edit Fields
  ├─ 3.2 Reconectar default → If existente
  ├─ 3.3 Caminho report_sim: Code + Supabase GET + HTTP + WhatsApp + Log
  ├─ 3.4 Caminho report_nao: WhatsApp + Log
  ├─ 3.5 Adicionar branch paralela de setar_user: Consume + IF + Fire
  └─ 3.6 Testar: enviar mensagem com user marcado, verificar nudge

FASE 4: Report workflow (10 min)
  ├─ 4.1 Adicionar node "Limpar Nudge Flag" após buscar-perfil
  └─ 4.2 Testar: pedir relatório manual, verificar flag limpa

FASE 5: Desativar antigo (10 min)
  ├─ 5.1 Alterar Set nodes WT-MT/WF-MF/WT-MF/WF-MT
  └─ 5.2 Verificar que classificador não menciona relatórios proativamente

FASE 6: Teste end-to-end (30 min)
  ├─ 6.1 Rodar mark_monthly_report_eligible() manual
  ├─ 6.2 Enviar mensagem via webhook DEV → verificar nudge
  ├─ 6.3 Clicar Sim → verificar PDF recebido
  ├─ 6.4 Repetir → verificar que não recebe nudge de novo
  ├─ 6.5 Testar report_nao
  ├─ 6.6 Testar mensagem de Standard user (sem nudge)
  └─ 6.7 Verificar logs em log_total
```

---

## 12. SQL COMPLETO (copiar e colar no Supabase SQL Editor)

```sql
-- ==========================================================
-- NUDGE RELATÓRIO MENSAL — SQL COMPLETO
-- Executar no Supabase SQL Editor (banco Principal)
-- ==========================================================

-- 1. Novas colunas
ALTER TABLE profiles
ADD COLUMN IF NOT EXISTS pending_monthly_report boolean DEFAULT false,
ADD COLUMN IF NOT EXISTS nudge_report_month date DEFAULT NULL;

-- 2. Function: marcar elegíveis (todo dia 1)
CREATE OR REPLACE FUNCTION mark_monthly_report_eligible()
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  affected integer;
  target_month date;
BEGIN
  PERFORM set_config('timezone', 'America/Sao_Paulo', true);
  target_month := date_trunc('month', now() - interval '1 month')::date;

  UPDATE profiles
  SET pending_monthly_report = false, nudge_report_month = NULL
  WHERE pending_monthly_report = true;

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

-- 3. Function: consumir nudge (atômico)
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

-- 4. Function: limpar flag ao gerar relatório
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

-- 5. Agendamento (APENAS se pg_cron disponível)
-- SELECT cron.schedule(
--   'mark-monthly-report-eligible',
--   '5 3 1 * *',
--   $$SELECT mark_monthly_report_eligible()$$
-- );

-- ==========================================================
-- VERIFICAÇÃO (rodar manualmente para validar)
-- ==========================================================

-- Quantos users seriam marcados?
SELECT COUNT(DISTINCT s.fk_user) as elegíveis
FROM spent s
JOIN profiles p ON p.id = s.fk_user
WHERE s.date_spent >= date_trunc('month', now() - interval '1 month')
  AND s.date_spent < date_trunc('month', now())
  AND p.plan_type = 'premium'
  AND p.plan_status = true;

-- Teste manual
-- SELECT mark_monthly_report_eligible();

-- Verificar marcados
-- SELECT id, name, phone, pending_monthly_report, nudge_report_month
-- FROM profiles WHERE pending_monthly_report = true;
```

---

*Plano v2 gerado por Lupa (auditor-360) — Todas as 20 falhas endereçadas 🔎*
