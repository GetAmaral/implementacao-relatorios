# Alterações no Main Workflow — Passo a Passo com JSON

**Workflow:** Main - Total Assistente

Todos os nodes estão em arquivos JSON prontos para colar no N8N.
Para colar: copiar o conteúdo do JSON → no N8N, clicar no canvas → Ctrl+V.

---

## Parte A — Interceptar Button Reply

### Passo 1: Desconectar Edit Fields → If

- Achar o node `Edit Fields` e o node `If` (checa "Resuma para mim")
- Clicar na linha de conexão entre eles → Delete

### Passo 2: Criar Switch "É Nudge Report?"

Criar manualmente (Switch não cola bem via JSON por causa das rules):

```
Tipo: Switch
Nome: É Nudge Report?

Mode: Rules

Regra 0 (Output 0 = report_sim):
  Left Value:  {{ $('trigger-whatsapp').item.json.messages[0].interactive?.button_reply?.id || '' }}
  Operation:   starts with
  Right Value: report_sim_

Regra 1 (Output 1 = report_nao):
  Left Value:  {{ $('trigger-whatsapp').item.json.messages[0].interactive?.button_reply?.id || '' }}
  Operation:   equals
  Right Value: report_nao

Fallback Output: ON (gera output 2)
```

**Posicionar** entre `Edit Fields` e `If`, na mesma altura.

### Passo 3: Conectar

```
Edit Fields → É Nudge Report?
É Nudge Report? [output 2 / fallback] → If ("Resuma para mim")
```

Testar: o fluxo normal deve continuar funcionando para mensagens de texto.

---

### Passo 4: Colar nodes do caminho report_sim

**Arquivo:** `nodes-report-sim.json`

1. Abrir o arquivo, copiar TODO o conteúdo
2. No N8N, clicar no canvas vazio (área livre abaixo do fluxo)
3. **Ctrl+V**
4. Os 5 nodes aparecem já conectados entre si:

```
Buscar Profile Report → Calcular Período → Gerar Relatório Nudge → Msg Relatório Gerando → Log Nudge Aceito
```

5. **Conectar manualmente:** saída 0 do `É Nudge Report?` → entrada do `Buscar Profile Report`
6. Posicionar os nodes abaixo do fluxo principal (linha de cima fica o fluxo normal, linha de baixo fica o report_sim)

**Verificar credentials** (podem aparecer em vermelho após colar):
- `Buscar Profile Report` → selecionar "Total Supabase"
- `Gerar Relatório Nudge` → selecionar "Basic Auth Google"
- `Msg Relatório Gerando` → selecionar "WhatsApp account 2"

---

### Passo 5: Colar nodes do caminho report_nao

**Arquivo:** `nodes-report-nao.json`

1. Copiar conteúdo do arquivo
2. Ctrl+V no canvas
3. Os 2 nodes aparecem conectados:

```
Msg Nudge Dispensado → Log Nudge Recusado
```

4. **Conectar manualmente:** saída 1 do `É Nudge Report?` → entrada do `Msg Nudge Dispensado`
5. Posicionar abaixo do caminho report_sim

**Verificar credentials:**
- `Msg Nudge Dispensado` → selecionar "WhatsApp account 2"

---

## Parte B — Disparar Nudge em Paralelo

### Passo 6: Colar nodes do nudge paralelo

**Arquivo:** `nodes-nudge-paralelo.json`

1. Copiar conteúdo do arquivo
2. Ctrl+V no canvas
3. Os 3 nodes aparecem conectados:

```
Consume Nudge → Nudge Consumido? → Disparar Nudge
```

4. Posicionar à direita e abaixo do node `setar_user` (que já existe)

**Verificar credentials:**
- `Disparar Nudge` → selecionar "Basic Auth Google"

### Passo 7: Conectar ao setar_user

1. Localizar o node `setar_user` (já tem saída para `Premium User`)
2. **NÃO REMOVER** a conexão existente para `Premium User`
3. Arrastar uma **SEGUNDA linha** da bolinha de saída de `setar_user` para `Consume Nudge`
4. Agora `setar_user` tem 2 saídas paralelas:
   - → Premium User (existente)
   - → Consume Nudge (nova)

---

## Resultado final no Main Workflow

```
                    Edit Fields
                        │
                   É Nudge Report?
                   /      |       \
              output 0  output 1  output 2 (fallback)
                 │         │          │
          Buscar Profile  Msg Nudge   If ("Resuma para mim")
                 │        Dispensado      │
          Calcular         │          fluxo normal...
          Período       Log Nudge        │
                 │       Recusado    setar_user ──────────┐
          Gerar                          │                │
          Relatório                 Premium User    Consume Nudge
                 │                  (existente)          │
          Msg Gerando                              Nudge Consumido?
                 │                                   │ true
          Log Aceito                            Disparar Nudge
```
