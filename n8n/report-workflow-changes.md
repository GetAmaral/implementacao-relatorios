# Alteração no Report Workflow

**Workflow:** Relatórios Mensais-Semanais (`0erjX5QpI9IJEmdi`)

**Mudança:** Adicionar 1 node entre `buscar-perfil` e `Update a row8` para limpar a flag de nudge quando um relatório é gerado por qualquer caminho (manual ou nudge).

---

## 1. Desconectar

```
buscar-perfil (posição [304, 1264])  →✂️→  Update a row8 (posição [432, 1264])
```

## 2. Criar node `Limpar Nudge Flag`

```
Tipo: HTTP Request
Nome: Limpar Nudge Flag
Posição sugerida: [368, 1264]

Method: POST
URL: https://ldbdtakddxznfridsarn.supabase.co/rest/v1/rpc/clear_nudge_on_report

Send Headers: ON
Headers:
  apikey = eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImxkYmR0YWtrZHh6bmZyaWRzYXJuIiwicm9sZSI6InNlcnZpY2Vfcm9sZSIsImlhdCI6MTc1MzgxMTU3OCwiZXhwIjoyMDY5Mzg3NTc4fQ.sgZAmagW59WkngAIbI5QX5X05sfdmRF-PPsdxO1mwTE
  Authorization = Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImxkYmR0YWtrZHh6bmZyaWRzYXJuIiwicm9sZSI6InNlcnZpY2Vfcm9sZSIsImlhdCI6MTc1MzgxMTU3OCwiZXhwIjoyMDY5Mzg3NTc4fQ.sgZAmagW59WkngAIbI5QX5X05sfdmRF-PPsdxO1mwTE
  Content-Type = application/json

Send Body: ON
Specify Body: JSON

JSON Body:
={{ { p_user_id: $('webhook-report').item.json.body.user_id } }}
```

## 3. Reconectar

```
buscar-perfil → Limpar Nudge Flag → Update a row8
```

O restante do fluxo (buscar-gastos → gerar-html → gotenberg → upload → enviar) permanece inalterado.
