# AUDITORIA DE FALHAS — Sistema de Nudge Relatório Mensal

**Data:** 2026-03-30
**Auditor:** Lupa (auditor-360)
**Escopo:** Apenas o sistema proposto de relatórios mensais com nudge interativo
**Referência:** `PLANO-RELATORIO-MENSAL-NUDGE-2026-03-30.md`

---

## Metodologia

Simulação mental de todos os cenários possíveis, cobrindo:
- Happy path e variantes
- Edge cases de timing
- Concorrência e race conditions
- Falhas de infra (DB, API, N8N)
- Conflitos com sistemas existentes
- UX e comportamento do usuário
- Segurança e dados

---

## FALHAS ENCONTRADAS

### F1 — MENSAGEM ORIGINAL PERDIDA (GASTO NÃO REGISTRADO)

| Campo | Valor |
|-------|-------|
| **Severidade** | CRITICA |
| **Tipo** | Design / UX |
| **Probabilidade** | 100% (by design) |

**Cenário:**
1. User digita: "gastei 30 no almoço"
2. Fix Conflito v2 intercepta ANTES do classificador
3. Em vez de registrar o gasto, envia nudge: "Quer o relatório de março?"
4. User clica "Sim" ou "Não"
5. O gasto de R$30 no almoço **nunca foi registrado**
6. User precisa lembrar e redigitar — pode esquecer o valor exato

**Por que é crítico:** O público-alvo são EXATAMENTE users que registram gastos frequentemente (requisito: "pelo menos 1 gasto no mês anterior"). A feature de nudge prejudica a feature principal do produto.

**Impacto ampliado:** Se o user manda uma mensagem complexa tipo "almocei 45 reais no restaurante japonês, paguei com cartão de crédito", e recebe um nudge em vez do registro, a frustração é enorme. O user precisa redigitar tudo e pode simplificar ("gastei 45") perdendo detalhes.

**Fix proposto — Abordagem pós-processamento:**

Em vez de interceptar ANTES do classificador, enviar o nudge DEPOIS de processar a mensagem normalmente:

```
User: "gastei 30 no almoço"
  → Classificador → registrar_gasto → AI Agent → "✅ Gasto registrado"
  → [PÓS-PROCESSAMENTO] Checar pending_monthly_report
  → Se true: Enviar nudge como SEGUNDA mensagem
  → User recebe: "✅ Gasto registrado" + "📊 Quer o relatório de março?"
```

**Onde inserir no Fix Conflito v2:**
Após o `Send message` (resposta ao user) e antes do `Get a row` (log), adicionar:
```
Send message (resposta normal ao user)
  → [NOVO] Checar Nudge Pós (GET profiles.pending_monthly_report)
    → [NOVO] IF pending = true
      → [NOVO] Enviar Nudge Relatório (interactive button)
      → [NOVO] Desativar Nudge (UPDATE profiles SET false)
    → Get a row (log normal continua)
```

**Pontos de atenção da nova abordagem:**
- Existem DOIS pontos de `Send message` no Fix Conflito v2: `Send message` (padrao) e `Send message6` (direto). O nudge pós-processamento precisa estar em AMBOS os caminhos.
- O fluxo de calendar events (criar_evento, editar_evento, etc.) tem caminhos diferentes que NÃO passam por esses Send message nodes. Precisaria mapear todos os pontos de saída.

---

### F2 — STANDARD USERS COM FLAG TRUE ETERNA

| Campo | Valor |
|-------|-------|
| **Severidade** | MEDIA |
| **Tipo** | SQL / Lógica |
| **Probabilidade** | 100% |

**Cenário:**
1. pg_cron roda: `WHERE plan_status = true` (inclui premium E standard)
2. User Standard tem gastos no mês anterior → marcado `pending_monthly_report = true`
3. User Standard manda mensagem → Main workflow → If9 (plan active) → rota Standard
4. Standard NÃO passa pelo Fix Conflito v2
5. Flag fica `true` para sempre (até o próximo dia 1, quando reseta e possivelmente seta de novo)

**Impacto:** Dados sujos no banco. Todo mês, users Standard são marcados e resetados sem efeito. Queries sobre `pending_monthly_report` retornam resultados inflados.

**Fix:**
```sql
-- Opção A: Filtrar no SQL
AND plan_type = 'premium'

-- Opção B: Tratar no Main workflow (se quiser nudge para Standard também no futuro)
-- Adicionar a lógica de nudge no Main, antes do roteamento Premium/Standard
```

