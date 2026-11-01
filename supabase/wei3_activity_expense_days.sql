-- supabase/wei3_activity_expense_days.sql
-- 2026-11-01：活動查詢多回傳 manualExpenseDays（依日期列出每一筆開銷明細）。
-- 只動 wei3 schema。在 Supabase（wei 專案）SQL Editor 整段貼上執行，可重複執行。
-- 前提：已先套用 wei3_expense_items.sql（要有 manual_expense_items 欄位）。

set search_path = wei3, pg_temp;

create or replace function activity_query(p_from date, p_to date)
returns jsonb
language sql
stable
set search_path = wei3, pg_temp
as $$
  with range as (
    select * from resolve_range('custom', p_from, p_to)
  ),
  rows as (
    select r.* from records r, range
    where r.voided = false
      and r.type = 'prize'
      and r.business_date between range.range_from and range.range_to
      -- machines 已經被 RLS 篩過，這裡直接 join 現在看得到的機台即可，
      -- 不用像 GAS 版本那樣自己先查一輪 visibleMachineIds()。
      and r.machine_id in (select machine_id from machines)
  ),
  counts as (
    select
      coalesce(sum(count) filter (where prize_name = '432'), 0) as count432,
      coalesce(sum(count) filter (where prize_name = '441'), 0) as count441
    from rows
  ),
  -- 逐天取那一天 daily_ledger 最新（seq 最大）的一列，同一天可能因為忘記
  -- 結單又重開之類的情況存過好幾列，只算最後那列，其餘視為被覆蓋。
  latest_ledger_per_day as (
    select distinct on (business_date) business_date, manual_expense,
      ledger_items_or_legacy(manual_expense_items, manual_expense, '開銷') as items
    from daily_ledger
    where business_date between (select range_from from range) and (select range_to from range)
    order by business_date, seq desc
  )
  select jsonb_build_object(
    'range', jsonb_build_object(
      'from', (select range_from from range)::text, 'to', (select range_to from range)::text,
      'preset', (select preset from range)
    ),
    'count432', (select count432 from counts),
    'count441', (select count441 from counts),
    'manualExpense', coalesce((select sum(manual_expense) from latest_ledger_per_day), 0),
    -- 2026-11-01：每天的開銷明細（只列有開銷的日子，日期由舊到新）
    'manualExpenseDays', coalesce((
      select jsonb_agg(jsonb_build_object('date', business_date::text, 'items', items) order by business_date)
      from latest_ledger_per_day
      where jsonb_array_length(items) > 0
    ), '[]'::jsonb)
  );
$$;
reset search_path;
