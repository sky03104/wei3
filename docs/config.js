/**
 * wei3（第二個場地）的連線設定。
 *
 * 跟原本場地共用同一個 Supabase 專案，但資料放在獨立的 wei3 schema，
 * 兩邊的機台、記帳紀錄、營業日、帳號完全分開（見 README.md）。
 * wei3 沒有 Google Apps Script 後端，也沒有同步 Google 試算表。
 *
 * 這個檔案是公開的沒關係：anon key 本來就是給瀏覽器用的公開金鑰，
 * 真正擋人的是資料庫的 RLS 與函式裡的權限檢查。
 */
window.APP_CONFIG = {
  BACKEND: 'supabase',
  SUPABASE_URL: 'https://gwwuzmspgvpzlstvafov.supabase.co',
  SUPABASE_ANON_KEY: 'sb_publishable_47e2AZYATL2emOv5B-gYjg_5MKCMem3',

  // 這個場地的資料在哪個 schema（原本場地是 public）
  SUPABASE_SCHEMA: 'wei3',
  // 建立帳號／重設密碼用的 Edge Function（只管 wei3 自己的帳號）
  ADMIN_USERS_FN: 'admin-users-wei3',
  // 瀏覽器儲存的名稱前綴：GitHub Pages 上 sky03104.github.io 底下的網站共用
  // 同一份瀏覽器儲存，跟原本的 'claw' 分開，兩個 App 的登入狀態才不會互相蓋掉
  STORAGE_PREFIX: 'wei3',
  // 顯示在登入頁與首頁標題的場地名稱（想改成場地的名字直接改這裡）
  VENUE_NAME: 'wei3'
};
