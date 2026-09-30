// supabase/functions/admin-users-wei3/index.ts
//
// wei3（第二個場地）專用的帳號管理 Edge Function：「建立全新帳號」「重設密碼」
// 這兩件需要 service role key 的事。從原本場地的 admin-users 複製過來，差別只有：
//   1. 所有資料表操作都走 wei3 schema（db: { schema: 'wei3' }），只看得到、只改得到
//      wei3.profiles 這份帳號名單。
//   2. 新帳號的內部 email 用 @wei3.local（原本場地是 @migrated.local）。Supabase Auth
//      整個專案共用一份帳號表，email 不能重複；分開網域，兩個場地才能有同名帳號。
//   3. 重設密碼前先確認對象在 wei3.profiles 裡。Auth 帳號表是兩個場地共用的，
//      沒有這道檢查的話，wei3 的管理員只要知道原本場地某個帳號的內部 ID，就能改掉
//      那個帳號的密碼。
//
// 部署：Supabase 後台（或 MCP deploy_edge_function）名稱 admin-users-wei3，
// verify_jwt 開著（跟原本的 admin-users 一樣）。前端 docs/config.js 的
// ADMIN_USERS_FN 要設成 'admin-users-wei3'。

import { createClient } from 'npm:@supabase/supabase-js@2';

const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!;
const SERVICE_ROLE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
const ANON_KEY = Deno.env.get('SUPABASE_ANON_KEY')!;

const SCHEMA = 'wei3';
const EMAIL_DOMAIN = 'wei3.local';

// 前端是瀏覽器直接呼叫，一定要回 CORS 標頭（原因見原本場地 admin-users 的說明）。
const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, apikey, content-type, x-client-info',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { 'Content-Type': 'application/json', ...corsHeaders },
  });
}

function assertPasswordStrength(password: string) {
  if (password.length < 6) throw new Error('密碼至少 6 個字');
  if (password.length > 64) throw new Error('密碼請在 64 字以內');
}

Deno.serve(async (req: Request) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders });
  if (req.method !== 'POST') return json({ error: 'Method not allowed' }, 405);

  // 呼叫者的身分只能信 Authorization header 裡的 JWT；先用呼叫者自己的 token
  // 確認他是 wei3 的 active 管理員，才切去 service role 做真正的操作。
  // 原本場地的帳號在 wei3.profiles 查不到，會在這裡被擋下來。
  const authHeader = req.headers.get('Authorization') || '';
  if (!authHeader) return json({ error: '未登入' }, 401);

  const callerClient = createClient(SUPABASE_URL, ANON_KEY, {
    global: { headers: { Authorization: authHeader } },
    db: { schema: SCHEMA },
  });
  const { data: authData, error: authErr } = await callerClient.auth.getUser();
  if (authErr || !authData.user) return json({ error: '請重新登入' }, 401);

  const { data: callerProfile } = await callerClient
    .from('profiles')
    .select('role, status')
    .eq('id', authData.user.id)
    .single();
  if (!callerProfile || callerProfile.role !== 'admin' || callerProfile.status !== 'active') {
    return json({ error: '只有管理員能執行這個操作' }, 403);
  }

  let body: Record<string, unknown>;
  try {
    body = await req.json();
  } catch {
    return json({ error: '請求格式錯誤' }, 400);
  }

  const admin = createClient(SUPABASE_URL, SERVICE_ROLE_KEY, { db: { schema: SCHEMA } });
  const action = String(body.action || '');

  try {
    if (action === 'createUser') {
      const username = String(body.username || '').trim();
      if (!/^[A-Za-z0-9_.-]{3,20}$/.test(username)) {
        return json({ error: '帳號只能用英數字與 _ . -，長度 3~20' }, 400);
      }
      const role = String(body.role || '');
      if (!['admin', 'patrol', 'owner'].includes(role)) {
        return json({ error: '角色不正確' }, 400);
      }
      const password = String(body.password || '');
      assertPasswordStrength(password);
      const displayName = String(body.displayName || username).substring(0, 30);

      const { data: existing } = await admin
        .from('profiles')
        .select('id')
        .ilike('username', username)
        .maybeSingle();
      if (existing) return json({ error: '這個帳號已經存在' }, 400);

      const email = username.toLowerCase() + '@' + EMAIL_DOMAIN;
      const { data: created, error: createErr } = await admin.auth.admin.createUser({
        email,
        password,
        email_confirm: true,
        user_metadata: { username },
      });
      if (createErr) return json({ error: createErr.message }, 400);

      const { error: profileErr } = await admin.from('profiles').insert({
        id: created.user.id,
        username,
        display_name: displayName,
        role,
        status: 'active',
      });
      if (profileErr) {
        // profiles 寫失敗，Auth 那邊剛建的帳號會變孤兒——盡量清掉，錯誤照樣回報。
        await admin.auth.admin.deleteUser(created.user.id).catch(() => {});
        return json({ error: profileErr.message }, 400);
      }

      return json({ userId: created.user.id });
    }

    if (action === 'resetPassword') {
      const userId = String(body.userId || '');
      if (!userId) return json({ error: '缺少帳號 ID' }, 400);
      const password = String(body.password || '');
      assertPasswordStrength(password);

      // 只能改 wei3 自己帳號名單裡的人（Auth 帳號表兩個場地共用，見檔頭說明）
      const { data: target } = await admin
        .from('profiles')
        .select('id')
        .eq('id', userId)
        .maybeSingle();
      if (!target) return json({ error: '找不到這個帳號' }, 404);

      const { error } = await admin.auth.admin.updateUserById(userId, { password });
      if (error) return json({ error: error.message }, 400);

      return json({ userId, sessionsCleared: true });
    }

    return json({ error: '不支援的操作：' + action }, 400);
  } catch (err) {
    return json({ error: err instanceof Error ? err.message : String(err) }, 400);
  }
});
