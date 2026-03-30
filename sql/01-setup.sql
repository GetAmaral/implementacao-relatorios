-- ==========================================================
-- NUDGE RELATÓRIO MENSAL — SQL COMPLETO
--
-- Executar no Supabase SQL Editor
-- Projeto: ldbdtakddxznfridsarn (Banco Principal)
-- URL: https://supabase.com/dashboard/project/ldbdtakddxznfridsarn/sql
--
-- Ordem: rodar tudo de uma vez (copy-paste completo)
-- ==========================================================


-- =====================
-- 1. NOVAS COLUNAS
-- =====================

ALTER TABLE profiles
ADD COLUMN IF NOT EXISTS pending_monthly_report boolean DEFAULT false,
ADD COLUMN IF NOT EXISTS nudge_report_month date DEFAULT NULL;

-- pending_monthly_report: flag que indica se o user tem nudge pendente
-- nudge_report_month: qual mês o relatório cobre (primeiro dia do mês)


-- =====================
-- 2. FUNCTION: MARCAR USERS ELEGÍVEIS
-- Roda todo dia 1 do mês (via pg_cron ou N8N Schedule)
-- =====================

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

  -- 1) Resetar flags antigas (users que não mandaram msg no ciclo anterior)
  UPDATE profiles
  SET pending_monthly_report = false, nudge_report_month = NULL
  WHERE pending_monthly_report = true;

  -- 2) Marcar elegíveis: premium + plano ativo + pelo menos 1 gasto no mês anterior
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


-- =====================
-- 3. FUNCTION: CONSUMIR NUDGE (ATÔMICO)
-- Chamado pelo Main Workflow quando user manda mensagem.
-- Garante que apenas 1 processo consome o nudge (impede race condition).
-- =====================

CREATE OR REPLACE FUNCTION consume_monthly_nudge(p_user_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  result_month date;
BEGIN
  -- UPDATE atômico: se 2 mensagens chegam ao mesmo tempo,
  -- apenas 1 consegue fazer o UPDATE (WHERE pending = true)
  UPDATE profiles
  SET pending_monthly_report = false
  WHERE id = p_user_id AND pending_monthly_report = true
  RETURNING nudge_report_month INTO result_month;

  -- Se nenhuma row afetada, outro processo já consumiu
  IF NOT FOUND THEN
    RETURN '{"consumed": false}'::jsonb;
  END IF;

  RETURN jsonb_build_object('consumed', true, 'report_month', result_month);
END;
$$;


-- =====================
-- 4. FUNCTION: LIMPAR FLAG QUANDO RELATÓRIO GERADO
-- Chamado pelo Report Workflow quando qualquer relatório é gerado.
-- Se user pediu "gera meu relatório" manualmente, a flag é limpa
-- e ele não recebe nudge redundante.
-- =====================

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


-- =====================
-- 5. AGENDAMENTO (OPCIONAL — apenas se pg_cron disponível)
-- Se pg_cron não estiver ativo, usar o N8N Schedule Trigger
-- =====================

-- Descomentar as linhas abaixo se pg_cron estiver disponível:

-- CREATE EXTENSION IF NOT EXISTS pg_cron;
--
-- SELECT cron.schedule(
--   'mark-monthly-report-eligible',
--   '5 3 1 * *',    -- 03:05 UTC = 00:05 BRT
--   $$SELECT mark_monthly_report_eligible()$$
-- );


-- ==========================================================
-- TESTES (rodar manualmente para validar)
-- ==========================================================

-- Quantos users seriam marcados?
SELECT COUNT(DISTINCT s.fk_user) as elegiveis
FROM spent s
JOIN profiles p ON p.id = s.fk_user
WHERE s.date_spent >= date_trunc('month', now() - interval '1 month')
  AND s.date_spent < date_trunc('month', now())
  AND p.plan_type = 'premium'
  AND p.plan_status = true;

-- Executar marcação (descomentar para testar):
-- SELECT mark_monthly_report_eligible();

-- Verificar quem foi marcado:
-- SELECT id, name, phone, pending_monthly_report, nudge_report_month
-- FROM profiles WHERE pending_monthly_report = true;

-- Testar consume atômico (substituir UUID):
-- SELECT consume_monthly_nudge('2eb4065b-280c-4a50-8b54-4f9329bda0ff');
