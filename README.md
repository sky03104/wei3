# 娃娃機管理系統－wei3（第二個場地）

從 [sky03104/wei](https://github.com/sky03104/wei) 的**資料庫版**（`feature/supabase-migration` 分支，前端 v63）
複製出來，給第二個場地用。

## 跟原本場地的關係

| | 原本場地（wei 資料庫版） | 第二個場地（這個 repo） |
|---|---|---|
| 資料庫 | Supabase 專案 `gwwuzmspgvpzlstvafov` 的 `public` schema | **同一個專案**的 `wei3` schema |
| 機台／獎型／快捷金額／入幣費率 | 自己一份 | 自己一份（2026-09-30 從原本場地複製一次當起點，之後各改各的） |
| 記帳紀錄／營業日／每日帳目 | 自己一份 | 自己一份（從空白開始） |
| 帳號 | `public.profiles`，內部 email `@migrated.local` | `wei3.profiles`，內部 email `@wei3.local` |
| 帳號管理 Edge Function | `admin-users` | `admin-users-wei3` |
| Google 試算表同步 | 有 | **沒有** |
| 網站 | Netlify | GitHub Pages（`docs/`） |

- 兩個場地的資料完全分開：原本場地的帳號登入 wei3 什麼都看不到、什麼都做不了，反過來也一樣
  （每支函式都用 `can_record()`／`is_admin()`／`can_see_machine()` 檢查，這些只查自己 schema 的帳號名單）。
- Supabase Auth（`auth.users`）整個專案共用一份，所以兩邊的內部 email 網域不同，才能有同名帳號。
- 免費方案的額度（資料庫 500 MB、每月流量 5 GB…）兩個場地一起算。

## 網頁設定（`docs/config.js`）

| 設定 | 值 | 用途 |
|---|---|---|
| `SUPABASE_SCHEMA` | `wei3` | 所有查詢／rpc 只打 wei3 |
| `ADMIN_USERS_FN` | `admin-users-wei3` | 建立帳號／重設密碼 |
| `STORAGE_PREFIX` | `wei3` | 瀏覽器儲存的名稱前綴。GitHub Pages 上 `sky03104.github.io/wei`（試算表版）跟這裡共用同一份瀏覽器儲存，前綴分開才不會互相登出 |
| `VENUE_NAME` | `wei3` | 顯示在登入頁與首頁標題，想改成場地名字就改這裡 |

`docs/app.js` 跟原本資料庫版 v63 的差別只有：上面四個設定、`render()` 在 Supabase 後端不再要求
`GAS_API_URL`、版本號從 `w3-v1` 開始。`docs/sw.js` 的快取名稱改成 `wei3-shell-` 開頭，換版時只清自己的舊快取。
改前端時 `app.js` 的 `APP_VERSION` 跟 `sw.js` 的 `CACHE_VERSION` 要一起改（`w3-v1` → `w3-v2`…）。

## 資料庫（`supabase/`）

- `wei3_setup.sql`：建立 wei3 的完整步驟（2026-09-30 套用過一次，不用再跑）。整段包在一個 DO 區塊裡，
  失敗就全部不留。資料表用 `schema.sql`、權限規則用 `policies.sql`，函式從原本場地當時的定義複製，
  每支函式的 `search_path` 都固定成 `wei3`，就算呼叫端帶到 `public` 也不會讀寫到原本場地。
- `schema.sql`／`policies.sql`／`functions.sql`：wei3 目前的結構，跟原本場地一樣
  （`policies.sql` 的 helper 函式已改成 `search_path = wei3`）。
- `functions/admin-users-wei3/index.ts`：帳號管理 Edge Function，只管 `wei3.profiles` 裡的帳號。

### 之後要改 wei3 的資料庫函式

`functions.sql` 裡的函式沒寫 schema 名稱，**一定要**在同一個交易裡先切 search_path，再把
search_path 固定在函式上，否則會改到原本場地（public）：

```sql
begin;
set local search_path = wei3, pg_temp;
create or replace function xxx(...) ...;             -- 從 functions.sql 貼過來
alter function xxx(...) set search_path = wei3, pg_temp;
commit;
```

改完用這個確認沒有漏掉固定 search_path 的函式（結果要是空的）：

```sql
select proname from pg_proc
where pronamespace = 'wei3'::regnamespace
  and not exists (select 1 from unnest(coalesce(proconfig, '{}')) c where c like 'search_path=wei3%');
```

## 骰台結算區（本期／前期／租金／入幣*5%／總額）

「骰台查詢」（全部骰台）按「📷 匯出截圖」或「⬇ 匯出 Excel」時，會先跳視窗問要不要加入前期、租金；
每台的對帳表在「總出幣…+/-」那組欄位右邊多兩欄：

| 列 | 內容 |
|---|---|
| 本期 | 該台查詢區間的 +/- 總計（照原數字，負的就是負的）。「本週」是週日到今天，要完整週日～週六請用「自訂」 |
| 前期 | 有勾才帶：該台上一期（區間結束日早於本期起始日的最新一筆）匯出時存下的總額 |
| 租金 | 有勾才帶：名稱（例：租金9/1-9/30）與金額填一次，再勾要扣的機台；沒勾的機台這格空白、不扣 |
| 入幣*5% | -round(總入幣 × 5%) |
| 總額 | 本期 + 前期 − 租金 − 入幣*5% |

每次匯出都會把各台總額存進 `wei3.settlements`（同台同區間重複匯出是覆寫），下一期的「前期」就從這裡抓。
只有管理員／巡邏人員會存檔，台主匯出只計算不存。資料表定義在 `supabase/settlements.sql`（要在 SQL editor 跑一次）。

## 部署

- **網站**：GitHub → Settings → Pages → Source 選「Deploy from a branch」→ Branch 選 `main`、資料夾 `/docs` → Save。
  網址是 `https://sky03104.github.io/wei3/`。
- **Supabase 後台**：Project Settings → Data API → Exposed schemas 要有 `wei3`（已設定就不用再動）。
