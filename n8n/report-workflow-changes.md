# Alteração no Report Workflow — Passo a Passo

**Workflow:** Relatórios Mensais-Semanais

---

## Passo 1: Colar o node

**Arquivo:** `nodes-limpar-flag-report.json`

1. Abrir o workflow "Relatórios Mensais-Semanais" no N8N
2. Copiar o conteúdo do arquivo JSON
3. Ctrl+V no canvas
4. O node `Limpar Nudge Flag` aparece

## Passo 2: Desconectar

- Localizar `buscar-perfil` e `Update a row8` (ficam perto, na linha do webhook-report)
- Deletar a conexão entre eles

## Passo 3: Reconectar

```
buscar-perfil → Limpar Nudge Flag → Update a row8
```

Pronto. Agora quando qualquer relatório for gerado (manual ou via nudge), a flag é limpa automaticamente.