---

### F3 — pg_cron TIMEZONE UTC vs BRT

| Campo | Valor |
|-------|-------|
| **Severidade** | MEDIA |
| **Tipo** | Configuração |
| **Probabilidade** | 100% |

**Cenário:**
- Supabase pg_cron usa UTC por padrão
- Cron `5 0 1 * *` = 00:05 UTC = **21:05 BRT do dia anterior**
- No dia 31/mar às 21:05 BRT, a function roda
- `now()` retorna `2026-04-01 00:05:00 UTC`
- `date_trunc('month', now() - interval '1 month')` = `2026-03-01` ✓
- `date_trunc('month', now())` = `2026-04-01` ✓
- Os cálculos estão corretos por coincidência, mas conceitualmente roda no dia errado

**Risco real:** Se Supabase mudar o comportamento ou se alguém debugar logs, vai ver execuções no dia 31 em vez do dia 1.

**Fix:**
```sql
-- Ajustar para 03:05 UTC = 00:05 BRT
SELECT cron.schedule('mark-monthly-report-eligible', '5 3 1 * *', ...);

-- Ou melhor, usar timezone explícito na function:
CREATE OR REPLACE FUNCTION mark_monthly_report_eligible()
RETURNS void LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
  -- Usar timezone explícito
  PERFORM set_config('timezone', 'America/Sao_Paulo', true);
  -- ... resto da lógica
END;
$$;
```

---

### F4 — USER DIGITA RESPOSTA EM TEXTO EM VEZ DE CLICAR BOTÃO

| Campo | Valor |
|-------|-------|
| **Severidade** | BAIXA |
| **Tipo** | UX / Edge case |
| **Probabilidade** | ~10-15% dos users |

**Cenário:**
1. User recebe nudge com botões [Sim, quero!] [Agora não]
2. Em vez de clicar, digita "sim" no teclado
3. Mensagem chega como `type: text`, não `type: interactive`
4. "É Resposta Relatório?" no Main → FALSE (não é button_reply)
5. Vai pro fluxo normal → classificador
6. Classificador R1: "sim" → retorne branch do último pedido do histórico
7. Se havia conversa anterior, repete a última ação (pode ser qualquer coisa)
8. Se não havia, vai pra `padrao` → resposta genérica

**Resultado:** User não recebe o relatório, e pode executar uma ação inesperada.

**Fix:** No fluxo pós-processamento (se adotarmos F1 fix), isso é menos grave porque a flag já foi resetada. No fluxo de interceptação original, é mais problemático.

**Fix adicional (opcional):** No classificador "Escolher Branch", adicionar regra para detectar respostas textuais a nudges. Mas isso adiciona complexidade ao classificador que já é grande.

---

### F5 — RACE CONDITION COM MENSAGENS RÁPIDAS

| Campo | Valor |
|-------|-------|
| **Severidade** | BAIXA |
| **Tipo** | Concorrência |
| **Probabilidade** | ~5% |

**Cenário (abordagem interceptação):**
1. User manda "oi" (msg1) e "gastei 20" (msg2) com 1s de diferença
2. msg1: Fix Conflito v2 checa pending=true, envia nudge, começa UPDATE false
3. msg2: Fix Conflito v2 checa pending=true (UPDATE de msg1 ainda não commitou)
4. User recebe 2 nudges idênticos

**Cenário (abordagem pós-processamento):**
1. User manda "oi" (msg1) e "gastei 20" (msg2)
2. msg1: Fix Conflito processa "oi" → resposta → pós-processamento → nudge + UPDATE false
3. msg2: Fix Conflito processa "gastei 20" → registra gasto → pós-processamento → checa pending
4. Se msg2 checa ANTES do UPDATE de msg1 commitar → nudge duplicado

**Impacto:** User recebe 2 nudges. Irritante mas não destrutivo.

**Fix:**
```sql
-- Usar UPDATE atômico com RETURNING
UPDATE profiles
SET pending_monthly_report = false
WHERE id = $1 AND pending_monthly_report = true
RETURNING pending_monthly_report;
-- Se retornou 0 rows, outro processo já tratou → não enviar nudge
```

---

### F6 — FALHA ENTRE ENVIAR NUDGE E DESATIVAR FLAG

| Campo | Valor |
|-------|-------|
| **Severidade** | MEDIA |
| **Tipo** | Resiliência |
| **Probabilidade** | ~1% |

