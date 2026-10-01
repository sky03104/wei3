-- wei3：骰台查詢匯出的「結算區」（本期／前期／租金／入幣*5%／總額）存檔。
--
-- 每次在「全部骰台」匯出截圖或 Excel，前端（docs/app.js 的 _applySettlement()）
-- 會把每台算出來的總額寫一筆進來；下一期匯出勾「前期」時，就抓同一台
-- range_to 早於本期起始日的最新一筆 total 帶入。
-- 同一台、同一個區間重複匯出是覆寫（unique 索引 + upsert），不會疊出好幾筆。
--
-- 套用方式：整段貼到 Supabase SQL editor 執行一次（已經包好 begin/commit，
-- 並先把 search_path 切到 wei3，不會建到原本場地 public）。

begin;
set local search_path = wei3, pg_temp;

do $chk$
begin
  if current_schema() is distinct from 'wei3' then
    raise exception '目前 schema 是 %，不是 wei3，中止', current_schema();
  end if;
end
$chk$;

create table if not exists settlements (
  settlement_id  bigint generated always as identity primary key,
  machine_id     text not null references machines(machine_id),
  range_from     date not null,
  range_to       date not null,
  current_amt    numeric not null default 0, -- 本期（= 該區間 +/- 總計）
  prev_amt       numeric not null default 0, -- 前期（沒勾就是 0）
  rent_name      text,                        -- 租金名稱，例：租金9/1-9/30（沒勾是 null）
  rent_amt       numeric not null default 0, -- 租金金額（正數，計算時扣掉）
  fee_amt        numeric not null default 0, -- 入幣*5%（正數，計算時扣掉）
  total          numeric not null default 0, -- 總額 = 本期 + 前期 - 租金 - 入幣*5%
  created_by     uuid references profiles(id) default auth.uid(),
  created_at     timestamptz not null default now()
);

create unique index if not exists settlements_machine_range_idx
  on settlements (machine_id, range_from, range_to);
create index if not exists settlements_machine_to_idx
  on settlements (machine_id, range_to desc);

alter table settlements enable row level security;

-- 讀：看得到這台機台就讀得到（台主也能看到自己機台的前期）。
-- 寫：跟記帳一樣只有管理員／巡邏人員。
drop policy if exists settlements_select on settlements;
create policy settlements_select on settlements
  for select using (can_see_machine(machine_id));
drop policy if exists settlements_write on settlements;
create policy settlements_write on settlements
  for all using (can_record() and can_see_machine(machine_id))
  with check (can_record() and can_see_machine(machine_id));

grant all on settlements to anon, authenticated, service_role;

commit;
