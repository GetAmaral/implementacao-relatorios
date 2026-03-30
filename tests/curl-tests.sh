#!/bin/bash
# ==========================================================
# Testes do Sistema de Nudge Relatório Mensal
# Executar APÓS implementar todas as fases
# ==========================================================

echo "============================================"
echo "TESTE 1: Marcar user de teste como elegível"
echo "============================================"

# Rodar marcação manual (ajustar se necessário)
curl -s -X POST \
  "https://ldbdtakddxznfridsarn.supabase.co/rest/v1/rpc/mark_monthly_report_eligible" \
  -H "apikey: eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImxkYmR0YWtrZHh6bmZyaWRzYXJuIiwicm9sZSI6InNlcnZpY2Vfcm9sZSIsImlhdCI6MTc1MzgxMTU3OCwiZXhwIjoyMDY5Mzg3NTc4fQ.sgZAmagW59WkngAIbI5QX5X05sfdmRF-PPsdxO1mwTE" \
  -H "Authorization: Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImxkYmR0YWtrZHh6bmZyaWRzYXJuIiwicm9sZSI6InNlcnZpY2Vfcm9sZSIsImlhdCI6MTc1MzgxMTU3OCwiZXhwIjoyMDY5Mzg3NTc4fQ.sgZAmagW59WkngAIbI5QX5X05sfdmRF-PPsdxO1mwTE" \
  -H "Content-Type: application/json" \
  -d '{}'

echo ""
echo "→ Deve retornar o número de users marcados"
echo ""

# Verificar se Luiz Felipe foi marcado
echo "Verificando user de teste..."
curl -s \
  "https://ldbdtakddxznfridsarn.supabase.co/rest/v1/profiles?phone=eq.554391936205&select=id,name,phone,pending_monthly_report,nudge_report_month" \
  -H "apikey: eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImxkYmR0YWtrZHh6bmZyaWRzYXJuIiwicm9sZSI6InNlcnZpY2Vfcm9sZSIsImlhdCI6MTc1MzgxMTU3OCwiZXhwIjoyMDY5Mzg3NTc4fQ.sgZAmagW59WkngAIbI5QX5X05sfdmRF-PPsdxO1mwTE" \
  -H "Authorization: Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImxkYmR0YWtrZHh6bmZyaWRzYXJuIiwicm9sZSI6InNlcnZpY2Vfcm9sZSIsImlhdCI6MTc1MzgxMTU3OCwiZXhwIjoyMDY5Mzg3NTc4fQ.sgZAmagW59WkngAIbI5QX5X05sfdmRF-PPsdxO1mwTE" | python3 -m json.tool

echo ""
echo "→ Deve mostrar pending_monthly_report=true e nudge_report_month com data"
echo ""
read -p "Pressione Enter para continuar..."


echo "============================================"
echo "TESTE 2: Enviar mensagem (deve receber nudge)"
echo "============================================"

curl -s -X POST http://76.13.172.17:5678/webhook/dev-whatsapp \
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
            "id": "test_nudge_'$(date +%s)'",
            "timestamp": "'$(date +%s)'",
            "type": "text",
            "text": { "body": "oi" }
          }]
        }
      }]
    }]
  }'

echo ""
echo "→ Esperado: resposta normal (~5s) + nudge com botões (~10s depois)"
echo ""
read -p "Pressione Enter para continuar..."


echo "============================================"
echo "TESTE 3: Simular clique 'Sim, quero!'"
echo "============================================"

curl -s -X POST http://76.13.172.17:5678/webhook/dev-whatsapp \
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
            "id": "test_report_sim_'$(date +%s)'",
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

echo ""
echo "→ Esperado: 'Gerando relatório...' + PDF via WhatsApp (~30s)"
echo ""
read -p "Pressione Enter para continuar..."


echo "============================================"
echo "TESTE 4: Enviar msg normal (NÃO deve receber nudge)"
echo "============================================"

curl -s -X POST http://76.13.172.17:5678/webhook/dev-whatsapp \
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
            "id": "test_normal_'$(date +%s)'",
            "timestamp": "'$(date +%s)'",
            "type": "text",
            "text": { "body": "gastei 25 no almoço" }
          }]
        }
      }]
    }]
  }'

echo ""
echo "→ Esperado: apenas 'Gasto registrado' SEM nudge"
echo ""
read -p "Pressione Enter para continuar..."


echo "============================================"
echo "TESTE 5: Verificar logs"
echo "============================================"

curl -s \
  "https://hkzgttizcfklxfafkzfl.supabase.co/rest/v1/log_total?acao=like.nudge_*&order=created_at.desc&limit=10" \
  -H "apikey: eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Imhremd0dGl6Y2ZrbHhmYWZremZsIiwicm9sZSI6InNlcnZpY2Vfcm9sZSIsImlhdCI6MTc3MDIwODYwMSwiZXhwIjoyMDg1Nzg0NjAxfQ._DkH_9A7E1xe6WXOsWNKSWgsRcYJfxjhyTvpXFm23ok" \
  -H "Authorization: Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Imhremd0dGl6Y2ZrbHhmYWZremZsIiwicm9sZSI6InNlcnZpY2Vfcm9sZSIsImlhdCI6MTc3MDIwODYwMSwiZXhwIjoyMDg1Nzg0NjAxfQ._DkH_9A7E1xe6WXOsWNKSWgsRcYJfxjhyTvpXFm23ok" | python3 -m json.tool

echo ""
echo "→ Deve mostrar: nudge_mensal_marcados, nudge_mensal_enviado, nudge_mensal_aceito"
echo ""
echo "============================================"
echo "TESTES CONCLUÍDOS"
echo "============================================"