**Cenário:**
1. Node "Enviar Nudge Relatório" (POST WhatsApp) → sucesso, nudge enviado
2. Node "Desativar Nudge" (UPDATE profiles) → FALHA (Supabase timeout, RLS, etc.)
3. `pending_monthly_report` continua `true`
4. Próxima mensagem do user → recebe nudge NOVAMENTE
5. Repete até Supabase voltar ou até dia 1 do próximo mês (reset)

**Impacto:** User recebe nudge em TODA mensagem. Pode ser 5, 10, 20 nudges no dia.

**Fix — Inverter a ordem:**
```
1. Desativar Nudge (UPDATE false) ← PRIMEIRO
2. Enviar Nudge Relatório ← SEGUNDO
```
Se o envio falhar, o user perde o nudge (aceitável — 1 nudge perdido é melhor que 20 nudges). Se o UPDATE falhar, o nudge não é enviado.

**Fix alternativo — RPC atômico:**
```sql
CREATE OR REPLACE FUNCTION consume_monthly_report_nudge(p_user_id uuid)
RETURNS boolean LANGUAGE plpgsql AS $$
DECLARE
  was_pending boolean;
BEGIN
  UPDATE profiles
  SET pending_monthly_report = false
  WHERE id = p_user_id AND pending_monthly_report = true
  RETURNING true INTO was_pending;

  RETURN COALESCE(was_pending, false);
END;
$$;
-- Retorna true se havia nudge pendente (consumiu), false se não
-- Atômico: impossível 2 processos consumirem o mesmo nudge
```

---

### F7 — WEBHOOK-REPORT REQUER BASIC AUTH NÃO ESPECIFICADO

| Campo | Valor |
|-------|-------|
| **Severidade** | ALTA |
| **Tipo** | Configuração |
| **Probabilidade** | 100% se não tratado |

**Cenário:**
1. User clica "Sim, quero!"
2. Main workflow faz POST para `/webhook/report`
3. webhook-report tem `authentication: "basicAuth"`
4. Se o HTTP Request no Main não enviar credenciais → 401 Unauthorized
5. Relatório NÃO é gerado
6. User recebe "Gerando seu relatório..." mas nunca recebe o PDF

**Evidência:** O node `webhook-report` na definição:
```json
{
  "path": "report",
  "authentication": "basicAuth"
}
```

**Fix:** O HTTP Request no Main que chama webhook-report DEVE incluir:
- Credencial: Basic Auth (provavelmente `avelum:2007` conforme credenciais do sistema)
- Ou: usar a mesma credencial já configurada no N8N para outros webhooks internos

**Nota:** O node `Premium User` no Main já usa `genericCredentialType: httpBasicAuth` para chamar o Fix Conflito v2. Usar o mesmo pattern.

---

### F8 — QUERY REDUNDANTE EM PROFILES

| Campo | Valor |
|-------|-------|
| **Severidade** | BAIXA |
| **Tipo** | Performance |
| **Probabilidade** | 100% |

**Cenário:**
- Main workflow: `Get a row` em profiles (para checar plan_status) → dados descartados depois de setar_user
- Fix Conflito v2: `Checar Nudge Relatório` faz OUTRO GET em profiles (para pending_monthly_report)
- Fix Conflito v2: `Get a row` no final do fluxo faz MAIS UM GET em profiles (para logging)
- São **3 queries em profiles por mensagem Premium**

**Impacto:** Para 100 users ativos com ~10 msgs/dia = 3.000 queries extras/dia em profiles. Supabase aguenta, mas é desperdício.

**Fix otimizado:** Passar `pending_monthly_report` do Main para o Fix Conflito v2 no body do HTTP Request:
```json
{
  "user_name": "...",
  "user_phone": "...",
  "user_id": "...",
  "pending_monthly_report": true,  // ← ADICIONAR
  // ... demais campos
}
```

Isso elimina 1 das 3 queries. A terceira (logging) já é necessária.

---

### F9 — DOIS SISTEMAS PARALELOS DE RELATÓRIO CONFLITANDO

| Campo | Valor |
|-------|-------|
| **Severidade** | MEDIA |
| **Tipo** | Arquitetura |
| **Probabilidade** | 100% |

**Cenário:**
Após implementar o novo sistema, coexistiriam:

