# Alterações no Main Workflow

**Workflow:** Main - Total Assistente (`hLwhn94JSHonwHzl`)

---

## Parte A — Interceptar Button Reply do Nudge

### 1. Desconectar `Edit Fields` → `If`

- Localizar `Edit Fields` (posição [-2448, 528])
- Localizar `If` que checa "Resuma para mim" (posição [-2096, 544])
- Clicar na conexão entre eles → Delete

### 2. Criar node `É Nudge Report?` (Switch)

- **Tipo:** Switch
- **Nome:** É Nudge Report?
- **Posição:** [-2280, 528]

**Configuração:**

```
Mode: Rules

Regra 0 (Output 0):
  Left Value:  {{ $('trigger-whatsapp').item.json.messages[0].interactive?.button_reply?.id || '' }}
  Operation:   starts with
  Right Value: report_sim_

Regra 1 (Output 1):
  Left Value:  {{ $('trigger-whatsapp').item.json.messages[0].interactive?.button_reply?.id || '' }}
  Operation:   equals
  Right Value: report_nao

Fallback Output: ON (gera output 2 = default)
```

### 3. Conectar

```
Edit Fields → É Nudge Report?
É Nudge Report? [output 2 / default] → If ("Resuma para mim")
```

---

### 4. Criar caminho `report_sim` (Output 0) — 5 nodes

#### Node: `Buscar Profile Report`
```
Tipo: Supabase
Credential: "Total Supabase" (ID: IKPzp0SrhjoEMH0z)
Operation: Get
Table: profiles
Filter: phone = {{ $('trigger-whatsapp').item.json.messages[0].from }}
```

#### Node: `Calcular Período` (Code)
```
Tipo: Code
Language: JavaScript
```

```javascript
const buttonId = $('trigger-whatsapp').item.json
  .messages[0].interactive.button_reply.id;

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
    endDate: ano + '-' + pad2(mes) + '-' + pad2(lastDay) + 'T23:59:59-03:00'
  }
}];
```

#### Node: `Gerar Relatório Nudge` (HTTP Request)
```
Tipo: HTTP Request
Method: POST
URL: http://76.13.172.17:5678/webhook/report
Authentication: Generic Credential Type → HTTP Basic Auth
Credential: "Basic Auth Google" (ID: f031WiARtCEWQuVs)

Send Body: ON
Specify Body: JSON
JSON Body:
={{ {
  user_id: $json.user_id,
  tipo: $json.tipo,
  label: $json.label,
  startDate: $json.startDate,
  endDate: $json.endDate
} }}
```

#### Node: `Msg Relatório Gerando` (WhatsApp)
```
Tipo: WhatsApp
Credential: "WhatsApp account 2" (ID: OiRJwFsREONcxZdW)
Operation: Send
Phone Number ID: 744582292082931
Recipient: +{{ $('trigger-whatsapp').item.json.messages[0].from }}
Text: Gerando seu relatório de {{ $('Calcular Período').item.json.label }}... 📊
```

#### Node: `Log Nudge Aceito` (HTTP Request)
```
Tipo: HTTP Request
Method: POST
URL: https://hkzgttizcfklxfafkzfl.supabase.co/rest/v1/log_total

Headers:
  apikey = eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Imhremd0dGl6Y2ZrbHhmYWZremZsIiwicm9sZSI6InNlcnZpY2Vfcm9sZSIsImlhdCI6MTc3MDIwODYwMSwiZXhwIjoyMDg1Nzg0NjAxfQ._DkH_9A7E1xe6WXOsWNKSWgsRcYJfxjhyTvpXFm23ok
  Authorization = Bearer (mesma key)
  Content-Type = application/json
  Prefer = return=minimal

JSON Body:
={{ {
  user_id: $('Calcular Período').item.json.user_id,
  acao: 'nudge_mensal_aceito',
  mensagem: 'User aceitou nudge, relatório de ' + $('Calcular Período').item.json.label + ' solicitado',
  categoria: 'nudge'
} }}
```

