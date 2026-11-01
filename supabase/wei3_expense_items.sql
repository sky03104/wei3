-- supabase/wei3_expense_items.sql
-- 2026-11-01：「開銷」改成可自訂名稱＋金額的多筆明細（跟台主給／台主領同一套做法）。
-- 只動 wei3 schema，原本場地（public）不受影響。在 Supabase SQL Editor 整段貼上執行即可，
-- 可以重複執行。舊資料不會消失：沒有明細的舊紀錄，畫面上會顯示成一筆叫「開銷」的項目。
-- 套用完不用重新設定 Exposed schemas（wei3 本來就開了）。

do $wei3$
begin
  perform set_config('search_path', 'wei3, pg_temp', true);
  if current_schema() is distinct from 'wei3' then
    raise exception '目前 schema 是 %，不是 wei3，中止', current_schema();
  end if;

  alter table wei3.daily_ledger
    add column if not exists manual_expense_items jsonb not null default '[]'::jsonb;

  -- 舊七參數版本先刪，免得新舊並存
  drop function if exists wei3.save_daily_ledger(numeric, numeric, numeric, numeric, jsonb, jsonb, numeric);
end
$wei3$;

set search_path = wei3, pg_temp;

create or replace function public_daily_ledger(p_row daily_ledger)
returns jsonb
language sql
set search_path = wei3, pg_temp
stable
as $$
  select jsonb_build_object(
    'turnover', coalesce(p_row.turnover, 0),
    'transport', coalesce(p_row.transport, 0),
    'givenToOwnerItems', ledger_items_or_legacy(p_row.given_to_owner_items, p_row.given_to_owner, '台主給'),
    'givenToOwner', sum_ledger_items(ledger_items_or_legacy(p_row.given_to_owner_items, p_row.given_to_owner, '台主給')),
    'takenByOwnerItems', ledger_items_or_legacy(p_row.taken_by_owner_items, p_row.taken_by_owner, '台主領'),
    'takenByOwner', sum_ledger_items(ledger_items_or_legacy(p_row.taken_by_owner_items, p_row.taken_by_owner, '台主領')),
    'returnedToHouse', coalesce(p_row.returned_to_house, 0),
    'manual432', coalesce(p_row.manual_432, 0),
    'manual441', coalesce(p_row.manual_441, 0),
    'manualExpense', coalesce(p_row.manual_expense, 0),
    'manualExpenseItems', ledger_items_or_legacy(p_row.manual_expense_items, p_row.manual_expense, '開銷'),
    'updatedAt', coalesce(p_row.updated_at::text, '')
  );
$$;

create or replace function save_daily_ledger(
  p_turnover numeric,
  p_manual_expense numeric,
  p_manual432 numeric,
  p_manual441 numeric,
  p_given_to_owner_items jsonb,
  p_taken_by_owner_items jsonb,
  p_returned_to_house numeric default 0,
  p_manual_expense_items jsonb default null
)
returns jsonb
language plpgsql
set search_path = wei3, pg_temp
as $$
declare
  v_turnover numeric := valid_signed_amount(p_turnover);
  v_expense_items jsonb := case when p_manual_expense_items is null then null
    else sanitize_ledger_items(p_manual_expense_items, true, '開銷') end;
  v_manual_expense numeric := case when v_expense_items is null then valid_outflow_amount(p_manual_expense)
    else sum_ledger_items(v_expense_items) end;
  v_manual432 numeric := valid_outflow_amount(p_manual432);
  v_manual441 numeric := valid_outflow_amount(p_manual441);
  v_given jsonb := sanitize_ledger_items(p_given_to_owner_items, false, '台主給');
  v_taken jsonb := sanitize_ledger_items(p_taken_by_owner_items, true, '台主領');
  v_returned numeric := valid_signed_amount(p_returned_to_house);
  v_relevant biz_days;
  v_business_date date;
begin
  if not can_record() then
    raise exception '你的帳號沒有這個權限' using errcode = '42501';
  end if;

  select * into v_relevant from relevant_biz_day_for_today();
  v_business_date := coalesce(v_relevant.business_date, today_key());

  insert into daily_ledger (
    ledger_id, business_date, biz_id, turnover, transport, given_to_owner, taken_by_owner,
    given_to_owner_items, taken_by_owner_items, returned_to_house, manual_432, manual_441,
    manual_expense, manual_expense_items, updated_by, updated_at
  ) values (
    new_id('ldg'), v_business_date, v_relevant.biz_id, v_turnover, 0, 0, 0,
    v_given, v_taken, v_returned, v_manual432, v_manual441,
    v_manual_expense, coalesce(v_expense_items, '[]'::jsonb), auth.uid(), now()
  )
  on conflict (business_date, (coalesce(biz_id, '')))
  do update set
    turnover = excluded.turnover,
    transport = 0,
    given_to_owner = 0,
    taken_by_owner = 0,
    given_to_owner_items = excluded.given_to_owner_items,
    taken_by_owner_items = excluded.taken_by_owner_items,
    returned_to_house = excluded.returned_to_house,
    manual_432 = excluded.manual_432,
    manual_441 = excluded.manual_441,
    manual_expense = excluded.manual_expense,
    manual_expense_items = excluded.manual_expense_items,
    updated_by = excluded.updated_by,
    updated_at = excluded.updated_at;

  return public_daily_ledger((select l from daily_ledger_row_for_today() l limit 1));
end;
$$;

-- 套用後權限：新函式要讓登入帳號能呼叫（default privileges 已涵蓋，這行是保險）
grant execute on function wei3.save_daily_ledger(numeric, numeric, numeric, numeric, jsonb, jsonb, numeric, jsonb) to authenticated;

reset search_path;