| Sistema | Tabela | Lógica | Problema |
|---------|--------|--------|----------|
| **Antigo** | `recurrency_report.monthly` | Switch "possui relatórios?" → contexto pro classificador | Não funciona (user reportou) |
| **Novo** | `profiles.pending_monthly_report` | IF → interactive button → webhook-report | O que estamos implementando |
| **On-demand** | Nenhuma | User diz "gera relatório" → classificador → gerar_relatorio | Já funciona |

**Conflitos possíveis:**
1. O novo sistema envia nudge, user clica "Sim", relatório gerado
2. O antigo sistema ainda tem `monthly=true` em `recurrency_report`
3. O switch "possui relatórios?" ainda seta contexto "relatório disponível"
4. O classificador pode interpretar esse contexto e oferecer o relatório NOVAMENTE
5. User: "Por que estão me oferecendo relatório de novo?"

**Fix:** Ao implementar o novo sistema, DESATIVAR o switch "possui relatórios?" (ou pelo menos a parte `monthly`). Opções:
- Remover os nodes WT-MT, WF-MF, WT-MF, WF-MT e o switch
- Ou setar TODAS as branches para "Nenhum relatório" (desativa sem remover)
- Ou remover o `buscar_relatorios` e linkar `setar_user` direto ao `Aggregate3`

---

### F10 — USER JÁ GEROU RELATÓRIO MANUALMENTE NO MÊS

| Campo | Valor |
|-------|-------|
| **Severidade** | BAIXA |
| **Tipo** | UX |
| **Probabilidade** | ~15% |

**Cenário:**
1. Dia 15/mar: User diz "gera meu relatório mensal" → recebe PDF de março (parcial)
2. Dia 1/abr: pg_cron marca user como elegível (teve gastos em março)
3. Dia 2/abr: User manda mensagem → recebe nudge "Quer o relatório de março?"
4. User pensa: "Já recebi isso..."

**Impacto:** Confusão leve. O relatório do dia 15 era parcial (até dia 15). O do dia 1 seria completo (mês inteiro). Então TECNICAMENTE é útil. Mas o user não sabe a diferença.

**Fix (opcional, não essencial):**
Antes de marcar no pg_cron, checar se o user já gerou relatório mensal recentemente:
```sql
AND id NOT IN (
  SELECT DISTINCT user_id::uuid FROM log_total
  WHERE acao = 'relatorio_enviado'
    AND mensagem LIKE '%mensal%'
    AND created_at >= date_trunc('month', now() - interval '1 month')
)
```
**Contra:** Isso adiciona complexidade e uma query cross-database (log_total está no banco AI Messages, profiles está no Principal). Provavelmente não vale o esforço.

---

### F11 — RELATÓRIO VAZIO SE GASTOS DELETADOS ENTRE MARCAÇÃO E GERAÇÃO

| Campo | Valor |
|-------|-------|
| **Severidade** | MUITO BAIXA |
| **Tipo** | Edge case |
| **Probabilidade** | <1% |

**Cenário:**
1. Dia 1/abr: pg_cron marca user (tinha 5 gastos em março)
2. Dia 3/abr: User diz "apaga todos os gastos de março"
3. Dia 5/abr: User manda outra mensagem → nudge → clica "Sim"
4. webhook-report busca gastos de março → 0 registros
5. PDF gerado está vazio

**Impacto:** PDF vazio, user confuso.

**Fix (complexidade não justifica):** Checar se ainda existem gastos no momento do nudge. Mas isso adiciona outra query. Risco muito baixo — aceitar.

---

### F12 — CONFLITO NUDGE RELATÓRIO + NUDGE GOOGLE CALENDAR

| Campo | Valor |
|-------|-------|
| **Severidade** | BAIXA |
| **Tipo** | UX |
| **Probabilidade** | ~5% (users sem Google conectado) |

**Cenário (abordagem pós-processamento):**
1. User manda "agenda de amanhã"
2. Classificador → `buscar_evento_agenda` (branch [4])
3. Branch [4] → Checar Google Connect → Google Desconectado? → Envia nudge Google
4. User recebe nudge Google
5. PÓS-PROCESSAMENTO: checa pending_monthly_report → true → envia nudge relatório
6. User recebe DOIS nudges seguidos: Google + Relatório

**Impacto:** Spam de nudges. User recebe 2 interactive buttons em sequência.

**Fix:**
- Na abordagem pós-processamento: se o fluxo já enviou um nudge (Google), NÃO enviar o nudge do relatório. Usar uma flag Redis temporária `nudge_sent:{phone}` com TTL 60s.
- Ou: aceitar que são situações raras e separadas em propósito.

