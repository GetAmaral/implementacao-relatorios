# Sistema de Nudge de Relatório Mensal

**Projeto:** Total Assistente
**Objetivo:** Todo dia 1 do mês, identificar usuários premium com gastos no mês anterior. Na próxima mensagem que enviarem, oferecer o relatório financeiro via interactive button do WhatsApp.

---

## Como funciona

```
Dia 1 do mês
  → Supabase marca users elegíveis (pending = true)

User manda mensagem qualquer
  → Main Workflow processa normalmente (gasto registrado, evento criado, etc.)
  → Em PARALELO, checa se user tem nudge pendente
  → Se sim: consome flag + dispara workflow separado com delay de 10s
  → User recebe resposta normal + nudge como segunda mensagem

User clica [Sim, quero!]
  → Main Workflow intercepta o button reply
  → Chama webhook-report com período do mês
  → User recebe PDF do relatório

User clica [Agora não]
  → "Sem problemas!"
  → Flag já consumida, não pergunta de novo
```

## Estrutura do repositório

```
/
├── README.md                          ← Este arquivo
├── sql/
│   └── 01-setup.sql                   ← SQL completo (colar no Supabase SQL Editor)
├── n8n/
│   ├── workflow-nudge-relatorio.json  ← Novo workflow (importar no N8N)
│   ├── main-workflow-changes.md       ← Alterações no Main Workflow (passo a passo)
│   └── report-workflow-changes.md     ← Alteração no Report Workflow (1 node)
├── docs/
│   ├── plano-v2.md                    ← Plano arquitetural completo
│   ├── auditoria-falhas.md            ← 20 falhas encontradas e resolvidas
│   └── guia-implementacao.md          ← Guia copy-paste detalhado
└── tests/
    └── curl-tests.sh                  ← Comandos curl para testar
```

## Ordem de execução

1. **SQL** — Rodar `sql/01-setup.sql` no Supabase SQL Editor
2. **Novo Workflow** — Importar `n8n/workflow-nudge-relatorio.json` no N8N DEV
3. **Main Workflow** — Seguir `n8n/main-workflow-changes.md`
4. **Report Workflow** — Seguir `n8n/report-workflow-changes.md`
5. **Testar** — Rodar `tests/curl-tests.sh`

## Credentials necessárias (já existem no N8N)

| Nome | ID | Tipo | Uso |
|------|-----|------|-----|
| Total Supabase | `IKPzp0SrhjoEMH0z` | supabaseApi | Queries no banco |
| WhatsApp account 2 | `OiRJwFsREONcxZdW` | whatsAppApi | Enviar mensagens WhatsApp (node nativo) |
| z-api marcio | `nuraEsunXXhjSpGT` | httpHeaderAuth | WhatsApp via graph.facebook.com |
| Basic Auth Google | `f031WiARtCEWQuVs` | httpBasicAuth | Autenticação entre webhooks |