#### Conexões:
```
É Nudge Report? [output 0] → Buscar Profile Report
Buscar Profile Report → Calcular Período
Calcular Período → Gerar Relatório Nudge
Gerar Relatório Nudge → Msg Relatório Gerando
Msg Relatório Gerando → Log Nudge Aceito
```

---

### 5. Criar caminho `report_nao` (Output 1) — 2 nodes

#### Node: `Msg Nudge Dispensado` (WhatsApp)
```
Tipo: WhatsApp
Credential: "WhatsApp account 2" (ID: OiRJwFsREONcxZdW)
Operation: Send
Phone Number ID: 744582292082931
Recipient: +{{ $('trigger-whatsapp').item.json.messages[0].from }}
Text: Sem problemas! Quando quiser, é só pedir "gera meu relatório". 📊
```

#### Node: `Log Nudge Recusado` (HTTP Request)
```
Tipo: HTTP Request
Method: POST
URL: https://hkzgttizcfklxfafkzfl.supabase.co/rest/v1/log_total

Headers: (mesmas do Log Nudge Aceito)

JSON Body:
={{ {
  user_id: 'unknown',
  acao: 'nudge_mensal_recusado',
  mensagem: 'User recusou nudge de relatório mensal',
  categoria: 'nudge'
} }}
```

#### Conexões:
```
É Nudge Report? [output 1] → Msg Nudge Dispensado
Msg Nudge Dispensado → Log Nudge Recusado
```

---

## Parte B — Disparar Nudge em Paralelo com Premium User

### 6. Criar node `Consume Nudge` (HTTP Request)

```
Tipo: HTTP Request
Method: POST
URL: https://ldbdtakddxznfridsarn.supabase.co/rest/v1/rpc/consume_monthly_nudge
Posição sugerida: [-80, 480]

Headers:
  apikey = eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImxkYmR0YWtrZHh6bmZyaWRzYXJuIiwicm9sZSI6InNlcnZpY2Vfcm9sZSIsImlhdCI6MTc1MzgxMTU3OCwiZXhwIjoyMDY5Mzg3NTc4fQ.sgZAmagW59WkngAIbI5QX5X05sfdmRF-PPsdxO1mwTE
  Authorization = Bearer (mesma key)
  Content-Type = application/json

JSON Body:
={{ { p_user_id: $('setar_user').item.json.id_user } }}
```

### 7. Criar node `Nudge Consumido?` (IF)

```
Tipo: IF
Posição: [128, 480]

Condição:
  Left Value: {{ $json.consumed }}
  Operation: is true (boolean true)
```

### 8. Criar node `Disparar Nudge` (HTTP Request)

```
Tipo: HTTP Request
Method: POST
URL: http://76.13.172.17:5678/webhook/nudge-relatorio
  ⚠️ VERIFICAR: o path pode mudar para UUID ao salvar o workflow.
     Conferir o path real em "Nudge Relatório Mensal" → node webhook-nudge.
Authentication: Generic Credential Type → HTTP Basic Auth
Credential: "Basic Auth Google" (ID: f031WiARtCEWQuVs)
Posição: [368, 440]

Send Body: ON
Specify Body: JSON

JSON Body:
={{ {
  phone: $('setar_user').item.json.telefone,
  nome: $('setar_user').item.json.nome,
  user_id: $('setar_user').item.json.id_user,
  report_month: $json.report_month
} }}
```

### 9. Conectar branch nudge

```
setar_user → Consume Nudge          ← SEGUNDA saída (NÃO remover Premium User!)
Consume Nudge → Nudge Consumido?
Nudge Consumido? [true] → Disparar Nudge
Nudge Consumido? [false] → (nada)
```

**Como adicionar segunda conexão:**
1. Passar mouse sobre a bolinha de saída de `setar_user`
2. A conexão para `Premium User` já existe — NÃO remover
3. Arrastar NOVA linha da mesma bolinha para `Consume Nudge`
4. Ambas executam em paralelo