---

### F13 — INTERACTIVE BUTTON EXPIRA APÓS 24H

| Campo | Valor |
|-------|-------|
| **Severidade** | MUITO BAIXA |
| **Tipo** | Limitação WhatsApp |
| **Probabilidade** | ~2% |

**Cenário:**
1. User manda mensagem → recebe nudge com botões
2. User vê mas não clica (ocupado)
3. 25 horas depois, user tenta clicar → botão expirado
4. WhatsApp mostra erro "mensagem expirada" ou simplesmente não envia

**Impacto:** User não consegue clicar. Mas a flag já foi resetada (false), então não vai receber de novo. Perdeu a oportunidade.

**Fix:** Nenhum necessário. User pode sempre pedir "gera meu relatório mensal" manualmente. O nudge é conveniência, não único caminho.

---

### F14 — pg_cron NÃO DISPONÍVEL NO SUPABASE

| Campo | Valor |
|-------|-------|
| **Severidade** | ALTA |
| **Tipo** | Infra / Dependência |
| **Probabilidade** | ~30% (depende do plano Supabase) |

**Cenário:**
- pg_cron é uma extensão que precisa estar habilitada
- Free tier do Supabase NÃO inclui pg_cron (apenas planos Pro+)
- Se não tiver pg_cron, a function nunca roda
- Nenhum user é marcado → sistema não funciona

**Evidência:** Existem functions agendadas no banco (`cleanup_bot_tables`, etc.), o que SUGERE que pg_cron está ativo. Mas não é confirmado.

**Fix — Alternativa N8N (deve ser detalhada):**

```
Schedule Trigger no N8N (dia 1, 00:05 BRT)
  → Code (construir query)
  → HTTP Request (POST Supabase RPC)
    URL: https://ldbdtakddxznfridsarn.supabase.co/rest/v1/rpc/mark_monthly_report_eligible
    Headers: apikey + Authorization (service_role)
    Body: {}
```

A function `mark_monthly_report_eligible()` ainda precisa existir no Supabase (via SQL Editor), mas o agendamento é feito pelo N8N em vez do pg_cron.

**ATENÇÃO:** O trigger-mensal1 existente no Report workflow já está bugado (`field: "weeks"` em vez de `"months"`). Se usarmos o N8N como alternativa, criar um NOVO trigger separado e NÃO reutilizar o bugado.

---

### F15 — FALTA DE LOGGING DO NUDGE

| Campo | Valor |
|-------|-------|
| **Severidade** | MEDIA |
| **Tipo** | Observabilidade |
| **Probabilidade** | 100% |

**Cenário:**
O plano não especifica logging para:
- Quando o nudge é enviado
- Quando o user responde (sim/não)
- Se o relatório foi gerado com sucesso após o "sim"
- Quantos users foram marcados pelo pg_cron

**Impacto:** Impossível debugar, monitorar, ou medir eficácia da feature. "Quantos users recebem nudge?" — sem resposta. "Qual % clica Sim?" — sem resposta.

**Fix — Adicionar logs em `log_total`:**

| Momento | acao | mensagem |
|---------|------|----------|
| pg_cron roda | `nudge_mensal_marcados` | "N users marcados para nudge de {mês}" |
| Nudge enviado | `nudge_mensal_enviado` | "Nudge relatório {mês} enviado" |
| User clica Sim | `nudge_mensal_aceito` | "User aceitou nudge relatório {mês}" |
| User clica Não | `nudge_mensal_recusado` | "User recusou nudge relatório {mês}" |
| Relatório gerado | `relatorio_enviado` | (já existe) |

---

### F16 — CONFLITO COM BRANCH "gerar_relatorio" DO CLASSIFICADOR

| Campo | Valor |
|-------|-------|
| **Severidade** | BAIXA |
| **Tipo** | Lógica / UX |
| **Probabilidade** | ~3% |

**Cenário (abordagem pós-processamento):**
1. User manda: "gera meu relatório mensal"
2. Classificador → `gerar_relatorio` → AI Agent → chama tool gerar_relatorio
3. User recebe: "Seu relatório está sendo gerado 🔃"
4. PÓS-PROCESSAMENTO: checa pending_monthly_report → true
5. Envia nudge: "📊 Quer receber o relatório de março?"
6. User: "?? Acabei de pedir!"

**Impacto:** Redundância e confusão.

**Fix:** No pós-processamento, checar se a branch atual era `gerar_relatorio`. Se sim, NÃO enviar nudge + desativar flag silenciosamente:

```javascript
const branchAtual = $('Switch - Branches1').item.json; // verificar branch
if (branchAtual === 'gerar_relatorio') {
  // Desativar flag sem enviar nudge
  // O user já pediu o relatório
}
```

**Fix alternativo mais simples:** No webhook-report, quando o relatório é gerado (para qualquer tipo), já desativar o `pending_monthly_report`:
```sql
UPDATE profiles SET pending_monthly_report = false WHERE id = user_id;
```
Assim, se o user gerou relatório por qualquer caminho, a flag é limpa automaticamente.

---

### F17 — CÁLCULO DO MÊS ANTERIOR QUANDO NUDGE ATRASA

| Campo | Valor |
|-------|-------|
| **Severidade** | BAIXA |
| **Tipo** | Lógica temporal |
| **Probabilidade** | ~5% |

**Cenário:**
1. Dia 1/abril: pg_cron marca user (gastos de março)
2. User não manda mensagem em abril inteiro
3. Dia 1/maio: pg_cron reseta, marca novamente (se teve gastos em abril)
4. Dia 5/maio: User manda mensagem → nudge aparece
5. Code node calcula: `now.getMonth() - 1` = abril (mês 3, 0-indexed)
6. Nudge diz: "Quer o relatório de abril?"
7. Mas o user perdeu o relatório de março (foi sobrescrito pelo ciclo de maio)

**Impacto:** O relatório de março é perdido silenciosamente. Mas no cenário do dia 1/maio, se o user teve gastos em abril, o nudge de abril é correto. Se NÃO teve gastos em abril, não é marcado, e o pending de março já foi resetado. Não tem como recuperar.

**Fix:** Armazenar o mês-alvo junto com a flag:
```sql
ALTER TABLE profiles ADD COLUMN nudge_report_month date;

-- Na function:
UPDATE profiles
SET pending_monthly_report = true,
    nudge_report_month = date_trunc('month', now() - interval '1 month')
WHERE ...;
```

O Code node no N8N usaria `nudge_report_month` em vez de calcular `now() - 1 month`.

---

### F18 — MAIN WORKFLOW NÃO PASSA button_reply.id PARA FIX CONFLITO v2

| Campo | Valor |
|-------|-------|
| **Severidade** | INFO (sem impacto se tratado no Main) |
| **Tipo** | Arquitetura |
| **Probabilidade** | N/A |

**Contexto:**
O `Premium User` node no Main passa `conversation` como:
```javascript
$('Edit Fields').item.json.messageSet
// Que é: button_reply.title || button.text || text.body
```

O `button_reply.id` (ex: `report_sim`) NÃO é passado. Apenas o title ("Sim, quero!").

**Impacto no plano atual:** Nenhum, se a interceptação de button replies for feita no Main ANTES de chamar Premium User (como proposto). O Fix Conflito v2 nunca vê a resposta do botão.

**Impacto se mudar a arquitetura:** Se no futuro alguém decidir tratar button replies dentro do Fix Conflito v2, vai faltar o `button_reply.id`.

**Recomendação:** Para futureproofing, adicionar `button_reply_id` no body do Premium User:
```json
{
  "button_reply_id": "={{ $('trigger-whatsapp').item.json.messages[0].interactive?.button_reply?.id || '' }}"
}
```

---

### F19 — SEM RETRY PARA GERAÇÃO DE RELATÓRIO

| Campo | Valor |
|-------|-------|
| **Severidade** | MEDIA |
| **Tipo** | Resiliência |
| **Probabilidade** | ~5% |

**Cenário:**
1. User clica "Sim, quero!"
2. Main workflow chama POST /webhook/report
3. Report workflow começa: busca perfil, busca gastos, gera HTML, Gotenberg PDF...
4. Gotenberg está fora do ar (container crashou)
5. PDF não é gerado
6. User recebe "Gerando seu relatório..." mas nunca recebe o PDF
7. Flag já foi resetada → user não recebe nudge de novo
8. User não sabe que falhou

**Impacto:** User fica esperando um PDF que nunca chega. Nenhum feedback de erro.

**Fix:**
- O HTTP Request no Main deve checar o response do webhook-report
- Se falhar (status != 200), enviar mensagem: "Desculpe, houve um erro ao gerar seu relatório. Tente pedir novamente com 'gera meu relatório'."
- Ou: NÃO resetar a flag antes da geração confirmar sucesso (mas isso conflita com F6)

---

### F20 — RECURRENCY_REPORT SEM ROW PARA O USER

| Campo | Valor |
|-------|-------|
| **Severidade** | BAIXA |
| **Tipo** | Dados / Edge case |
| **Probabilidade** | ~10% (users novos) |

**Cenário:**
1. User novo se cadastra dia 10/mar, registra gastos
2. Dia 1/abr: pg_cron marca `profiles.pending_monthly_report = true` ✓
3. User manda mensagem → Fix Conflito v2
4. `buscar_relatorios` (GET recurrency_report WHERE fk_user = user_id)
5. User novo NÃO tem row em `recurrency_report` → retorna vazio
6. Switch "possui relatórios?" → output 1 (WF-MF) → "Nenhum relatório"
7. Isso está OK para o sistema antigo, mas e o novo?

**Impacto no novo sistema:** NENHUM, porque o novo sistema usa `profiles.pending_monthly_report` que já existe na row do profiles. O `buscar_relatorios` é do sistema antigo.

**Impacto no sistema antigo (informativo):** Users novos nunca têm relatórios automáticos porque não têm row em `recurrency_report`. Isso é um bug pré-existente, não do novo sistema.

---

## MATRIZ DE PRIORIDADE

### Bloqueia implementação (resolver ANTES):

| # | Falha | Ação |
|---|-------|------|
| **F1** | Mensagem original perdida | Mudar para pós-processamento |
| **F7** | Basic Auth não especificado | Documentar credenciais no plano |
| **F14** | pg_cron pode não existir | Validar ou preparar alternativa N8N |

### Resolver durante implementação:

| # | Falha | Ação |
|---|-------|------|
| **F2** | Standard users marcados | Adicionar `AND plan_type = 'premium'` no SQL |
| **F3** | UTC vs BRT | Ajustar cron para `5 3 1 * *` |
| **F6** | Flag não reseta após envio | Inverter ordem ou usar RPC atômico |
| **F9** | Dois sistemas conflitando | Desativar switch "possui relatórios?" |
| **F15** | Sem logging | Adicionar logs em log_total |

### Resolver após MVP funcionar:

| # | Falha | Ação |
|---|-------|------|
| **F5** | Race condition | Usar UPDATE RETURNING atômico |
| **F8** | Query redundante | Passar campo no body do Premium User |
| **F12** | Duplo nudge (Google + relatório) | Flag Redis anti-duplo |
| **F16** | Conflito com gerar_relatorio | Limpar flag no webhook-report |
| **F17** | Mês atrasado | Armazenar mês-alvo na profiles |
| **F19** | Sem retry/feedback de erro | Checar response do webhook-report |

### Aceitar (risco muito baixo):

| # | Falha | Razão |
|---|-------|-------|
| **F4** | User digita em vez de clicar | Minoria, pode pedir manualmente |
| **F10** | Já gerou relatório manual | Relatório completo > parcial |
| **F11** | Gastos deletados | Probabilidade <1% |
| **F13** | Button expira 24h | User pode pedir manualmente |
| **F18** | button_reply.id não passado | Sem impacto na arquitetura atual |
| **F20** | User novo sem recurrency_report | Bug do sistema antigo, não do novo |

---

## RECOMENDAÇÃO FINAL

**A falha F1 é arquitetural e muda todo o plano.** Antes de implementar, decidir:

**Opção A — Pós-processamento (recomendado):**
Processar a mensagem normalmente, depois enviar nudge como segunda mensagem. Mais complexo (precisa cobrir múltiplos pontos de saída do Fix Conflito v2) mas preserva UX.

**Opção B — Interceptação suave:**
Interceptar no Fix Conflito v2, mas GUARDAR a mensagem original no Redis antes de enviar o nudge. Quando o user responder (sim/não), REPROCESSAR a mensagem original automaticamente. Muito mais complexo.

**Opção C — Manter interceptação (aceitar perda):**
Aceitar que a mensagem se perde. Mais simples, mas UX ruim para o público-alvo.

Minha recomendação: **Opção A**, com as correções F2, F3, F6, F7, F9, F15 aplicadas.

---

*Auditado por Lupa (auditor-360) — Constatando com precisão 🔎*
