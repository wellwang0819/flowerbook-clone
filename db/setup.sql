-- ====================================================
-- 复刻版：花册公会系统 Supabase 建库脚本
-- 在 Supabase SQL Editor 中整段执行即可
-- 公会名/成员均为占位，部署后请自行修改
-- ====================================================

create extension if not exists pgcrypto;

-- 公会表
create table if not exists public.guilds (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  slug text unique not null,
  reminder_enabled boolean not null default false,
  created_by text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- 成员表（id 用文本，支持自定义 id；password_hash 为 sha256(密码)）
create table if not exists public.guild_members (
  id text primary key,
  guild_id uuid not null references public.guilds(id) on delete cascade,
  name text not null,
  role text not null default 'member',
  status text not null default 'active',
  password_hash text not null,
  created_at timestamptz not null default now()
);

-- 花朵表（id 即花名）
create table if not exists public.flowers (
  id text primary key,
  name text not null,
  primary_channel text,
  sources jsonb not null default '[]'::jsonb,
  grow_time text,
  competition_score integer not null default 0,
  currency text,
  price numeric,
  order_exp text,
  order_price numeric,
  materials text,
  vase text,
  image_url text,
  is_custom boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- 拥有关系表（own=已拥有 / cultivating=待培育）
create table if not exists public.flower_ownership (
  id uuid primary key default gen_random_uuid(),
  flower_id text not null references public.flowers(id) on delete cascade,
  member_id text not null references public.guild_members(id) on delete cascade,
  status text not null default 'own',
  created_at timestamptz not null default now(),
  unique (flower_id, member_id, status)
);

-- 竞赛任务表
create table if not exists public.competition_tasks (
  id uuid primary key default gen_random_uuid(),
  guild_id uuid not null references public.guilds(id) on delete cascade,
  title text not null,
  done boolean not null default false,
  sort_order integer not null default 0,
  created_by text,
  created_at timestamptz not null default now(),
  completed_at timestamptz
);

-- 竞赛操作日志
create table if not exists public.competition_logs (
  id uuid primary key default gen_random_uuid(),
  guild_id uuid not null references public.guilds(id) on delete cascade,
  task_id uuid references public.competition_tasks(id) on delete set null,
  content text not null,
  created_by text,
  created_at timestamptz not null default now()
);

-- 索引
create index if not exists idx_members_guild on public.guild_members(guild_id);
create index if not exists idx_own_flower on public.flower_ownership(flower_id);
create index if not exists idx_own_member on public.flower_ownership(member_id);
create index if not exists idx_tasks_guild on public.competition_tasks(guild_id);
create index if not exists idx_logs_guild on public.competition_logs(guild_id);

-- 启用行级安全（匿名可读公共数据；写操作见部署文档说明）
alter table public.guilds enable row level security;
alter table public.guild_members enable row level security;
alter table public.flowers enable row level security;
alter table public.flower_ownership enable row level security;
alter table public.competition_tasks enable row level security;
alter table public.competition_logs enable row level security;

drop policy if exists "pub_read_guilds" on public.guilds;
create policy "pub_read_guilds" on public.guilds for select using (true);
drop policy if exists "pub_read_guild_members" on public.guild_members;
create policy "pub_read_guild_members" on public.guild_members for select using (true);
drop policy if exists "pub_read_flowers" on public.flowers;
create policy "pub_read_flowers" on public.flowers for select using (true);

drop policy if exists "pub_write_flower_ownership" on public.flower_ownership;
create policy "pub_write_flower_ownership" on public.flower_ownership for all using (true) with check (true);
drop policy if exists "pub_write_competition_tasks" on public.competition_tasks;
create policy "pub_write_competition_tasks" on public.competition_tasks for all using (true) with check (true);
drop policy if exists "pub_write_competition_logs" on public.competition_logs;
create policy "pub_write_competition_logs" on public.competition_logs for all using (true) with check (true);

-- 成员表：仅允许应用层通过 RPC 读，这里放开匿名读（部署后可收紧）
drop policy if exists "pub_write_guild_members" on public.guild_members;
create policy "pub_write_guild_members" on public.guild_members for all using (true) with check (true);

-- RPC：主页聚合数据（花朵 + 拥有关系 + 成员）
create or replace function public.get_guild_home_data(p_guild_id uuid)
returns jsonb language plpgsql security definer as $$
declare
  v_guild_id uuid := coalesce(p_guild_id, '00000000-0000-0000-0000-000000000001');
begin
  return jsonb_build_object(
    'flowers', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'id', f.id,
        'name', f.name,
        'competition_score', f.competition_score,
        'owners', (
          select coalesce(jsonb_agg(jsonb_build_object(
            'member_id', o.member_id,
            'member_name', m.name,
            'status', o.status
          ) order by m.name), '[]'::jsonb)
          from public.flower_ownership o
          join public.guild_members m on m.id = o.member_id
          where o.flower_id = f.id and o.status = 'own'
        )
      )), '[]'::jsonb)
      from public.flowers f),
    'members', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'id', gm.id,
        'name', gm.name,
        'role', gm.role,
        'status', gm.status,
        'created_at', gm.created_at
      ) order by gm.created_at), '[]'::jsonb)
      from public.guild_members gm where gm.guild_id = v_guild_id
    )
  );
end; $$;

-- RPC：扩展数据（分数表 / 花朵详情 / 待培育 / 自定义缺失）
create or replace function public.get_guild_extra_data(p_guild_id uuid)
returns jsonb language plpgsql security definer as $$
declare
  v_guild_id uuid := coalesce(p_guild_id, '00000000-0000-0000-0000-000000000001');
begin
  return jsonb_build_object(
    'scores', (
      select coalesce(jsonb_object_agg(f.id, f.competition_score), '{}'::jsonb)
      from public.flowers f),
    'flowers', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'id', f.id,
        'name', f.name,
        'primary_channel', f.primary_channel,
        'sources', f.sources,
        'grow_time', f.grow_time,
        'competition_score', f.competition_score,
        'currency', f.currency,
        'price', f.price,
        'vase', f.vase,
        'image_url', f.image_url,
        'is_custom', f.is_custom
      )), '[]'::jsonb)
      from public.flowers f),
    'missing', (
      select coalesce(jsonb_object_agg(x.flower_id, x.member_ids), '{}'::jsonb)
      from (
        select o.flower_id, jsonb_agg(o.member_id) as member_ids
        from public.flower_ownership o
        join public.flowers f on f.id = o.flower_id
        where o.status = 'own' and (f.image_url is null or f.image_url = '')
        group by o.flower_id
      ) x),
    'cultivation', (
      select coalesce(jsonb_object_agg(x.flower_id, x.member_ids), '{}'::jsonb)
      from (
        select o.flower_id, jsonb_agg(o.member_id) as member_ids
        from public.flower_ownership o
        where o.status = 'cultivating'
        group by o.flower_id
      ) x
    )
  );
end; $$;

-- ====================================================
-- 种子数据（占位公会 + 占位成员 + 578 朵花）
-- 公会名 / 成员名均为占位，登录后请自行修改
-- ====================================================
insert into public.guilds (id, name, slug, reminder_enabled, created_by) values
  ('00000000-0000-0000-0000-000000000001', '（公会名称待设置）', 'my-guild', false, 'm-admin')
on conflict (id) do update set name = excluded.name;

insert into public.guild_members (id, guild_id, name, role, status, password_hash) values
  ('m-admin', '00000000-0000-0000-0000-000000000001', '会长·花语', 'admin', 'active', '240be518fabd2724ddb6f04eeb1da5967448d7e831c08c8fa822809f74c720a9'),
  ('m-vice', '00000000-0000-0000-0000-000000000001', '副会长·月影', 'vice', 'active', '03ac674216f3e15c761ee1a5e255f067953623c8b388b4459e13f978d7c846f4'),
  ('m-mgr', '00000000-0000-0000-0000-000000000001', '理事·晨星', 'mgr', 'active', '03ac674216f3e15c761ee1a5e255f067953623c8b388b4459e13f978d7c846f4'),
  ('m-elite', '00000000-0000-0000-0000-000000000001', '菁英·清风', 'elite', 'active', '03ac674216f3e15c761ee1a5e255f067953623c8b388b4459e13f978d7c846f4'),
  ('m-member1', '00000000-0000-0000-0000-000000000001', '成员·山茶', 'member', 'active', '03ac674216f3e15c761ee1a5e255f067953623c8b388b4459e13f978d7c846f4'),
  ('m-member2', '00000000-0000-0000-0000-000000000001', '成员·远岫', 'member', 'active', '03ac674216f3e15c761ee1a5e255f067953623c8b388b4459e13f978d7c846f4')
on conflict (id) do update set name = excluded.name, role = excluded.role;

insert into public.flowers (id, name, primary_channel, sources, grow_time, competition_score, currency, price, order_exp, vase, image_url, is_custom) values
  ('一串红', '一串红', '活动鲜花', '[{"detail": "", "channel": "活动鲜花"}]', NULL, 14, NULL, NULL, NULL, NULL, 'assets/flower-images/一串红.webp', true),
  ('三花水杨梅', '三花水杨梅', '花灵', '[{"detail": "", "channel": "花灵"}]', NULL, 23, NULL, NULL, NULL, NULL, 'assets/flower-images/三花水杨梅.webp', true),
  ('丹影蛾蝶花', '丹影蛾蝶花', '礼包花圃', '[{"detail": "", "channel": "礼包花圃"}]', NULL, 23, '元', 28.0, NULL, NULL, 'assets/flower-images/丹影蛾蝶花.webp', true),
  ('丹紫夹竹桃', '丹紫夹竹桃', '花坊', '[{"detail": "花坊", "channel": "花坊"}]', NULL, 14, '花坊币', 3880.0, '99', '流波花樽', 'assets/flower-images/丹紫夹竹桃.webp', false),
  ('丹红耧斗菜', '丹红耧斗菜', '礼包花圃', '[{"detail": "礼包花圃", "channel": "礼包花圃"}]', NULL, 23, '元', 28.0, NULL, '醉蕊金樽', 'assets/flower-images/丹红耧斗菜.webp', false),
  ('丹红蜀葵花', '丹红蜀葵花', '花坊', '[{"detail": "花坊", "channel": "花坊"}]', NULL, 14, '花坊币', 2880.0, '95', '翠羽芳华', 'assets/flower-images/丹红蜀葵花.webp', false),
  ('丹红龙面花', '丹红龙面花', '花之密令', '[{"detail": "花之密令", "channel": "花之密令"}]', NULL, 23, NULL, NULL, '密令获取', '翠羽芳华', 'assets/flower-images/丹红龙面花.webp', false),
  ('九色灵鹿', '九色灵鹿', '活动鲜花', '[{"detail": "", "channel": "活动鲜花"}]', NULL, 28, NULL, NULL, '活动获取', '活动专属（无花瓶关联）', 'assets/flower-images/九色灵鹿.webp', true),
  ('云峰龙吐珠', '云峰龙吐珠', '等级花', '[{"detail": "", "channel": "等级花"}]', NULL, 9, NULL, NULL, NULL, NULL, 'assets/flower-images/云峰龙吐珠.webp', true),
  ('云松墨笺', '云松墨笺', '活动鲜花', '[{"detail": "", "channel": "活动鲜花"}]', NULL, 25, NULL, NULL, NULL, NULL, 'assets/flower-images/云松墨笺.webp', true),
  ('云白垂丝茉莉', '云白垂丝茉莉', '礼包花圃', '[{"detail": "", "channel": "礼包花圃"}]', NULL, 23, '元', 28.0, NULL, NULL, 'assets/flower-images/云白垂丝茉莉.webp', true),
  ('云白玉叶金花', '云白玉叶金花', '等级花', '[{"detail": "", "channel": "等级花"}]', NULL, 9, NULL, NULL, NULL, NULL, 'assets/flower-images/云白玉叶金花.webp', true),
  ('云紫茨菇', '云紫茨菇', '礼包花圃', '[{"detail": "", "channel": "礼包花圃"}]', NULL, 23, '元', 28.0, NULL, NULL, 'assets/flower-images/云紫茨菇.webp', true),
  ('云紫马利筋', '云紫马利筋', '花坊', '[{"detail": "", "channel": "花坊"}]', NULL, 14, '花坊币', 3880.0, NULL, NULL, 'assets/flower-images/云紫马利筋.webp', true),
  ('云蓝音符花', '云蓝音符花', '星河映蕊', '[{"detail": "", "channel": "星河映蕊"}]', NULL, 21, NULL, NULL, NULL, NULL, 'assets/flower-images/云蓝音符花.webp', true),
  ('云蜜花菱草', '云蜜花菱草', '活动鲜花', '[{"detail": "", "channel": "活动鲜花"}]', NULL, 14, NULL, NULL, NULL, NULL, 'assets/flower-images/云蜜花菱草.webp', true),
  ('云锦芍药', '云锦芍药', '花坊', '[{"detail": "花坊", "channel": "花坊"}]', NULL, 21, '花坊币', 5880.0, '145', '碧荷灵篮', 'assets/flower-images/云锦芍药.webp', false),
  ('云霓紫露草', '云霓紫露草', '星河映蕊', '[{"detail": "", "channel": "星河映蕊"}]', NULL, 14, NULL, NULL, NULL, NULL, 'assets/flower-images/云霓紫露草.webp', true),
  ('仙女散花', '仙女散花', '礼包花圃', '[{"detail": "礼包花圃", "channel": "礼包花圃"}]', NULL, 25, '元', 68.0, NULL, '碧荷灵篮', 'assets/flower-images/仙女散花.webp', false),
  ('仙魅灵狐', '仙魅灵狐', '星辰商店', '[{"detail": "星辰商店", "channel": "星辰商店"}]', NULL, 28, '月令币', 3999.0, NULL, '紫藤流韵', 'assets/flower-images/仙魅灵狐.webp', false),
  ('伯利恒之星', '伯利恒之星', '累计充值', '[{"detail": "累计充值", "channel": "累计充值"}]', NULL, 23, NULL, NULL, '充值奖励', '充值奖励（无花瓶关联）', 'assets/flower-images/伯利恒之星.webp', false),
  ('元气破蛋', '元气破蛋', '活动鲜花', '[{"detail": "(元气破蛋)", "channel": "活动鲜花"}]', NULL, 25, NULL, NULL, '活动获取', '活动专属（无花瓶关联）', 'assets/flower-images/元气破蛋.webp', false),
  ('冰蓝彩叶草', '冰蓝彩叶草', 'VIP商店', '[{"detail": "", "channel": "VIP商店"}]', NULL, 14, NULL, NULL, NULL, NULL, 'assets/flower-images/冰蓝彩叶草.webp', true),
  ('冰蓝矮牵牛', '冰蓝矮牵牛', '花坊', '[{"detail": "花坊", "channel": "花坊"}]', '16:40:00', 21, '花坊币', 4880.0, NULL, NULL, 'assets/flower-images/冰蓝矮牵牛.webp', false),
  ('冰蓝蝶舞玫瑰', '冰蓝蝶舞玫瑰', '礼包花圃', '[{"detail": "礼包花圃", "channel": "礼包花圃"}]', NULL, 25, '元', 68.0, NULL, '蓝心涟漪', 'assets/flower-images/冰蓝蝶舞玫瑰.webp', false),
  ('冰蓝谷鸢尾', '冰蓝谷鸢尾', '花之密令', '[{"detail": "花之密令", "channel": "花之密令"}]', NULL, 14, NULL, NULL, '密令获取', '水舞苍穹', 'assets/flower-images/冰蓝谷鸢尾.webp', false),
  ('冰蓝黑种草', '冰蓝黑种草', '花灵', '[{"detail": "花灵", "channel": "花灵"}]', NULL, 23, '月令币', 3999.0, NULL, '幽蓝瓷瓶', 'assets/flower-images/冰蓝黑种草.webp', false),
  ('凉酥山雪', '凉酥山雪', '活动鲜花', '[{"detail": "", "channel": "活动鲜花"}]', NULL, 25, NULL, NULL, NULL, NULL, 'assets/flower-images/凉酥山雪.webp', true),
  ('凝夜紫薇', '凝夜紫薇', '花灵', '[{"detail": "花灵", "channel": "花灵"}]', NULL, 23, '月令币', 3999.0, NULL, '紫藤流韵', 'assets/flower-images/凝夜紫薇.webp', false),
  ('凝紫四照花', '凝紫四照花', '活动鲜花', '[{"detail": "", "channel": "活动鲜花"}]', NULL, 14, NULL, NULL, NULL, NULL, 'assets/flower-images/凝紫四照花.webp', true),
  ('凤梨花', '凤梨花', '花坊', '[{"detail": "花坊", "channel": "花坊"}]', '20:40:00', 14, '花坊币', 3880.0, NULL, NULL, 'assets/flower-images/凤梨花.webp', false),
  ('勿忘我', '勿忘我', '等级花', '[{"detail": "等级花", "channel": "等级花"}]', '1900/1/1 06:40:00', 9, NULL, NULL, '等级解锁', '基础等级花（无花瓶关联）', 'assets/flower-images/勿忘我.webp', false),
  ('半见长寿花', '半见长寿花', '花坊', '[{"detail": "花坊", "channel": "花坊"}]', NULL, 21, '花坊币', 5880.0, '145', '雪梅迎春', 'assets/flower-images/半见长寿花.webp', false),
  ('双辉忍冬', '双辉忍冬', '花灵', '[{"detail": "花灵", "channel": "花灵"}]', NULL, 23, '月令币', 3999.0, NULL, '幽木流芳', 'assets/flower-images/双辉忍冬.webp', false),
  ('合欢花', '合欢花', '等级花', '[{"detail": "等级花", "channel": "等级花"}]', '20:40:00', 9, NULL, NULL, '等级解锁', '基础等级花（无花瓶关联）', 'assets/flower-images/合欢花.webp', false),
  ('向日葵', '向日葵', '等级花', '[{"detail": "等级花", "channel": "等级花"}]', '13:20:00', 9, NULL, NULL, '等级解锁', '基础等级花（无花瓶关联）', 'assets/flower-images/向日葵.webp', false),
  ('圣心百合', '圣心百合', '等级花', '[{"detail": "等级花", "channel": "等级花"}]', '1900/1/1 10:00:00', 9, NULL, NULL, '等级解锁', '基础等级花（无花瓶关联）', 'assets/flower-images/圣心百合.webp', false),
  ('圣诞一品红', '圣诞一品红', '活动鲜花', '[{"detail": "(欢雪颂冬)", "channel": "活动鲜花"}]', NULL, 14, NULL, NULL, '活动获取', '活动专属（无花瓶关联）', 'assets/flower-images/圣诞一品红.webp', false),
  ('处暑·花苑拾香', '处暑·花苑拾香', '花灵', '[{"detail": "", "channel": "花灵"}]', NULL, 28, NULL, NULL, NULL, NULL, 'assets/flower-images/处暑·花苑拾香.webp', true),
  ('夕岚蔷薇花', '夕岚蔷薇花', '花坊', '[{"detail": "花坊", "channel": "花坊"}]', NULL, 21, '花坊币', 5880.0, '145', '流波花樽', 'assets/flower-images/夕岚蔷薇花.webp', false),
  ('夕照肖鸢尾', '夕照肖鸢尾', '礼包花圃', '[{"detail": "", "channel": "礼包花圃"}]', NULL, 23, NULL, NULL, NULL, NULL, 'assets/flower-images/夕照肖鸢尾.webp', true),
  ('夕蜻菖序', '夕蜻菖序', '鲜花礼包', '[{"detail": "", "channel": "鲜花礼包"}]', NULL, 25, '元', 68.0, NULL, NULL, 'assets/flower-images/夕蜻菖序.webp', true),
  ('夜梦花庭', '夜梦花庭', '活动鲜花', '[{"detail": "(夜梦花庭)", "channel": "活动鲜花"}]', NULL, 28, NULL, NULL, '活动获取', '活动专属（无花瓶关联）', 'assets/flower-images/夜梦花庭.webp', false),
  ('夜蓝香息', '夜蓝香息', '活动鲜花', '[{"detail": "(夜梦花庭)", "channel": "活动鲜花"}]', NULL, 28, NULL, NULL, '活动获取', '活动专属（无花瓶关联）', 'assets/flower-images/夜蓝香息.webp', false),
  ('大暑·夏漪清欢', '大暑·夏漪清欢', '花灵', '[{"detail": "", "channel": "花灵"}]', NULL, 28, NULL, NULL, NULL, NULL, 'assets/flower-images/大暑·夏漪清欢.webp', true),
  ('天上宫阙', '天上宫阙', '花灵商店', '[{"detail": "花灵商店", "channel": "花灵商店"}]', NULL, 30, '月令币', 3999.0, NULL, '翠金留芳', 'assets/flower-images/天上宫阙.webp', false),
  ('天下一墨', '天下一墨', '活动鲜花', '[{"detail": "", "channel": "活动鲜花"}]', NULL, 28, NULL, NULL, NULL, NULL, 'assets/flower-images/天下一墨.webp', true),
  ('天荷繁星', '天荷繁星', '花灵', '[{"detail": "花灵", "channel": "花灵"}]', NULL, 23, '月令币', 3999.0, NULL, '碧荷灵篮', 'assets/flower-images/天荷繁星.webp', false),
  ('奶桃大丽花', '奶桃大丽花', '花坊', '[{"detail": "花坊", "channel": "花坊"}]', NULL, 21, '花坊币', 4880.0, '130', '幽蓝瓷瓶', 'assets/flower-images/奶桃大丽花.webp', false),
  ('奶油向日葵', '奶油向日葵', '活动鲜花', '[{"detail": "", "channel": "活动鲜花"}]', NULL, 14, NULL, NULL, '活动获取', '活动专属（无花瓶关联）', 'assets/flower-images/奶油向日葵.webp', true),
  ('奶黄花毛茛', '奶黄花毛茛', '花之密令', '[{"detail": "花之密令", "channel": "花之密令"}]', NULL, 23, NULL, NULL, '密令获取', '月影藤生', 'assets/flower-images/奶黄花毛茛.webp', false),
  ('姑苏雨蒙', '姑苏雨蒙', '礼包花圃', '[{"detail": "礼包花圃", "channel": "礼包花圃"}]', NULL, 25, '元', 68.0, NULL, '碧荷灵篮', 'assets/flower-images/姑苏雨蒙.webp', false),
  ('custom_1776338959428_r18078', '嫣粉石斛兰', '活动鲜花', '[{"detail": "", "channel": "活动鲜花"}]', NULL, 14, NULL, NULL, NULL, NULL, 'assets/flower-images/嫣粉石斛兰.webp', true),
  ('嫣紫金鱼草', '嫣紫金鱼草', '花之密令', '[{"detail": "", "channel": "花之密令"}]', NULL, 23, NULL, NULL, NULL, NULL, 'assets/flower-images/嫣紫金鱼草.webp', true),
  ('嫣红杜鹃', '嫣红杜鹃', '花坊', '[{"detail": "花坊", "channel": "花坊"}]', NULL, 14, '花坊币', 3880.0, '99', '碧荷灵篮', 'assets/flower-images/嫣红杜鹃.webp', false),
  ('嫣红荼蘼花', '嫣红荼蘼花', '等级花', '[{"detail": "等级花", "channel": "等级花"}]', '1900/1/1 08:40:00', 9, NULL, NULL, '等级解锁', '基础等级花（无花瓶关联）', 'assets/flower-images/嫣红荼蘼花.webp', false),
  ('嫩粉沙漠玫', '嫩粉沙漠玫', '活动鲜花', '[{"detail": "", "channel": "活动鲜花"}]', NULL, 14, NULL, NULL, '活动获取', '活动专属（无花瓶关联）', 'assets/flower-images/嫩粉沙漠玫.webp', true),
  ('嫩绿洋桔梗', '嫩绿洋桔梗', '等级花', '[{"detail": "等级花", "channel": "等级花"}]', '1900/1/1 02:40:00', 9, NULL, NULL, '等级解锁', '基础等级花（无花瓶关联）', 'assets/flower-images/嫩绿洋桔梗.webp', false),
  ('嫩绿花烟草', '嫩绿花烟草', '花之密令', '[{"detail": "", "channel": "花之密令"}]', NULL, 14, NULL, NULL, '密令获取', '绿意翠瓶', 'assets/flower-images/嫩绿花烟草.webp', true),
  ('嫩翠大花萱草', '嫩翠大花萱草', '鲜花礼包', '[{"detail": "", "channel": "鲜花礼包"}]', NULL, 23, '元', 28.0, NULL, NULL, 'assets/flower-images/嫩翠大花萱草.webp', true),
  ('嫩黄君子兰', '嫩黄君子兰', '活动鲜花', '[{"detail": "(迎春接福)", "channel": "活动鲜花"}]', NULL, 14, NULL, NULL, '活动获取', '活动专属（无花瓶关联）', 'assets/flower-images/嫩黄君子兰.webp', false),
  ('嫩黄晚香玉', '嫩黄晚香玉', '等级花', '[{"detail": "等级花", "channel": "等级花"}]', NULL, 9, NULL, NULL, '等级解锁', '基础等级花（无花瓶关联）', 'assets/flower-images/嫩黄晚香玉.webp', false),
  ('嫩黄风信子', '嫩黄风信子', '等级花', '[{"detail": "等级花", "channel": "等级花"}]', '22:40:00', 9, NULL, NULL, '等级解锁', '基础等级花（无花瓶关联）', 'assets/flower-images/嫩黄风信子.webp', false),
  ('嫩黄马齿苋', '嫩黄马齿苋', '活动鲜花', '[{"detail": "国色芳华 （第二期）", "channel": "活动鲜花"}]', NULL, 14, NULL, NULL, '活动获取', '活动专属（无花瓶关联）', 'assets/flower-images/嫩黄马齿苋.webp', false),
  ('安眠薰衣草', '安眠薰衣草', '活动鲜花', '[{"detail": "(夜梦花庭)", "channel": "活动鲜花"}]', NULL, 14, NULL, NULL, '活动获取', '活动专属（无花瓶关联）', 'assets/flower-images/安眠薰衣草.webp', false),
  ('宝珠玉兰', '宝珠玉兰', '星河映蕊', '[{"detail": "星河映蕊", "channel": "星河映蕊"}]', NULL, 25, NULL, NULL, '抽取获取', '流波花樽', 'assets/flower-images/宝珠玉兰.webp', false),
  ('宫灯百合', '宫灯百合', '花灵', '[{"detail": "花灵", "channel": "花灵"}]', NULL, 23, '月令币', 3999.0, NULL, '金盏生芳', 'assets/flower-images/宫灯百合.webp', false),
  ('宫粉玉叶金花', '宫粉玉叶金花', '等级花', '[{"detail": "", "channel": "等级花"}]', NULL, 9, NULL, NULL, NULL, NULL, 'assets/flower-images/宫粉玉叶金花.webp', true),
  ('富贵竹', '富贵竹', '活动鲜花', '[{"detail": "(八分来财)", "channel": "活动鲜花"}]', NULL, 14, NULL, NULL, '活动获取', '活动专属（无花瓶关联）', 'assets/flower-images/富贵竹.webp', false),
  ('寻蜜之心', '寻蜜之心', '活动鲜花', '[{"detail": "(心联盟)", "channel": "活动鲜花"}]', NULL, 25, NULL, NULL, '活动获取', '活动专属（无花瓶关联）', 'assets/flower-images/寻蜜之心.webp', false),
  ('小苍兰', '小苍兰', '等级花', '[{"detail": "等级花", "channel": "等级花"}]', '12:00:00', 9, NULL, NULL, '等级解锁', '基础等级花（无花瓶关联）', 'assets/flower-images/小苍兰.webp', false),
  ('山茶花', '山茶花', '等级花', '[{"detail": "等级花", "channel": "等级花"}]', '10:40:00', 9, NULL, NULL, '等级解锁', '基础等级花（无花瓶关联）', 'assets/flower-images/山茶花.webp', false),
  ('岚岫紫云英', '岚岫紫云英', '花灵', '[{"detail": "花灵", "channel": "花灵"}]', NULL, 23, '月令币', 3999.0, NULL, '竹韵花影', 'assets/flower-images/岚岫紫云英.webp', false),
  ('岚紫酒杯花', '岚紫酒杯花', '礼包花圃', '[{"detail": "", "channel": "礼包花圃"}]', NULL, 23, NULL, NULL, NULL, NULL, 'assets/flower-images/岚紫酒杯花.webp', true),
  ('巧克力秋英', '巧克力秋英', '等级花', '[{"detail": "等级花", "channel": "等级花"}]', NULL, 9, NULL, NULL, '等级解锁', '基础等级花（无花瓶关联）', 'assets/flower-images/巧克力秋英.webp', false),
  ('巧月·星眸应水', '巧月·星眸应水', '花灵', '[{"detail": "花灵", "channel": "花灵"}]', NULL, 28, '月令币', 3999.0, NULL, '翠金留芳', 'assets/flower-images/巧月·星眸应水.webp', false),
  ('幻紫铁线莲', '幻紫铁线莲', '礼包花圃', '[{"detail": "礼包花圃", "channel": "礼包花圃"}]', NULL, 23, '元', 28.0, NULL, '锦扇花容', 'assets/flower-images/幻紫铁线莲.webp', false),
  ('幽蓝绿绒蒿', '幽蓝绿绒蒿', '花坊', '[{"detail": "花坊", "channel": "花坊"}]', NULL, 21, '花坊币', 4880.0, '130', '绿意翠瓶', 'assets/flower-images/幽蓝绿绒蒿.webp', false),
  ('幽蓝逐影', '幽蓝逐影', '礼包花圃', '[{"detail": "礼包花圃", "channel": "礼包花圃"}]', NULL, 25, '元', 68.0, NULL, '水舞苍穹', 'assets/flower-images/幽蓝逐影.webp', false),
  ('幽香绮囊', '幽香绮囊', '活动鲜花', '[{"detail": "", "channel": "活动鲜花"}]', NULL, 25, NULL, NULL, NULL, NULL, 'assets/flower-images/幽香绮囊.webp', true),
  ('康乃馨', '康乃馨', '等级花', '[{"detail": "等级花", "channel": "等级花"}]', '01:13:00', 9, NULL, NULL, '等级解锁', '基础等级花（无花瓶关联）', 'assets/flower-images/康乃馨.webp', false),
  ('彤云六初花', '彤云六初花', '礼包花圃', '[{"detail": "礼包花圃", "channel": "礼包花圃"}]', NULL, 23, '元', 28.0, NULL, '枯木逢春', 'assets/flower-images/彤云六初花.webp', false),
  ('彤黄车轴草', '彤黄车轴草', '花坊', '[{"detail": "", "channel": "花坊"}]', NULL, 14, '花坊币', 3880.0, NULL, NULL, 'assets/flower-images/彤黄车轴草.webp', true),
  ('忽地笑', '忽地笑', '花坊', '[{"detail": "花坊", "channel": "花坊"}]', NULL, 14, '花坊币', 1680.0, '90', '紫藤流韵', 'assets/flower-images/忽地笑.webp', false),
  ('恬梦圣铃', '恬梦圣铃', '鲜花礼包', '[{"detail": "鲜花礼包", "channel": "鲜花礼包"}]', NULL, 25, '元', 68.0, NULL, '碧荷灵篮', 'assets/flower-images/恬梦圣铃.webp', false),
  ('悠游云间', '悠游云间', '活动鲜花', '[{"detail": "", "channel": "活动鲜花"}]', NULL, 25, NULL, NULL, '活动获取', '活动专属（无花瓶关联）', 'assets/flower-images/悠游云间.webp', true),
  ('扶摇云鲲', '扶摇云鲲', '花灵商店', '[{"detail": "", "channel": "花灵商店"}]', NULL, 28, NULL, NULL, NULL, NULL, 'assets/flower-images/扶摇云鲲.webp', true),
  ('捣蛋幽幽', '捣蛋幽幽', '鲜花礼包', '[{"detail": "鲜花礼包", "channel": "鲜花礼包"}]', NULL, 25, '元', 68.0, NULL, '水舞苍穹', 'assets/flower-images/捣蛋幽幽.webp', false),
  ('明黄凌霄花', '明黄凌霄花', '礼包花圃', '[{"detail": "礼包花圃", "channel": "礼包花圃"}]', NULL, 23, NULL, NULL, '购齐(暮山耧斗菜 盈粉芍药 朝晖姜荷花)赠送', '金盏生芳', 'assets/flower-images/明黄凌霄花.webp', false),
  ('明黄垂筒花', '明黄垂筒花', '花之密令', '[{"detail": "花之密令", "channel": "花之密令"}]', NULL, 14, NULL, NULL, '密令获取', '金盏生芳', 'assets/flower-images/明黄垂筒花.webp', false),
  ('明黄如意菊', '明黄如意菊', '等级花', '[{"detail": "等级花", "channel": "等级花"}]', '1900/1/1 02:15:00', 9, NULL, NULL, '等级解锁', '基础等级花（无花瓶关联）', 'assets/flower-images/明黄如意菊.webp', false),
  ('明黄松虫草', '明黄松虫草', '花之密令', '[{"detail": "花之密令", "channel": "花之密令"}]', NULL, 23, NULL, NULL, '密令获取', '枝鸣翠羽', 'assets/flower-images/明黄松虫草.webp', false),
  ('明黄矮牵牛', '明黄矮牵牛', '花坊', '[{"detail": "花坊", "channel": "花坊"}]', '13:20:00', 14, '花坊币', 2880.0, NULL, NULL, 'assets/flower-images/明黄矮牵牛.webp', false),
  ('明黄茑萝', '明黄茑萝', '花之密令', '[{"detail": "", "channel": "花之密令"}]', NULL, 14, NULL, NULL, NULL, NULL, 'assets/flower-images/明黄茑萝.webp', true),
  ('明黄跳舞兰', '明黄跳舞兰', '花坊', '[{"detail": "花坊", "channel": "花坊"}]', NULL, 21, '花坊币', 4880.0, '130', '幽蓝瓷瓶', 'assets/flower-images/明黄跳舞兰.webp', false),
  ('星垂绮夜', '星垂绮夜', '活动鲜花', '[{"detail": "", "channel": "活动鲜花"}]', NULL, 28, NULL, NULL, NULL, NULL, 'assets/flower-images/星垂绮夜.webp', true),
  ('星夜奇遇', '星夜奇遇', '活动鲜花', '[{"detail": "(星夜奇遇)", "channel": "活动鲜花"}]', NULL, 28, NULL, NULL, '活动获取', '活动专属（无花瓶关联）', 'assets/flower-images/星夜奇遇.webp', false),
  ('星槎仙舟', '星槎仙舟', '累计充值', '[{"detail": "累计充值", "channel": "累计充值"}]', NULL, 25, NULL, NULL, '充值奖励', '充值奖励（无花瓶关联）', 'assets/flower-images/星槎仙舟.webp', false),
  ('星河映蕊', '星河映蕊', '星河映蕊', '[{"detail": "星河映蕊", "channel": "星河映蕊"}]', NULL, 28, NULL, NULL, '抽取获取', '幽木流芳', 'assets/flower-images/星河映蕊.webp', false),
  ('星泽幽昙', '星泽幽昙', '星辰商店', '[{"detail": "星辰商店", "channel": "星辰商店"}]', NULL, 25, '月令币', 3999.0, NULL, '幽蓝瓷瓶', 'assets/flower-images/星泽幽昙.webp', false),
  ('星璇寰宇', '星璇寰宇', '花灵商店', '[{"detail": "", "channel": "花灵商店"}]', NULL, 30, NULL, NULL, NULL, NULL, 'assets/flower-images/星璇寰宇.webp', true),
  ('星耀灵蕊', '星耀灵蕊', '累计充值', '[{"detail": "累计充值", "channel": "累计充值"}]', NULL, 23, NULL, NULL, '充值奖励', '充值奖励（无花瓶关联）', 'assets/flower-images/星耀灵蕊.webp', false),
  ('星蓝婆婆纳', '星蓝婆婆纳', '花坊', '[{"detail": "", "channel": "花坊"}]', NULL, 14, '花坊币', 3880.0, NULL, NULL, 'assets/flower-images/星蓝婆婆纳.webp', false),
  ('星蓝山月桂', '星蓝山月桂', '花之密令', '[{"detail": "", "channel": "花之密令"}]', NULL, 23, NULL, NULL, NULL, NULL, 'assets/flower-images/星蓝山月桂.webp', true),
  ('星郎垂丝茉莉', '星郎垂丝茉莉', '礼包花圃', '[{"detail": "", "channel": "礼包花圃"}]', NULL, 23, '元', 28.0, NULL, '绮花幻蝶', 'assets/flower-images/星郎垂丝茉莉.webp', true),
  ('星铃萤夜', '星铃萤夜', '鲜花礼包', '[{"detail": "", "channel": "鲜花礼包"}]', NULL, 25, '元', 68.0, NULL, NULL, 'assets/flower-images/星铃萤夜.webp', true),
  ('映粉云光月季', '映粉云光月季', '礼包花圃', '[{"detail": "礼包花圃", "channel": "礼包花圃"}]', NULL, 25, '元', 68.0, NULL, '醉蕊金樽', 'assets/flower-images/映粉云光月季.webp', false),
  ('春晓木香花', '春晓木香花', '礼包花圃', '[{"detail": "礼包花圃", "channel": "礼包花圃"}]', NULL, 23, '元', 28.0, NULL, '月影藤生', 'assets/flower-images/春晓木香花.webp', false),
  ('春绿蕙兰', '春绿蕙兰', '礼包花圃', '[{"detail": "礼包花圃", "channel": "礼包花圃"}]', NULL, 23, NULL, NULL, '购齐(玉玲珑腊梅 霁澜牡丹 黛紫玉兰)赠送', '绿意翠瓶', 'assets/flower-images/春绿蕙兰.webp', false),
  ('晴兰蝶影', '晴兰蝶影', '鲜花礼包', '[{"detail": "", "channel": "鲜花礼包"}]', NULL, 25, '元', 68.0, NULL, NULL, 'assets/flower-images/晴兰蝶影.webp', true),
  ('晴山蔷薇花', '晴山蔷薇花', '礼包花圃', '[{"detail": "礼包花圃", "channel": "礼包花圃"}]', NULL, 23, '元', 28.0, NULL, '浮雕瓷壶', 'assets/flower-images/晴山蔷薇花.webp', false),
  ('晴粉大花芙蓉', '晴粉大花芙蓉', '鲜花礼包', '[{"detail": "", "channel": "鲜花礼包"}]', NULL, 23, '元', 28.0, NULL, NULL, 'assets/flower-images/晴粉大花芙蓉.webp', true),
  ('晴蓝耧斗菜', '晴蓝耧斗菜', '花之密令', '[{"detail": "花之密令", "channel": "花之密令"}]', NULL, 23, NULL, NULL, '密令获取', '醉蕊金樽', 'assets/flower-images/晴蓝耧斗菜.webp', false),
  ('晴蓝鸭跖草', '晴蓝鸭跖草', '活动鲜花', '[{"detail": "", "channel": "活动鲜花"}]', NULL, 14, NULL, NULL, NULL, NULL, 'assets/flower-images/晴蓝鸭跖草.webp', true),
  ('晴黄金鱼草', '晴黄金鱼草', '鲜花礼包', '[{"detail": "", "channel": "鲜花礼包"}]', NULL, 23, '元', 28.0, NULL, NULL, 'assets/flower-images/晴黄金鱼草.webp', true),
  ('暖橙兜兰', '暖橙兜兰', '活动鲜花', '[{"detail": "", "channel": "活动鲜花"}]', NULL, 14, NULL, NULL, NULL, NULL, 'assets/flower-images/暖橙兜兰.webp', true),
  ('暖橙旱金莲', '暖橙旱金莲', '花灵', '[{"detail": "", "channel": "花灵"}]', NULL, 23, NULL, NULL, NULL, NULL, 'assets/flower-images/暖橙旱金莲.webp', true),
  ('暖橙球根海棠', '暖橙球根海棠', '礼包花圃', '[{"detail": "", "channel": "礼包花圃"}]', NULL, 23, NULL, NULL, NULL, NULL, 'assets/flower-images/暖橙球根海棠.webp', true),
  ('暖阳金丝桃', '暖阳金丝桃', '花灵', '[{"detail": "", "channel": "花灵"}]', NULL, 23, '月令币', 3999.0, NULL, '金盏生芳', 'assets/flower-images/暖阳金丝桃.webp', true),
  ('暮山耧斗菜', '暮山耧斗菜', '礼包花圃', '[{"detail": "礼包花圃", "channel": "礼包花圃"}]', NULL, 23, '元', 28.0, NULL, '醉蕊金樽', 'assets/flower-images/暮山耧斗菜.webp', false),
  ('暮粉紫藤花', '暮粉紫藤花', '礼包花圃', '[{"detail": "礼包花圃", "channel": "礼包花圃"}]', NULL, 23, '元', 28.0, NULL, '镜华锦匣', 'assets/flower-images/暮粉紫藤花.webp', false),
  ('曜绯帝王花', '曜绯帝王花', '礼包花圃', '[{"detail": "", "channel": "礼包花圃"}]', NULL, 25, '元', 68.0, NULL, '幽蓝瓷瓶', 'assets/flower-images/曜绯帝王花.webp', false),
  ('曼珠沙华', '曼珠沙华', '累计充值', '[{"detail": "累计充值", "channel": "累计充值"}]', NULL, 23, NULL, NULL, '充值奖励', '充值奖励（无花瓶关联）', 'assets/flower-images/曼珠沙华.webp', false),
  ('曼陀罗华', '曼陀罗华', '花坊', '[{"detail": "花坊", "channel": "花坊"}]', NULL, 21, '花坊币', 4880.0, '130', '紫藤流韵', 'assets/flower-images/曼陀罗华.webp', false),
  ('月光白彩叶草', '月光白彩叶草', '花之密令', '[{"detail": "", "channel": "花之密令"}]', NULL, 14, NULL, NULL, NULL, NULL, 'assets/flower-images/月光白彩叶草.webp', true),
  ('月影摇光', '月影摇光', '累计充值', '[{"detail": "累计充值", "channel": "累计充值"}]', NULL, 23, NULL, NULL, '充值奖励', '充值奖励（无花瓶关联）', 'assets/flower-images/月影摇光.webp', false),
  ('月白兔狸藻', '月白兔狸藻', '花之密令', '[{"detail": "花之密令", "channel": "花之密令"}]', NULL, 14, NULL, NULL, '密令获取', '幽蓝瓷瓶', 'assets/flower-images/月白兔狸藻.webp', false),
  ('月白格桑花', '月白格桑花', '花坊', '[{"detail": "花坊", "channel": "花坊"}]', NULL, 14, '花坊币', 2880.0, '95', '幽蓝瓷瓶', 'assets/flower-images/月白格桑花.webp', false),
  ('月白舞花姜', '月白舞花姜', '鲜花礼包', '[{"detail": "", "channel": "鲜花礼包"}]', NULL, 23, NULL, NULL, NULL, NULL, 'assets/flower-images/月白舞花姜.webp', true),
  ('月白酒杯花', '月白酒杯花', '礼包花圃', '[{"detail": "", "channel": "礼包花圃"}]', NULL, 23, NULL, NULL, NULL, NULL, 'assets/flower-images/月白酒杯花.webp', true),
  ('月蓝乱子草', '月蓝乱子草', 'VIP商店', '[{"detail": "", "channel": "VIP商店"}]', NULL, 14, NULL, NULL, NULL, NULL, 'assets/flower-images/月蓝乱子草.webp', true),
  ('有龙则灵', '有龙则灵', '活动鲜花', '[{"detail": "(云深见龙)", "channel": "活动鲜花"}]', NULL, 30, NULL, NULL, '活动获取', '活动专属（无花瓶关联）', 'assets/flower-images/有龙则灵.webp', false),
  ('朝晖姜荷花', '朝晖姜荷花', '礼包花圃', '[{"detail": "礼包花圃", "channel": "礼包花圃"}]', NULL, 23, '元', 28.0, NULL, '金盏生芳', 'assets/flower-images/朝晖姜荷花.webp', false),
  ('朱柿长寿花', '朱柿长寿花', '花坊', '[{"detail": "花坊", "channel": "花坊"}]', NULL, 21, '花坊币', 5880.0, '145', '雪梅迎春', 'assets/flower-images/朱柿长寿花.webp', false),
  ('朱橙魔杖花', '朱橙魔杖花', '活动鲜花', '[{"detail": "(星夜奇遇)", "channel": "活动鲜花"}]', NULL, 14, NULL, NULL, '活动获取', '活动专属（无花瓶关联）', 'assets/flower-images/朱橙魔杖花.webp', false),
  ('朱砂丹桂', '朱砂丹桂', '花坊', '[{"detail": "花坊", "channel": "花坊"}]', NULL, 21, '花坊币', 5880.0, '145', '流波花樽', 'assets/flower-images/朱砂丹桂.webp', false),
  ('朱红凌霄花', '朱红凌霄花', '礼包花圃', '[{"detail": "礼包花圃", "channel": "礼包花圃"}]', NULL, 23, NULL, NULL, '购齐(珠匣橘芙蓉 暮粉紫藤花 桃绯姜荷花)赠送', '金盏生芳', 'assets/flower-images/朱红凌霄花.webp', false),
  ('朱红茑萝', '朱红茑萝', 'VIP商店', '[{"detail": "", "channel": "VIP商店"}]', NULL, 14, NULL, NULL, NULL, NULL, 'assets/flower-images/朱红茑萝.webp', true),
  ('朱绡大花芙蓉', '朱绡大花芙蓉', '鲜花礼包', '[{"detail": "", "channel": "鲜花礼包"}]', NULL, 23, '元', 28.0, NULL, NULL, 'assets/flower-images/朱绡大花芙蓉.webp', true),
  ('杏坛启学', '杏坛启学', '活动鲜花', '[{"detail": "", "channel": "活动鲜花"}]', NULL, 25, NULL, NULL, NULL, NULL, 'assets/flower-images/杏坛启学.webp', true),
  ('杏月·花影雅憩', '杏月·花影雅憩', '花灵', '[{"detail": "花灵", "channel": "花灵"}]', NULL, 28, '月令币', 3999.0, NULL, '月影藤生', 'assets/flower-images/杏月·花影雅憩.webp', false),
  ('杏白忘忧草', '杏白忘忧草', '花坊', '[{"detail": "花坊", "channel": "花坊"}]', NULL, 14, '花坊币', 3880.0, NULL, NULL, 'assets/flower-images/杏白忘忧草.webp', false),
  ('杏粉针垫花', '杏粉针垫花', '花坊', '[{"detail": "", "channel": "花坊"}]', NULL, 14, '花坊币', 3880.0, NULL, NULL, 'assets/flower-images/杏粉针垫花.webp', true),
  ('杏绯德鸢', '杏绯德鸢', '礼包花圃', '[{"detail": "礼包花圃", "channel": "礼包花圃"}]', NULL, 23, '元', 28.0, NULL, '幽木流芳', 'assets/flower-images/杏绯德鸢.webp', false),
  ('杏色春衫', '杏色春衫', '礼包花圃', '[{"detail": "礼包花圃", "channel": "礼包花圃"}]', NULL, 25, '元', 68.0, NULL, '碧荷灵篮', 'assets/flower-images/杏色春衫.webp', false),
  ('杏黄杜鹃', '杏黄杜鹃', '花坊', '[{"detail": "花坊", "channel": "花坊"}]', NULL, 14, '花坊币', 3880.0, '95', '碧荷灵篮', 'assets/flower-images/杏黄杜鹃.webp', false),
  ('杏黄立金花', '杏黄立金花', '礼包花圃', '[{"detail": "人民币 28元", "channel": "礼包花圃"}]', NULL, 23, '元', 28.0, NULL, NULL, 'assets/flower-images/杏黄立金花.webp', false),
  ('杏黄蕨叶芍药', '杏黄蕨叶芍药', '花坊', '[{"detail": "", "channel": "花坊"}]', NULL, 14, '花坊币', 3880.0, NULL, NULL, 'assets/flower-images/杏黄蕨叶芍药.webp', true),
  ('松绿立金花', '松绿立金花', '礼包花圃', '[{"detail": "礼包花圃", "channel": "礼包花圃"}]', NULL, 23, '元', 28.0, NULL, '枝鸣翠羽', 'assets/flower-images/松绿立金花.webp', false),
  ('染杏贝壳花', '染杏贝壳花', '活动鲜花', '[{"detail": "", "channel": "活动鲜花"}]', NULL, 14, NULL, NULL, '活动获取', '活动专属（无花瓶关联）', 'assets/flower-images/染杏贝壳花.webp', true),
  ('柔白茨菇', '柔白茨菇', '礼包花圃', '[{"detail": "", "channel": "礼包花圃"}]', NULL, 23, '元', 28.0, NULL, '碧荷灵篮', 'assets/flower-images/柔白茨菇.webp', true),
  ('柔粉堇兰', '柔粉堇兰', '鲜花礼包', '[{"detail": "", "channel": "鲜花礼包"}]', NULL, 23, '元', 28.0, NULL, NULL, 'assets/flower-images/柔粉堇兰.webp', true),
  ('柔粉松虫草', '柔粉松虫草', '礼包花圃', '[{"detail": "", "channel": "礼包花圃"}]', NULL, 23, '元', 28.0, NULL, '枝鸣翠羽', 'assets/flower-images/柔粉松虫草.webp', false),
  ('柔粉马利筋', '柔粉马利筋', '花坊', '[{"detail": "", "channel": "花坊"}]', NULL, 14, '花坊币', 3880.0, NULL, NULL, 'assets/flower-images/柔粉马利筋.webp', true),
  ('柔紫石斛兰', '柔紫石斛兰', 'VIP商店', '[{"detail": "VIP商店", "channel": "VIP商店"}]', NULL, 14, NULL, NULL, 'VIP获取', 'VIP专属（无花瓶关联）', 'assets/flower-images/柔紫石斛兰.webp', false),
  ('柔绯金鱼草', '柔绯金鱼草', '鲜花礼包', '[{"detail": "", "channel": "鲜花礼包"}]', NULL, 23, '元', 28.0, NULL, NULL, 'assets/flower-images/柔绯金鱼草.webp', true),
  ('柔蓝小手球', '柔蓝小手球', '活动鲜花', '[{"detail": "", "channel": "活动鲜花"}]', NULL, 14, NULL, NULL, '活动获取', '活动专属（无花瓶关联）', 'assets/flower-images/柔蓝小手球.webp', true),
  ('柔蓝飞燕草', '柔蓝飞燕草', '礼包花圃', '[{"detail": "礼包花圃", "channel": "礼包花圃"}]', NULL, 23, '元', 28.0, NULL, '翠羽芳华', 'assets/flower-images/柔蓝飞燕草.webp', false),
  ('柳月·溪亭燕语', '柳月·溪亭燕语', '花灵', '[{"detail": "花灵", "channel": "花灵"}]', NULL, 28, '月令币', 3999.0, NULL, '绿意翠瓶', 'assets/flower-images/柳月·溪亭燕语.webp', false),
  ('柿柿如意', '柿柿如意', '活动鲜花', '[{"detail": "(八分来财)", "channel": "活动鲜花"}]', NULL, 25, NULL, NULL, '活动获取', '活动专属（无花瓶关联）', 'assets/flower-images/柿柿如意.webp', false),
  ('栀子花', '栀子花', '等级花', '[{"detail": "等级花", "channel": "等级花"}]', '1900/1/1 00:00:00', 9, NULL, NULL, '等级解锁', '基础等级花（无花瓶关联）', 'assets/flower-images/栀子花.webp', false),
  ('栖香含笑花', '栖香含笑花', '花灵', '[{"detail": "", "channel": "花灵"}]', NULL, 23, NULL, NULL, NULL, NULL, 'assets/flower-images/栖香含笑花.webp', true),
  ('桂月·秋千稚语', '桂月·秋千稚语', '花灵', '[{"detail": "花灵", "channel": "花灵"}]', NULL, 28, '月令币', 3999.0, NULL, '竹韵花影', 'assets/flower-images/桂月·秋千稚语.webp', false),
  ('桃云木香花', '桃云木香花', '礼包花圃', '[{"detail": "礼包花圃", "channel": "礼包花圃"}]', NULL, 23, NULL, NULL, '购齐(珠匣粉芙蓉 春晓木香花 粉羽朱顶红)赠送', '月影藤生', 'assets/flower-images/桃云木香花.webp', false),
  ('桃华驻颜', '桃华驻颜', '活动鲜花', '[{"detail": "", "channel": "活动鲜花"}]', NULL, 5, NULL, NULL, NULL, NULL, 'assets/flower-images/桃华驻颜.webp', true),
  ('桃夭杰奎琳', '桃夭杰奎琳', 'VIP商店', '[{"detail": "VIP商店", "channel": "VIP商店"}]', NULL, 14, NULL, NULL, 'VIP获取', 'VIP专属（无花瓶关联）', 'assets/flower-images/桃夭杰奎琳.webp', false),
  ('桃夭美人蕉', '桃夭美人蕉', '花灵', '[{"detail": "花灵", "channel": "花灵"}]', NULL, 23, '月令币', 3999.0, NULL, '翠羽芳华', 'assets/flower-images/桃夭美人蕉.webp', false),
  ('桃夭飞燕草', '桃夭飞燕草', '礼包花圃', '[{"detail": "礼包花圃", "channel": "礼包花圃"}]', NULL, 23, '元', 28.0, NULL, '翠羽芳华', 'assets/flower-images/桃夭飞燕草.webp', false),
  ('桃影浮澜', '桃影浮澜', '礼包花圃', '[{"detail": "礼包花圃", "channel": "礼包花圃"}]', NULL, 25, '元', 68.0, NULL, '水舞苍穹', 'assets/flower-images/桃影浮澜.webp', false),
  ('桃月·云汐灼华', '桃月·云汐灼华', '花灵', '[{"detail": "", "channel": "花灵"}]', NULL, 28, '月令币', 3999.0, NULL, '锦扇花容', 'assets/flower-images/桃月·云汐灼华.webp', true),
  ('桃李承辉', '桃李承辉', '活动鲜花', '[{"detail": "", "channel": "活动鲜花"}]', NULL, 25, NULL, NULL, NULL, NULL, 'assets/flower-images/桃李承辉.webp', true),
  ('桃汐酒杯花', '桃汐酒杯花', '礼包花圃', '[{"detail": "", "channel": "礼包花圃"}]', NULL, 23, NULL, NULL, NULL, NULL, 'assets/flower-images/桃汐酒杯花.webp', true),
  ('桃粉四照花', '桃粉四照花', '活动鲜花', '[{"detail": "", "channel": "活动鲜花"}]', NULL, 14, NULL, NULL, NULL, NULL, 'assets/flower-images/桃粉四照花.webp', true),
  ('桃粉报春花', '桃粉报春花', '花坊', '[{"detail": "花坊", "channel": "花坊"}]', NULL, 14, '花坊币', 3880.0, NULL, '枯木逢春', 'assets/flower-images/桃粉报春花.webp', false),
  ('桃粉蕨叶芍药', '桃粉蕨叶芍药', '花坊', '[{"detail": "", "channel": "花坊"}]', NULL, 14, '花坊币', 3880.0, NULL, NULL, 'assets/flower-images/桃粉蕨叶芍药.webp', true),
  ('桃粉谷鸢尾', '桃粉谷鸢尾', '花坊', '[{"detail": "", "channel": "花坊"}]', NULL, 14, NULL, NULL, '活动获取', '活动专属（无花瓶关联）', 'assets/flower-images/桃粉谷鸢尾.webp', false),
  ('桃绯姜荷花', '桃绯姜荷花', '礼包花圃', '[{"detail": "礼包花圃", "channel": "礼包花圃"}]', NULL, 23, '元', 28.0, NULL, '金盏生芳', 'assets/flower-images/桃绯姜荷花.webp', false),
  ('桃鳞乱子草', '桃鳞乱子草', '活动鲜花', '[{"detail": "", "channel": "活动鲜花"}]', NULL, 14, NULL, NULL, NULL, NULL, 'assets/flower-images/桃鳞乱子草.webp', true),
  ('梅月·疏影听弦', '梅月·疏影听弦', '花灵', '[{"detail": "花灵", "channel": "花灵"}]', NULL, 28, '月令币', 3999.0, NULL, '幽蓝瓷瓶', 'assets/flower-images/梅月·疏影听弦.webp', false),
  ('梦幻之心', '梦幻之心', '活动鲜花', '[{"detail": "(心联盟)", "channel": "活动鲜花"}]', NULL, 28, NULL, NULL, '活动获取', '活动专属（无花瓶关联）', 'assets/flower-images/梦幻之心.webp', false),
  ('梦紫郁金香', '梦紫郁金香', '活动鲜花', '[{"detail": "(为紫打call)", "channel": "活动鲜花"}]', NULL, 23, NULL, NULL, '活动获取', '紫藤流韵', 'assets/flower-images/梦紫郁金香.webp', false),
  ('梦蓝香豌豆', '梦蓝香豌豆', '花之密令', '[{"detail": "花之密令", "channel": "花之密令"}]', NULL, 14, NULL, NULL, '密令获取', '紫藤流韵', 'assets/flower-images/梦蓝香豌豆.webp', false),
  ('梦蝶花章', '梦蝶花章', '礼包花圃', '[{"detail": "", "channel": "礼包花圃"}]', NULL, 25, '元', 68.0, NULL, '锦扇花容', 'assets/flower-images/梦蝶花章.webp', false),
  ('棉花小熊', '棉花小熊', '累计充值', '[{"detail": "累计充值", "channel": "累计充值"}]', NULL, 23, NULL, NULL, '充值奖励', '充值奖励（无花瓶关联）', 'assets/flower-images/棉花小熊.webp', false),
  ('榴月·绛花照影', '榴月·绛花照影', '花灵', '[{"detail": "", "channel": "花灵"}]', NULL, 28, '月令币', 3999.0, NULL, '翠羽芳华', 'assets/flower-images/榴月·绛花照影.webp', true),
  ('槐月·蝶梦轻语', '槐月·蝶梦轻语', '花灵', '[{"detail": "", "channel": "花灵"}]', NULL, 28, '月令币', 3999.0, NULL, '枝鸣翠羽', 'assets/flower-images/槐月·蝶梦轻语.webp', true),
  ('樱红跳舞兰', '樱红跳舞兰', '礼包花圃', '[{"detail": "礼包花圃", "channel": "礼包花圃"}]', NULL, 23, '元', 28.0, NULL, '幽蓝瓷瓶', 'assets/flower-images/樱红跳舞兰.webp', false),
  ('橘光朱顶红', '橘光朱顶红', '礼包花圃', '[{"detail": "礼包花圃", "channel": "礼包花圃"}]', NULL, 23, '元', 28.0, NULL, '月影藤生', 'assets/flower-images/橘光朱顶红.webp', false),
  ('橘焰冠华', '橘焰冠华', '花灵', '[{"detail": "花灵", "channel": "花灵"}]', NULL, 23, '月令币', 3999.0, NULL, '翠金留芳', 'assets/flower-images/橘焰冠华.webp', false),
  ('橘粉忘忧草', '橘粉忘忧草', '活动鲜花', '[{"detail": "(云深见龙)", "channel": "活动鲜花"}]', NULL, 14, NULL, NULL, '活动获取', '活动专属（无花瓶关联）', 'assets/flower-images/橘粉忘忧草.webp', false),
  ('橘红垂筒花', '橘红垂筒花', 'VIP商店', '[{"detail": "VIP商店", "channel": "VIP商店"}]', NULL, 14, NULL, NULL, 'VIP获取', 'VIP专属（无花瓶关联）', 'assets/flower-images/橘红垂筒花.webp', false),
  ('橘红海棠花', '橘红海棠花', '花坊', '[{"detail": "花坊", "channel": "花坊"}]', NULL, 14, '花坊币', 3880.0, '99', '翠金留芳', 'assets/flower-images/橘红海棠花.webp', false),
  ('橘霞华珊', '橘霞华珊', '花坊', '[{"detail": "花坊", "channel": "花坊"}]', NULL, 21, '花坊币', 5880.0, '145', '水舞苍穹', 'assets/flower-images/橘霞华珊.webp', false),
  ('橙光拂晓月季', '橙光拂晓月季', '礼包花圃', '[{"detail": "", "channel": "礼包花圃"}]', NULL, 25, '元', 68.0, NULL, '醉蕊金樽', 'assets/flower-images/橙光拂晓月季.webp', false),
  ('橙心剑兰', '橙心剑兰', '礼包花圃', '[{"detail": "礼包花圃", "channel": "礼包花圃"}]', NULL, 23, NULL, NULL, '购齐(杏色春衫 瑶光牡丹 粉菲铁筷花)赠送', '浮雕瓷壶', 'assets/flower-images/橙心剑兰.webp', false),
  ('橙星花福禄考', '橙星花福禄考', '礼包花圃', '[{"detail": "", "channel": "礼包花圃"}]', NULL, 23, '元', 28.0, NULL, '锦扇花容', 'assets/flower-images/橙星花福禄考.webp', true),
  ('橙霞洋金凤', '橙霞洋金凤', '花灵', '[{"detail": "", "channel": "花灵"}]', NULL, 23, '月令币', 3999.0, NULL, '云腾绕梦', 'assets/flower-images/橙霞洋金凤.webp', true),
  ('橙霞花毛茛', '橙霞花毛茛', '礼包花圃', '[{"detail": "礼包花圃", "channel": "礼包花圃"}]', NULL, 23, '元', 28.0, NULL, '月影藤生', 'assets/flower-images/橙霞花毛茛.webp', false),
  ('橙黄君子兰', '橙黄君子兰', '活动鲜花', '[{"detail": "(迎春接福)", "channel": "活动鲜花"}]', NULL, 14, NULL, NULL, '活动获取', '活动专属（无花瓶关联）', 'assets/flower-images/橙黄君子兰.webp', false),
  ('橙黄虞美人', '橙黄虞美人', '礼包花圃', '[{"detail": "礼包花圃", "channel": "礼包花圃"}]', NULL, 23, '元', 28.0, NULL, '竹韵花影', 'assets/flower-images/橙黄虞美人.webp', false),
  ('橙黄酢浆草', '橙黄酢浆草', '花坊', '[{"detail": "", "channel": "花坊"}]', NULL, 14, '花坊币', 3880.0, NULL, NULL, 'assets/flower-images/橙黄酢浆草.webp', false),
  ('橙黄醡浆草', '橙黄醡浆草', '花坊', '[{"detail": "", "channel": "花坊"}]', NULL, 14, NULL, NULL, '活动获取', '活动专属（无花瓶关联）', 'assets/flower-images/橙黄醡浆草.webp', true),
  ('欢云妙舞', '欢云妙舞', '活动鲜花', '[{"detail": "国色芳华 （第三期）", "channel": "活动鲜花"}]', NULL, 28, NULL, NULL, '活动获取', '活动专属（无花瓶关联）', 'assets/flower-images/欢云妙舞.webp', false),
  ('欢闹南瓜', '欢闹南瓜', '活动鲜花', '[{"detail": "(星夜奇遇)", "channel": "活动鲜花"}]', NULL, 25, NULL, NULL, '活动获取', '活动专属（无花瓶关联）', 'assets/flower-images/欢闹南瓜.webp', false),
  ('欢雪颂冬', '欢雪颂冬', '活动鲜花', '[{"detail": "(欢雪颂冬)", "channel": "活动鲜花"}]', NULL, 28, NULL, NULL, '活动获取', '活动专属（无花瓶关联）', 'assets/flower-images/欢雪颂冬.webp', false),
  ('正红大丽花', '正红大丽花', '星河映蕊', '[{"detail": "星河映蕊", "channel": "星河映蕊"}]', NULL, 14, NULL, NULL, '抽取获取', '幽蓝瓷瓶', 'assets/flower-images/正红大丽花.webp', false),
  ('殷红灯笼花', '殷红灯笼花', '花坊', '[{"detail": "花坊", "channel": "花坊"}]', NULL, 14, '花坊币', 3880.0, '99', '翠羽芳华', 'assets/flower-images/殷红灯笼花.webp', false),
  ('殷红马利筋', '殷红马利筋', '花坊', '[{"detail": "", "channel": "花坊"}]', NULL, 14, '花坊币', 3880.0, NULL, NULL, 'assets/flower-images/殷红马利筋.webp', true),
  ('毓秀兰结', '毓秀兰结', '活动鲜花', '[{"detail": "", "channel": "活动鲜花"}]', NULL, 25, NULL, NULL, NULL, NULL, '', true),
  ('比翼双飞', '比翼双飞', '活动鲜花', '[{"detail": "", "channel": "活动鲜花"}]', NULL, 25, NULL, NULL, NULL, NULL, 'assets/flower-images/比翼双飞.webp', true),
  ('毛蕊紫银莲', '毛蕊紫银莲', '花坊', '[{"detail": "花坊", "channel": "花坊"}]', NULL, 21, '花坊币', 5880.0, '145', '翠金留芳', 'assets/flower-images/毛蕊紫银莲.webp', false),
  ('水仙花', '水仙花', '等级花', '[{"detail": "等级花", "channel": "等级花"}]', '15:20:00', 9, NULL, NULL, '等级解锁', '基础等级花（无花瓶关联）', 'assets/flower-images/水仙花.webp', false),
  ('水红落新妇', '水红落新妇', '花坊', '[{"detail": "花坊", "channel": "花坊"}]', NULL, 14, '花坊币', 880.0, '90', '紫藤流韵', 'assets/flower-images/水红落新妇.webp', false),
  ('水蓝球根海棠', '水蓝球根海棠', '花坊', '[{"detail": "", "channel": "花坊"}]', NULL, 21, '花坊币', 5880.0, NULL, NULL, 'assets/flower-images/水蓝球根海棠.webp', true),
  ('汀蓝兔狸藻', '汀蓝兔狸藻', '花坊', '[{"detail": "", "channel": "花坊"}]', NULL, 14, NULL, NULL, '活动获取', '活动专属（无花瓶关联）', 'assets/flower-images/汀蓝兔狸藻.webp', false),
  ('沐光映黄月季', '沐光映黄月季', '礼包花圃', '[{"detail": "礼包花圃", "channel": "礼包花圃"}]', NULL, 25, '元', 68.0, NULL, '醉蕊金樽', 'assets/flower-images/沐光映黄月季.webp', false),
  ('波叶金桂', '波叶金桂', '花坊', '[{"detail": "花坊", "channel": "花坊"}]', NULL, 21, '花坊币', 5880.0, '145', '流波花樽', 'assets/flower-images/波叶金桂.webp', false),
  ('泼墨', '泼墨', '活动鲜花', '[{"detail": "", "channel": "活动鲜花"}]', NULL, 23, NULL, NULL, '活动获取', '丹青瓷瓶', 'assets/flower-images/泼墨.webp', true),
  ('浅杏片栗花', '浅杏片栗花', '星河映蕊', '[{"detail": "", "channel": "星河映蕊"}]', NULL, 21, NULL, NULL, NULL, NULL, 'assets/flower-images/浅杏片栗花.webp', true),
  ('浅橘乒乓菊', '浅橘乒乓菊', '花坊', '[{"detail": "花坊", "channel": "花坊"}]', '15:20:00', 14, '花坊币', 2880.0, NULL, NULL, 'assets/flower-images/浅橘乒乓菊.webp', false),
  ('浅橘如意菊', '浅橘如意菊', '等级花', '[{"detail": "等级花", "channel": "等级花"}]', '1900/1/1 00:40:00', 9, NULL, NULL, '等级解锁', '基础等级花（无花瓶关联）', 'assets/flower-images/浅橘如意菊.webp', false),
  ('浅汐蓝蝴蝶', '浅汐蓝蝴蝶', '花灵', '[{"detail": "", "channel": "花灵"}]', NULL, 23, NULL, NULL, NULL, NULL, 'assets/flower-images/浅汐蓝蝴蝶.webp', true),
  ('浅白乒乓菊', '浅白乒乓菊', '花坊', '[{"detail": "花坊", "channel": "花坊"}]', '20:40:00', 14, '花坊币', 2880.0, NULL, NULL, 'assets/flower-images/浅白乒乓菊.webp', false),
  ('浅粉乒乓菊', '浅粉乒乓菊', '花坊', '[{"detail": "花坊", "channel": "花坊"}]', '15:20:00', 14, '花坊币', 2880.0, NULL, NULL, 'assets/flower-images/浅粉乒乓菊.webp', false),
  ('浅粉仙客来', '浅粉仙客来', '花坊', '[{"detail": "花坊币 3880", "channel": "花坊"}]', NULL, 14, '花坊币', 3880.0, NULL, NULL, 'assets/flower-images/浅粉仙客来.webp', false),
  ('浅粉凤仙花', '浅粉凤仙花', '活动鲜花', '[{"detail": "", "channel": "活动鲜花"}]', NULL, 14, NULL, NULL, NULL, NULL, 'assets/flower-images/浅粉凤仙花.webp', true),
  ('浅粉夹竹桃', '浅粉夹竹桃', '花坊', '[{"detail": "花坊", "channel": "花坊"}]', NULL, 14, '花坊币', 3880.0, '99', '流波花樽', 'assets/flower-images/浅粉夹竹桃.webp', false),
  ('浅粉婆婆纳', '浅粉婆婆纳', 'VIP商店', '[{"detail": "VIP商店", "channel": "VIP商店"}]', NULL, 14, NULL, NULL, 'VIP获取', 'VIP专属（无花瓶关联）', 'assets/flower-images/浅粉婆婆纳.webp', false),
  ('浅粉洋桔梗', '浅粉洋桔梗', '等级花', '[{"detail": "等级花", "channel": "等级花"}]', '1900/1/1 04:00:00', 9, NULL, NULL, '等级解锁', '基础等级花（无花瓶关联）', 'assets/flower-images/浅粉洋桔梗.webp', false),
  ('浅紫晚香玉', '浅紫晚香玉', '等级花', '[{"detail": "等级花", "channel": "等级花"}]', NULL, 9, NULL, NULL, '等级解锁', '基础等级花（无花瓶关联）', 'assets/flower-images/浅紫晚香玉.webp', false),
  ('浅紫落新妇', '浅紫落新妇', '花坊', '[{"detail": "花坊", "channel": "花坊"}]', NULL, 14, '花坊币', 880.0, '90', '紫藤流韵', 'assets/flower-images/浅紫落新妇.webp', false),
  ('浅绀紫藤花', '浅绀紫藤花', '花之密令', '[{"detail": "花之密令", "channel": "花之密令"}]', NULL, 23, NULL, NULL, '密令获取', '镜华锦匣', 'assets/flower-images/浅绀紫藤花.webp', false),
  ('浅绯茨菇', '浅绯茨菇', '礼包花圃', '[{"detail": "", "channel": "礼包花圃"}]', NULL, 23, '元', 28.0, NULL, '碧荷灵篮', 'assets/flower-images/浅绯茨菇.webp', true),
  ('浅蓝仙客来', '浅蓝仙客来', '花坊', '[{"detail": "花坊", "channel": "花坊"}]', NULL, 14, '花坊币', 3880.0, NULL, NULL, 'assets/flower-images/浅蓝仙客来.webp', false),
  ('浅蓝落新妇', '浅蓝落新妇', '花坊', '[{"detail": "花坊", "channel": "花坊"}]', NULL, 14, '花坊币', 880.0, '90', '紫藤流韵', 'assets/flower-images/浅蓝落新妇.webp', false),
  ('浅韵美女樱', '浅韵美女樱', '礼包花圃', '[{"detail": "礼包花圃", "channel": "礼包花圃"}]', NULL, 23, '元', 28.0, NULL, '锦扇花容', 'assets/flower-images/浅韵美女樱.webp', false),
  ('浅黄沙漠玫', '浅黄沙漠玫', '活动鲜花', '[{"detail": "", "channel": "活动鲜花"}]', NULL, 14, NULL, NULL, '活动获取', '活动专属（无花瓶关联）', 'assets/flower-images/浅黄沙漠玫.webp', true),
  ('浅黄绿绒蒿', '浅黄绿绒蒿', '花坊', '[{"detail": "花坊", "channel": "花坊"}]', NULL, 21, '花坊币', 4880.0, '130', '绿意翠瓶', 'assets/flower-images/浅黄绿绒蒿.webp', false),
  ('海蓝蓝铃花', '海蓝蓝铃花', '活动鲜花', '[{"detail": "", "channel": "活动鲜花"}]', NULL, 14, NULL, NULL, NULL, NULL, 'assets/flower-images/海蓝蓝铃花.webp', true),
  ('淡粉如意菊', '淡粉如意菊', '等级花', '[{"detail": "等级花", "channel": "等级花"}]', '1900/1/1 00:40:00', 9, NULL, NULL, '等级解锁', '基础等级花（无花瓶关联）', 'assets/flower-images/淡粉如意菊.webp', false),
  ('淡粉矮牵牛', '淡粉矮牵牛', '花坊', '[{"detail": "花坊", "channel": "花坊"}]', '10:00:00', 14, '花坊币', 2880.0, NULL, NULL, 'assets/flower-images/淡粉矮牵牛.webp', false),
  ('淡粉雪柳', '淡粉雪柳', '礼包花圃', '[{"detail": "礼包花圃", "channel": "礼包花圃"}]', NULL, 23, NULL, NULL, '购齐(红香妃腊梅 浅韵美女樱 杏绯德鸢)赠送', '绿意翠瓶', 'assets/flower-images/淡粉雪柳.webp', false),
  ('淡粉非洲堇', '淡粉非洲堇', '花坊', '[{"detail": "花坊", "channel": "花坊"}]', NULL, 14, '花坊币', 3880.0, '99', '月影藤生', 'assets/flower-images/淡粉非洲堇.webp', false),
  ('淡粉马齿苋', '淡粉马齿苋', '活动鲜花', '[{"detail": "国色芳华 （第三期）", "channel": "活动鲜花"}]', NULL, 14, NULL, NULL, '活动获取', '活动专属（无花瓶关联）', 'assets/flower-images/淡粉马齿苋.webp', false),
  ('淡紫仙客来', '淡紫仙客来', '花坊', '[{"detail": "花坊", "channel": "花坊"}]', NULL, 14, '花坊币', 3880.0, NULL, NULL, 'assets/flower-images/淡紫仙客来.webp', false),
  ('淡紫凤仙花', '淡紫凤仙花', '活动鲜花', '[{"detail": "", "channel": "活动鲜花"}]', NULL, 14, NULL, NULL, NULL, NULL, 'assets/flower-images/淡紫凤仙花.webp', true),
  ('淡紫菊苣', '淡紫菊苣', '等级花', '[{"detail": "等级花", "channel": "等级花"}]', NULL, 9, NULL, NULL, '等级解锁', '基础等级花（无花瓶关联）', 'assets/flower-images/淡紫菊苣.webp', false),
  ('淡绯花烟草', '淡绯花烟草', 'VIP商店', '[{"detail": "", "channel": "VIP商店"}]', NULL, 14, NULL, NULL, 'VIP获取', 'VIP专属（无花瓶关联）', 'assets/flower-images/淡绯花烟草.webp', true),
  ('淡茜蜀葵花', '淡茜蜀葵花', '花坊', '[{"detail": "花坊", "channel": "花坊"}]', NULL, 14, '花坊币', 880.0, '90', '翠羽芳华', 'assets/flower-images/淡茜蜀葵花.webp', false),
  ('淡黄三角梅', '淡黄三角梅', '等级花', '[{"detail": "等级花", "channel": "等级花"}]', '1900/1/1 07:20:00', 9, NULL, NULL, '等级解锁', '基础等级花（无花瓶关联）', 'assets/flower-images/淡黄三角梅.webp', false),
  ('清栀玉露', '清栀玉露', '鲜花礼包', '[{"detail": "", "channel": "鲜花礼包"}]', NULL, 25, '元', 68.0, NULL, NULL, '', true),
  ('漱玉雪莲', '漱玉雪莲', '星辰商店', '[{"detail": "星辰商店", "channel": "星辰商店"}]', NULL, 25, '月令币', 3999.0, NULL, '碧荷灵篮', 'assets/flower-images/漱玉雪莲.webp', false),
  ('橙蓝龙面花', '澄蓝龙面花', '礼包花圃', '[{"detail": "", "channel": "礼包花圃"}]', NULL, 23, NULL, NULL, NULL, NULL, 'assets/flower-images/澄蓝龙面花.webp', false),
  ('火焰针垫花', '火焰针垫花', '花坊', '[{"detail": "花坊", "channel": "花坊"}]', NULL, 14, '花坊币', 3880.0, NULL, NULL, 'assets/flower-images/火焰针垫花.webp', false),
  ('火耀金丹', '火耀金丹', '活动鲜花', '[{"detail": "国色芳华 （第一期）", "channel": "活动鲜花"}]', NULL, 25, NULL, NULL, '活动获取', '活动专属（无花瓶关联）', 'assets/flower-images/火耀金丹.webp', false),
  ('火蕊朱顶红', '火蕊朱顶红', '礼包花圃', '[{"detail": "礼包花圃", "channel": "礼包花圃"}]', NULL, 23, '元', 28.0, NULL, '月影藤生', 'assets/flower-images/火蕊朱顶红.webp', false),
  ('灵松照夜', '灵松照夜', '花灵商店', '[{"detail": "花灵商店", "channel": "花灵商店"}]', NULL, 25, '月令币', 3999.0, NULL, '翠羽芳华', 'assets/flower-images/灵松照夜.webp', false),
  ('灵瑞仙桃', '灵瑞仙桃', '活动鲜花', '[{"detail": "(八分来财)", "channel": "活动鲜花"}]', NULL, 25, NULL, NULL, '活动获取', '活动专属（无花瓶关联）', 'assets/flower-images/灵瑞仙桃.webp', false),
  ('灿若繁星', '灿若繁星', '活动鲜花', '[{"detail": "", "channel": "活动鲜花"}]', NULL, 25, NULL, NULL, NULL, NULL, 'assets/flower-images/灿若繁星.webp', true),
  ('烟粉格桑花', '烟粉格桑花', '礼包花圃', '[{"detail": "礼包花圃", "channel": "礼包花圃"}]', NULL, 23, NULL, NULL, '购齐(幽蓝逐影 甜橙美女樱 桃夭飞燕草)赠送', '幽蓝瓷瓶', 'assets/flower-images/烟粉格桑花.webp', false),
  ('烟紫瑞香花', '烟紫瑞香花', '礼包花圃', '[{"detail": "人民币 购齐赠送", "channel": "礼包花圃"}]', NULL, 23, NULL, NULL, '购齐赠送', NULL, 'assets/flower-images/烟紫瑞香花.webp', false),
  ('烟紫花烟草', '烟紫花烟草', '活动鲜花', '[{"detail": "", "channel": "活动鲜花"}]', NULL, 14, NULL, NULL, '活动获取', '活动专属（无花瓶关联）', 'assets/flower-images/烟紫花烟草.webp', true),
  ('焰火迎春', '焰火迎春', '活动鲜花', '[{"detail": "(迎春接福)", "channel": "活动鲜花"}]', NULL, 30, NULL, NULL, '活动获取', '活动专属（无花瓶关联）', 'assets/flower-images/焰火迎春.webp', false),
  ('焰红嘉兰', '焰红嘉兰', '礼包花圃', '[{"detail": "", "channel": "礼包花圃"}]', NULL, 23, '元', 28.0, NULL, '翠羽芳华', 'assets/flower-images/焰红嘉兰.webp', false),
  ('焰绯海葵', '焰绯海葵', '花坊', '[{"detail": "花坊", "channel": "花坊"}]', NULL, 21, '花坊币', 5880.0, '145', '水舞苍穹', 'assets/flower-images/焰绯海葵.webp', false),
  ('熏紫松虫草', '熏紫松虫草', '礼包花圃', '[{"detail": "", "channel": "礼包花圃"}]', NULL, 23, '元', 28.0, NULL, '枝鸣翠羽', 'assets/flower-images/熏紫松虫草.webp', false),
  ('玉兔揽辉', '玉兔揽辉', '活动鲜花', '[{"detail": "(花好月圆)", "channel": "活动鲜花"}]', NULL, 25, NULL, NULL, '活动获取', '活动专属（无花瓶关联）', 'assets/flower-images/玉兔揽辉.webp', false),
  ('玉兰栖香', '玉兰栖香', '活动鲜花', '[{"detail": "(花漾春山)", "channel": "活动鲜花"}]', NULL, 25, '元', 68.0, NULL, '活动专属（无花瓶关联）', 'assets/flower-images/玉兰栖香.webp', false),
  ('玉晶蓝花楹', '玉晶蓝花楹', '星河映蕊', '[{"detail": "", "channel": "星河映蕊"}]', NULL, 25, NULL, NULL, NULL, NULL, 'assets/flower-images/玉晶蓝花楹.webp', true),
  ('玉玲珑腊梅', '玉玲珑腊梅', '礼包花圃', '[{"detail": "礼包花圃", "channel": "礼包花圃"}]', NULL, 25, '元', 68.0, NULL, '雪梅迎春', 'assets/flower-images/玉玲珑腊梅.webp', false),
  ('玉白梨花', '玉白梨花', '活动鲜花', '[{"detail": "(花漾春山)", "channel": "活动鲜花"}]', NULL, 14, NULL, NULL, '活动获取', '活动专属（无花瓶关联）', 'assets/flower-images/玉白梨花.webp', false),
  ('玉白贝母', '玉白贝母', '活动鲜花', '[{"detail": "", "channel": "活动鲜花"}]', NULL, 14, NULL, NULL, '活动获取', '活动专属（无花瓶关联）', 'assets/flower-images/玉白贝母.webp', true),
  ('玉紫雪割草', '玉紫雪割草', '花灵', '[{"detail": "花灵", "channel": "花灵"}]', NULL, 23, '月令币', 3999.0, NULL, '雪梅迎春', 'assets/flower-images/玉紫雪割草.webp', false),
  ('玉蕊金棠', '玉蕊金棠', '花灵商店', '[{"detail": "", "channel": "花灵商店"}]', NULL, 25, NULL, NULL, NULL, NULL, 'assets/flower-images/玉蕊金棠.webp', true),
  ('玛瑙石榴花', '玛瑙石榴花', '花灵', '[{"detail": "花灵", "channel": "花灵"}]', NULL, 23, '月令币', 3999.0, NULL, '翠金留芳', 'assets/flower-images/玛瑙石榴花.webp', false),
  ('玫瑰小熊', '玫瑰小熊', '活动鲜花', '[{"detail": "(共赴花约)", "channel": "活动鲜花"}]', NULL, 25, NULL, NULL, '活动获取', '活动专属（无花瓶关联）', 'assets/flower-images/玫瑰小熊.webp', false),
  ('玫瑰粉银莲', '玫瑰粉银莲', '花坊', '[{"detail": "花坊", "channel": "花坊"}]', NULL, 21, '花坊币', 5880.0, '145', '翠金留芳', 'assets/flower-images/玫瑰粉银莲.webp', false),
  ('玫紫车轴草', '玫紫车轴草', '花坊', '[{"detail": "", "channel": "花坊"}]', NULL, 14, '花坊币', 3880.0, NULL, NULL, 'assets/flower-images/玫紫车轴草.webp', true),
  ('玫红古代稀', '玫红古代稀', '星河映蕊', '[{"detail": "", "channel": "星河映蕊"}]', NULL, 21, NULL, NULL, NULL, NULL, 'assets/flower-images/玫红古代稀.webp', true),
  ('玫红非洲堇', '玫红非洲堇', '花坊', '[{"detail": "花坊", "channel": "花坊"}]', NULL, 14, '花坊币', 3880.0, '95', '月影藤生', 'assets/flower-images/玫红非洲堇.webp', false),
  ('珊粉立金花', '珊粉立金花', '礼包花圃', '[{"detail": "礼包花圃", "channel": "礼包花圃"}]', NULL, 23, NULL, NULL, '购齐(映粉云光月季 彤云六初花 素雪瑞香花)赠送', '枝鸣翠羽', 'assets/flower-images/珊粉立金花.webp', false),
  ('珠匣橘芙蓉', '珠匣橘芙蓉', '礼包花圃', '[{"detail": "礼包花圃", "channel": "礼包花圃"}]', NULL, 25, '元', 68.0, NULL, '镜华锦匣', 'assets/flower-images/珠匣橘芙蓉.webp', false),
  ('珠匣粉芙蓉', '珠匣粉芙蓉', '礼包花圃', '[{"detail": "礼包花圃", "channel": "礼包花圃"}]', NULL, 25, '元', 68.0, NULL, '镜华锦匣', 'assets/flower-images/珠匣粉芙蓉.webp', false),
  ('珠匣紫芙蓉', '珠匣紫芙蓉', '礼包花圃', '[{"detail": "礼包花圃", "channel": "礼包花圃"}]', NULL, 25, '元', 68.0, NULL, '镜华锦匣', 'assets/flower-images/珠匣紫芙蓉.webp', false),
  ('珠宝之心', '珠宝之心', '活动鲜花', '[{"detail": "(心联盟)", "channel": "活动鲜花"}]', NULL, 25, NULL, NULL, '活动获取', '活动专属（无花瓶关联）', 'assets/flower-images/珠宝之心.webp', false),
  ('珠斓银杏', '珠斓银杏', '花灵商店', '[{"detail": "", "channel": "花灵商店"}]', NULL, 25, NULL, NULL, NULL, NULL, 'assets/flower-images/珠斓银杏.webp', true),
  ('琉白车轴草', '琉白车轴草', '花坊', '[{"detail": "", "channel": "花坊"}]', NULL, 14, '花坊币', 3880.0, NULL, NULL, 'assets/flower-images/琉白车轴草.webp', true),
  ('琉蓝帝王花', '琉蓝帝王花', '礼包花圃', '[{"detail": "", "channel": "礼包花圃"}]', NULL, 25, '元', 68.0, NULL, '镜华锦匣', 'assets/flower-images/琉蓝帝王花.webp', false),
  ('琼台玉露', '琼台玉露', '活动鲜花', '[{"detail": "国色芳华 （第二期）", "channel": "活动鲜花"}]', NULL, 25, NULL, NULL, '活动获取', '活动专属（无花瓶关联）', 'assets/flower-images/琼台玉露.webp', false),
  ('琼台碧色', '琼台碧色', '活动鲜花', '[{"detail": "", "channel": "活动鲜花"}]', NULL, 25, NULL, NULL, '活动获取', '活动专属（无花瓶关联）', 'assets/flower-images/琼台碧色.webp', true),
  ('瑶光牡丹', '瑶光牡丹', '礼包花圃', '[{"detail": "礼包花圃", "channel": "礼包花圃"}]', NULL, 25, '元', 68.0, NULL, '翠金留芳', 'assets/flower-images/瑶光牡丹.webp', false),
  ('瑶光芙华', '瑶光芙华', '星河映蕊', '[{"detail": "", "channel": "星河映蕊"}]', NULL, 28, NULL, NULL, NULL, NULL, 'assets/flower-images/瑶光芙华.webp', true),
  ('瑶晖缅栀子', '瑶晖缅栀子', '花灵', '[{"detail": "花灵", "channel": "花灵"}]', NULL, 23, '月令币', 3999.0, NULL, '碧荷灵篮', 'assets/flower-images/瑶晖缅栀子.webp', false),
  ('瑶枝桂影', '瑶枝桂影', '花灵商店', '[{"detail": "花灵商店", "channel": "花灵商店"}]', NULL, 25, '月令币', 3999.0, NULL, '月影藤生', 'assets/flower-images/瑶枝桂影.webp', false),
  ('甜橙美女樱', '甜橙美女樱', '礼包花圃', '[{"detail": "礼包花圃", "channel": "礼包花圃"}]', NULL, 23, '元', 28.0, NULL, '锦扇花容', 'assets/flower-images/甜橙美女樱.webp', false),
  ('甜绒羊羊', '甜绒羊羊', '活动鲜花', '[{"detail": "(花开同行)", "channel": "活动鲜花"}]', NULL, 25, NULL, NULL, '活动获取', '活动专属（无花瓶关联）', 'assets/flower-images/甜绒羊羊.webp', false),
  ('白云乱子草', '白云乱子草', '活动鲜花', '[{"detail": "", "channel": "活动鲜花"}]', NULL, 14, NULL, NULL, NULL, NULL, 'assets/flower-images/白云乱子草.webp', true),
  ('白灵逐浪', '白灵逐浪', '礼包花圃', '[{"detail": "礼包花圃", "channel": "礼包花圃"}]', NULL, 25, '元', 68.0, NULL, '水舞苍穹', 'assets/flower-images/白灵逐浪.webp', false),
  ('白玉姜荷花', '白玉姜荷花', '礼包花圃', '[{"detail": "礼包花圃", "channel": "礼包花圃"}]', NULL, 23, NULL, NULL, '购齐(珠匣紫芙蓉 霁蓝紫藤花 白紫凌霄花)赠送', '金盏生芳', 'assets/flower-images/白玉姜荷花.webp', false),
  ('白玉贝壳花', '白玉贝壳花', '花之密令', '[{"detail": "", "channel": "花之密令"}]', NULL, 14, NULL, NULL, NULL, NULL, 'assets/flower-images/白玉贝壳花.webp', true),
  ('白玉音符花', '白玉音符花', '礼包花圃', '[{"detail": "", "channel": "礼包花圃"}]', NULL, 25, NULL, NULL, NULL, NULL, 'assets/flower-images/白玉音符花.webp', true),
  ('白百合', '白百合', '等级花', '[{"detail": "等级花", "channel": "等级花"}]', '00:37:00', 9, NULL, NULL, '等级解锁', '基础等级花（无花瓶关联）', 'assets/flower-images/白百合.webp', false),
  ('白粉蕙兰', '白粉蕙兰', '花坊', '[{"detail": "花坊", "channel": "花坊"}]', NULL, 21, '花坊币', 4880.0, '130', '绿意翠瓶', 'assets/flower-images/白粉蕙兰.webp', false),
  ('白紫凌霄花', '白紫凌霄花', '礼包花圃', '[{"detail": "礼包花圃", "channel": "礼包花圃"}]', NULL, 23, '元', 28.0, NULL, '金盏生芳', 'assets/flower-images/白紫凌霄花.webp', false),
  ('白紫贝母', '白紫贝母', '花之密令', '[{"detail": "", "channel": "花之密令"}]', NULL, 14, NULL, NULL, '密令获取', '镜华锦匣', 'assets/flower-images/白紫贝母.webp', true),
  ('白色满天星', '白色满天星', '花坊', '[{"detail": "花坊", "channel": "花坊"}]', NULL, 14, '花坊币', 2880.0, '95', '浮雕瓷壶', 'assets/flower-images/白色满天星.webp', false),
  ('白花马齿苋', '白花马齿苋', '活动鲜花', '[{"detail": "国色芳华 （第一期）", "channel": "活动鲜花"}]', NULL, 14, NULL, NULL, '活动获取', '活动专属（无花瓶关联）', 'assets/flower-images/白花马齿苋.webp', false),
  ('白茜剑兰', '白茜剑兰', '花坊', '[{"detail": "花坊", "channel": "花坊"}]', NULL, 21, '花坊币', 5880.0, '145', '浮雕瓷壶', 'assets/flower-images/白茜剑兰.webp', false),
  ('白鹤芋', '白鹤芋', '花坊', '[{"detail": "花坊", "channel": "花坊"}]', '19:20:00', 14, '花坊币', 3880.0, NULL, NULL, 'assets/flower-images/白鹤芋.webp', false),
  ('皇冠贝母', '皇冠贝母', '花灵', '[{"detail": "", "channel": "花灵"}]', NULL, 23, NULL, NULL, NULL, NULL, 'assets/flower-images/皇冠贝母.webp', true),
  ('皎如明月', '皎如明月', '活动鲜花', '[{"detail": "", "channel": "活动鲜花"}]', NULL, 25, NULL, NULL, NULL, NULL, 'assets/flower-images/皎如明月.webp', true),
  ('皓白肖鸢尾', '皓白肖鸢尾', '礼包花圃', '[{"detail": "", "channel": "礼包花圃"}]', NULL, 23, NULL, NULL, NULL, NULL, 'assets/flower-images/皓白肖鸢尾.webp', true),
  ('盈粉大花萱草', '盈粉大花萱草', '花之密令', '[{"detail": "", "channel": "花之密令"}]', NULL, 23, NULL, NULL, '密令获取', '碧荷灵篮', 'assets/flower-images/盈粉大花萱草.webp', true),
  ('盈粉翠珠', '盈粉翠珠', '花之密令', '[{"detail": "花之密令", "channel": "花之密令"}]', NULL, 14, NULL, NULL, '密令获取', '锦扇花容', 'assets/flower-images/盈粉翠珠.webp', false),
  ('盈粉芍药', '盈粉芍药', '礼包花圃', '[{"detail": "礼包花圃", "channel": "礼包花圃"}]', NULL, 23, '元', 28.0, NULL, '碧荷灵篮', 'assets/flower-images/盈粉芍药.webp', false),
  ('盈粉荼蘼花', '盈粉荼蘼花', '等级花', '[{"detail": "等级花", "channel": "等级花"}]', '1900/1/1 10:40:00', 9, NULL, NULL, '等级解锁', '基础等级花（无花瓶关联）', 'assets/flower-images/盈粉荼蘼花.webp', false),
  ('碧玉六初花', '碧玉六初花', '礼包花圃', '[{"detail": "", "channel": "礼包花圃"}]', NULL, 23, '元', 28.0, NULL, '枯木逢春', 'assets/flower-images/碧玉六初花.webp', false),
  ('碧白石斛兰', '碧白石斛兰', '花坊', '[{"detail": "", "channel": "花坊"}]', NULL, 14, NULL, NULL, '活动获取', '活动专属（无花瓶关联）', 'assets/flower-images/碧白石斛兰.webp', false),
  ('碧羽青鸾', '碧羽青鸾', '花灵商店', '[{"detail": "花灵商店", "channel": "花灵商店"}]', NULL, 28, '月令币', 3999.0, NULL, '绿意翠瓶', 'assets/flower-images/碧羽青鸾.webp', false),
  ('碧落夹竹桃', '碧落夹竹桃', '礼包花圃', '[{"detail": "礼包花圃", "channel": "礼包花圃"}]', NULL, 23, NULL, NULL, '购齐(冰蓝蝶舞玫瑰 轻紫格桑花 霜色麦冬花)赠送', '流波花樽', 'assets/flower-images/碧落夹竹桃.webp', false),
  ('碧落月见草', '碧落月见草', '星河映蕊', '[{"detail": "星河映蕊", "channel": "星河映蕊"}]', NULL, 21, NULL, NULL, '抽取获取', '幽木流芳', 'assets/flower-images/碧落月见草.webp', false),
  ('碧落杰奎琳', '碧落杰奎琳', '花之密令', '[{"detail": "花之密令", "channel": "花之密令"}]', NULL, 14, NULL, NULL, '密令获取', '镜华锦匣', 'assets/flower-images/碧落杰奎琳.webp', false),
  ('福运招财', '福运招财', '活动鲜花', '[{"detail": "(八分来财)", "channel": "活动鲜花"}]', NULL, 28, NULL, NULL, '活动获取', '活动专属（无花瓶关联）', 'assets/flower-images/福运招财.webp', false),
  ('秋分·枫华玉律', '秋分·枫华玉律', '花灵', '[{"detail": "", "channel": "花灵"}]', NULL, 28, NULL, NULL, NULL, NULL, 'assets/flower-images/秋分·枫华玉律.webp', true),
  ('秋枫跳舞兰', '秋枫跳舞兰', '礼包花圃', '[{"detail": "礼包花圃", "channel": "礼包花圃"}]', NULL, 23, NULL, NULL, '购齐(桃影浮澜 黛紫虞美人 落霞灯笼花)赠送', '幽蓝瓷瓶', 'assets/flower-images/秋枫跳舞兰.webp', false),
  ('竹映金辉', '竹映金辉', '花灵商店', '[{"detail": "花灵商店", "channel": "花灵商店"}]', NULL, 25, '月令币', 3999.0, NULL, '竹韵花影', 'assets/flower-images/竹映金辉.webp', false),
  ('竹韵华灯', '竹韵华灯', '活动鲜花', '[{"detail": "", "channel": "活动鲜花"}]', NULL, 25, NULL, NULL, NULL, NULL, '', true),
  ('粉云溲疏花', '粉云溲疏花', '花灵', '[{"detail": "", "channel": "花灵"}]', NULL, 23, '月令币', 3999.0, NULL, '锦扇花容', 'assets/flower-images/粉云溲疏花.webp', true),
  ('粉星花福禄考', '粉星花福禄考', '礼包花圃', '[{"detail": "", "channel": "礼包花圃"}]', NULL, 23, NULL, NULL, NULL, NULL, 'assets/flower-images/粉星花福禄考.webp', true),
  ('粉月季', '粉月季', '活动鲜花', '[{"detail": "(花开同行)", "channel": "活动鲜花"}]', NULL, 14, NULL, NULL, '活动获取', '活动专属（无花瓶关联）', 'assets/flower-images/粉月季.webp', false),
  ('粉桃花', '粉桃花', '等级花', '[{"detail": "等级花", "channel": "等级花"}]', '1900/1/1 01:20:00', 9, NULL, NULL, '等级解锁', '基础等级花（无花瓶关联）', 'assets/flower-images/粉桃花.webp', false),
  ('粉樱月见草', '粉樱月见草', '星河映蕊', '[{"detail": "星河映蕊", "channel": "星河映蕊"}]', NULL, 21, NULL, NULL, '抽取获取', '幽木流芳', 'assets/flower-images/粉樱月见草.webp', false),
  ('粉樱蝶舞玫瑰', '粉樱蝶舞玫瑰', '礼包花圃', '[{"detail": "礼包花圃", "channel": "礼包花圃"}]', NULL, 25, '元', 68.0, NULL, '蓝心涟漪', 'assets/flower-images/粉樱蝶舞玫瑰.webp', false),
  ('粉玫瑰', '粉玫瑰', '等级花', '[{"detail": "等级花", "channel": "等级花"}]', '08:00:00', 9, NULL, NULL, '等级解锁', '基础等级花（无花瓶关联）', 'assets/flower-images/粉玫瑰.webp', false),
  ('粉白三角梅', '粉白三角梅', '等级花', '[{"detail": "等级花", "channel": "等级花"}]', '1900/1/1 08:40:00', 9, NULL, NULL, '等级解锁', '基础等级花（无花瓶关联）', 'assets/flower-images/粉白三角梅.webp', false),
  ('粉白君子兰', '粉白君子兰', '活动鲜花', '[{"detail": "(迎春接福)", "channel": "活动鲜花"}]', NULL, 14, NULL, NULL, '活动获取', '活动专属（无花瓶关联）', 'assets/flower-images/粉白君子兰.webp', false),
  ('粉白酢浆草', '粉白酢浆草', 'VIP商店', '[{"detail": "VIP商店", "channel": "VIP商店"}]', NULL, 14, NULL, NULL, 'VIP获取', 'VIP专属（无花瓶关联）', 'assets/flower-images/粉白酢浆草.webp', false),
  ('粉白醡浆草', '粉白醡浆草', 'VIP商店', '[{"detail": "", "channel": "VIP商店"}]', NULL, 14, NULL, NULL, NULL, NULL, 'assets/flower-images/粉白醡浆草.webp', true),
  ('粉百合', '粉百合', '等级花', '[{"detail": "等级花", "channel": "等级花"}]', '06:07:00', 9, NULL, NULL, '等级解锁', '基础等级花（无花瓶关联）', 'assets/flower-images/粉百合.webp', false),
  ('粉矢车菊', '粉矢车菊', '花坊', '[{"detail": "花坊", "channel": "花坊"}]', NULL, 14, '花坊币', 880.0, '90', '紫藤流韵', 'assets/flower-images/粉矢车菊.webp', false),
  ('粉石菖蒲', '粉石菖蒲', '活动鲜花', '[{"detail": "", "channel": "活动鲜花"}]', NULL, 14, NULL, NULL, '活动获取', '活动专属（无花瓶关联）', 'assets/flower-images/粉石菖蒲.webp', true),
  ('粉米茶梅花', '粉米茶梅花', '花灵', '[{"detail": "花灵", "channel": "花灵"}]', NULL, 23, '月令币', 3999.0, NULL, '雪梅迎春', 'assets/flower-images/粉米茶梅花.webp', false),
  ('粉米露薇花', '粉米露薇花', '礼包花圃', '[{"detail": "礼包花圃", "channel": "礼包花圃"}]', NULL, 23, NULL, NULL, '购齐(纯白木香花 火蕊朱顶红 橘光朱顶红)赠送', '蓝心涟漪', 'assets/flower-images/粉米露薇花.webp', false),
  ('粉紫华珊', '粉紫华珊', '花坊', '[{"detail": "花坊", "channel": "花坊"}]', NULL, 21, '花坊币', 5880.0, '145', '水舞苍穹', 'assets/flower-images/粉紫华珊.webp', false),
  ('粉红木槿花', '粉红木槿花', '活动鲜花', '[{"detail": "(成长之路)", "channel": "活动鲜花"}]', NULL, 21, NULL, NULL, '活动获取', '活动专属（无花瓶关联）', 'assets/flower-images/粉红木槿花.webp', false),
  ('粉绒免尾草', '粉绒免尾草', '星河映蕊', '[{"detail": "", "channel": "星河映蕊"}]', NULL, 14, NULL, NULL, NULL, NULL, 'assets/flower-images/粉绒免尾草.webp', true),
  ('粉绣球', '粉绣球', '等级花', '[{"detail": "等级花", "channel": "等级花"}]', '11:20:00', 9, NULL, NULL, '等级解锁', '基础等级花（无花瓶关联）', 'assets/flower-images/粉绣球.webp', false),
  ('粉羽朱顶红', '粉羽朱顶红', '礼包花圃', '[{"detail": "礼包花圃", "channel": "礼包花圃"}]', NULL, 23, '元', 28.0, NULL, '雪梅迎春', 'assets/flower-images/粉羽朱顶红.webp', false),
  ('粉胭海棠花', '粉胭海棠花', '礼包花圃', '[{"detail": "礼包花圃", "channel": "礼包花圃"}]', NULL, 23, NULL, NULL, '购齐(紫曜牡丹 柔蓝飞燕草 晴山蔷薇花)赠送', '翠金留芳', 'assets/flower-images/粉胭海棠花.webp', false),
  ('粉色满天星', '粉色满天星', '花坊', '[{"detail": "花坊", "channel": "花坊"}]', NULL, 14, '花坊币', 2880.0, '95', '浮雕瓷壶', 'assets/flower-images/粉色满天星.webp', false),
  ('粉色风信子', '粉色风信子', '等级花', '[{"detail": "等级花", "channel": "等级花"}]', '21:20:00', 9, NULL, NULL, '等级解锁', '基础等级花（无花瓶关联）', 'assets/flower-images/粉色风信子.webp', false),
  ('粉花绮梦', '粉花绮梦', '活动鲜花', '[{"detail": "(缘定鹊桥)", "channel": "活动鲜花"}]', NULL, 23, NULL, NULL, '活动获取', '锦扇花容', 'assets/flower-images/粉花绮梦.webp', false),
  ('粉荷包牡丹', '粉荷包牡丹', '活动鲜花', '[{"detail": "(心联盟)", "channel": "活动鲜花"}]', NULL, 14, NULL, NULL, '活动获取', '活动专属（无花瓶关联）', 'assets/flower-images/粉荷包牡丹.webp', false),
  ('粉菲铁筷花', '粉菲铁筷花', '礼包花圃', '[{"detail": "礼包花圃", "channel": "礼包花圃"}]', NULL, 23, '元', 28.0, NULL, '雪梅迎春', 'assets/flower-images/粉菲铁筷花.webp', false),
  ('粉蓝换锦花', '粉蓝换锦花', '活动鲜花', '[{"detail": "", "channel": "活动鲜花"}]', NULL, 14, NULL, NULL, NULL, NULL, 'assets/flower-images/粉蓝换锦花.webp', true),
  ('粉郁金香', '粉郁金香', '等级花', '[{"detail": "等级花", "channel": "等级花"}]', '05:00:00', 9, NULL, NULL, '等级解锁', '基础等级花（无花瓶关联）', 'assets/flower-images/粉郁金香.webp', false),
  ('粉韵石竹花', '粉韵石竹花', '花之密令', '[{"detail": "花之密令", "channel": "花之密令"}]', NULL, 23, NULL, NULL, '密令获取', '丹青瓷瓶', 'assets/flower-images/粉韵石竹花.webp', false),
  ('粉鹤芋', '粉鹤芋', '花坊', '[{"detail": "花坊", "channel": "花坊"}]', NULL, 21, '花坊币', 7880.0, '185', '丹青瓷瓶', 'assets/flower-images/粉鹤芋.webp', false),
  ('粉黛德鸢', '粉黛德鸢', '礼包花圃', '[{"detail": "礼包花圃", "channel": "礼包花圃"}]', NULL, 23, '元', 28.0, NULL, '幽木流芳', 'assets/flower-images/粉黛德鸢.webp', false),
  ('素白九里香', '素白九里香', '等级花', '[{"detail": "等级花", "channel": "等级花"}]', '1900/1/1 08:00:00', 9, NULL, NULL, '等级解锁', '基础等级花（无花瓶关联）', 'assets/flower-images/素白九里香.webp', false),
  ('素白茑萝', '素白茑萝', '活动鲜花', '[{"detail": "", "channel": "活动鲜花"}]', NULL, 14, NULL, NULL, NULL, NULL, 'assets/flower-images/素白茑萝.webp', true),
  ('素雪玉簪花', '素雪玉簪花', '花之密令', '[{"detail": "花之密令", "channel": "花之密令"}]', NULL, 14, NULL, NULL, '密令获取', '枯木逢春', 'assets/flower-images/素雪玉簪花.webp', false),
  ('素雪瑞香花', '素雪瑞香花', '礼包花圃', '[{"detail": "礼包花圃", "channel": "礼包花圃"}]', NULL, 23, '元', 28.0, NULL, '枝鸣翠羽', 'assets/flower-images/素雪瑞香花.webp', false),
  ('紫星花福禄考', '紫星花福禄考', '礼包花圃', '[{"detail": "", "channel": "礼包花圃"}]', NULL, 23, NULL, NULL, NULL, NULL, 'assets/flower-images/紫星花福禄考.webp', true),
  ('紫晕石竹花', '紫晕石竹花', '礼包花圃', '[{"detail": "", "channel": "礼包花圃"}]', NULL, 23, '元', 28.0, NULL, '丹青瓷瓶', 'assets/flower-images/紫晕石竹花.webp', false),
  ('紫晶灯笼花', '紫晶灯笼花', '礼包花圃', '[{"detail": "礼包花圃", "channel": "礼包花圃"}]', NULL, 23, NULL, NULL, '购齐(白灵逐浪 薄红虞美人 樱红跳舞兰)赠送', '翠羽芳华', 'assets/flower-images/紫晶灯笼花.webp', false),
  ('紫晶玉簪花', '紫晶玉簪花', '花坊', '[{"detail": "", "channel": "花坊"}]', NULL, 14, '花坊币', 3880.0, NULL, '枯木逢春', 'assets/flower-images/紫晶玉簪花.webp', false),
  ('紫曜牡丹', '紫曜牡丹', '礼包花圃', '[{"detail": "礼包花圃", "channel": "礼包花圃"}]', NULL, 25, '元', 68.0, NULL, '翠金留芳', 'assets/flower-images/紫曜牡丹.webp', false),
  ('紫桔梗', '紫桔梗', '等级花', '[{"detail": "等级花", "channel": "等级花"}]', '03:00:00', 9, NULL, NULL, '等级解锁', '基础等级花（无花瓶关联）', 'assets/flower-images/紫桔梗.webp', false),
  ('紫灵福禄', '紫灵福禄', '活动鲜花', '[{"detail": "", "channel": "活动鲜花"}]', NULL, 25, '元', 28.0, NULL, '锦扇花容', 'assets/flower-images/紫灵福禄.webp', false),
  ('紫瑶蛾蝶花', '紫瑶蛾蝶花', '礼包花圃', '[{"detail": "", "channel": "礼包花圃"}]', NULL, 23, NULL, NULL, NULL, NULL, 'assets/flower-images/紫瑶蛾蝶花.webp', true),
  ('紫百子莲', '紫百子莲', '等级花', '[{"detail": "等级花", "channel": "等级花"}]', '1900/1/1 11:20:00', 9, NULL, NULL, '等级解锁', '基础等级花（无花瓶关联）', 'assets/flower-images/紫百子莲.webp', false),
  ('紫矢车菊', '紫矢车菊', '花坊', '[{"detail": "花坊", "channel": "花坊"}]', NULL, 14, '花坊币', 880.0, '60', '紫藤流韵', 'assets/flower-images/紫矢车菊.webp', false),
  ('紫红三角梅', '紫红三角梅', '等级花', '[{"detail": "等级花", "channel": "等级花"}]', '1900/1/1 06:00:00', 9, NULL, NULL, '等级解锁', '基础等级花（无花瓶关联）', 'assets/flower-images/紫红三角梅.webp', false),
  ('紫红杜鹃', '紫红杜鹃', '花坊', '[{"detail": "花坊", "channel": "花坊"}]', NULL, 14, '花坊币', 3880.0, '95', '碧荷灵篮', 'assets/flower-images/紫红杜鹃.webp', false),
  ('紫绣球', '紫绣球', '等级花', '[{"detail": "等级花", "channel": "等级花"}]', '10:00:00', 9, NULL, NULL, '等级解锁', '基础等级花（无花瓶关联）', 'assets/flower-images/紫绣球.webp', false),
  ('紫罗兰', '紫罗兰', '等级花', '[{"detail": "等级花", "channel": "等级花"}]', '04:20:00', 9, NULL, NULL, '等级解锁', '基础等级花（无花瓶关联）', 'assets/flower-images/紫罗兰.webp', false),
  ('紫色丁香花', '紫色丁香花', '等级花', '[{"detail": "等级花", "channel": "等级花"}]', '1900/1/1 03:20:00', 9, NULL, NULL, '等级解锁', '基础等级花（无花瓶关联）', 'assets/flower-images/紫色丁香花.webp', false),
  ('紫色风信子', '紫色风信子', '等级花', '[{"detail": "等级花", "channel": "等级花"}]', '20:00:00', 9, NULL, NULL, '等级解锁', '基础等级花（无花瓶关联）', 'assets/flower-images/紫色风信子.webp', false),
  ('紫苑凤眼莲', '紫苑凤眼莲', '花灵', '[{"detail": "花灵", "channel": "花灵"}]', NULL, 23, '月令币', 3999.0, NULL, '水舞苍穹', 'assets/flower-images/紫苑凤眼莲.webp', false),
  ('紫苑番红花', '紫苑番红花', '花灵', '[{"detail": "花灵", "channel": "花灵"}]', NULL, 23, '月令币', 3999.0, NULL, '水舞苍穹', 'assets/flower-images/紫苑番红花.webp', false),
  ('紫荷包牡丹', '紫荷包牡丹', '活动鲜花', '[{"detail": "(心联盟)", "channel": "活动鲜花"}]', NULL, 14, NULL, NULL, '活动获取', '活动专属（无花瓶关联）', 'assets/flower-images/紫荷包牡丹.webp', false),
  ('紫褐墨兰', '紫褐墨兰', '活动鲜花', '[{"detail": "", "channel": "活动鲜花"}]', NULL, 14, NULL, NULL, NULL, NULL, 'assets/flower-images/紫褐墨兰.webp', true),
  ('紫霁大岩桐', '紫霁大岩桐', '花之密令', '[{"detail": "", "channel": "花之密令"}]', NULL, 23, NULL, NULL, '密令获取', '月影藤生', 'assets/flower-images/紫霁大岩桐.webp', true),
  ('紫霄云庭', '紫霄云庭', '星辰商店', '[{"detail": "星辰商店", "channel": "星辰商店"}]', NULL, 30, '月令币', 3999.0, NULL, '流波花樽', 'assets/flower-images/紫霄云庭.webp', false),
  ('紫马蹄莲', '紫马蹄莲', '等级花', '[{"detail": "等级花", "channel": "等级花"}]', '19:20:00', 9, NULL, NULL, '等级解锁', '基础等级花（无花瓶关联）', 'assets/flower-images/紫马蹄莲.webp', false),
  ('紫麦冬花', '紫麦冬花', '花坊', '[{"detail": "花坊", "channel": "花坊"}]', NULL, 14, '花坊币', 2880.0, '95', '蓝心涟漪', 'assets/flower-images/紫麦冬花.webp', false),
  ('繁花满筑', '繁花满筑', '活动鲜花', '[{"detail": "国色芳华 （第二期）", "channel": "活动鲜花"}]', NULL, 28, NULL, NULL, '活动获取', '活动专属（无花瓶关联）', 'assets/flower-images/繁花满筑.webp', false),
  ('红玫瑰', '红玫瑰', '等级花', '[{"detail": "等级花", "channel": "等级花"}]', '06:40:00', 9, NULL, NULL, '等级解锁', '基础等级花（无花瓶关联）', 'assets/flower-images/红玫瑰.webp', false),
  ('红霞彩叶草', '红霞彩叶草', '活动鲜花', '[{"detail": "", "channel": "活动鲜花"}]', NULL, 14, NULL, NULL, NULL, NULL, 'assets/flower-images/红霞彩叶草.webp', true),
  ('红香妃腊梅', '红香妃腊梅', '礼包花圃', '[{"detail": "礼包花圃", "channel": "礼包花圃"}]', NULL, 25, '元', 68.0, NULL, '雪梅迎春', 'assets/flower-images/红香妃腊梅.webp', false),
  ('红马蹄莲', '红马蹄莲', '等级花', '[{"detail": "等级花", "channel": "等级花"}]', '16:40:00', 9, NULL, NULL, '等级解锁', '基础等级花（无花瓶关联）', 'assets/flower-images/红马蹄莲.webp', false),
  ('红鹤芋', '红鹤芋', '花坊', '[{"detail": "花坊", "channel": "花坊"}]', '18:00:00', 14, '花坊币', 3880.0, NULL, NULL, 'assets/flower-images/红鹤芋.webp', false),
  ('纯白晚香玉', '纯白晚香玉', '等级花', '[{"detail": "等级花", "channel": "等级花"}]', NULL, 9, NULL, NULL, '等级解锁', '基础等级花（无花瓶关联）', 'assets/flower-images/纯白晚香玉.webp', false),
  ('纯白月光花', '纯白月光花', '活动鲜花', '[{"detail": "", "channel": "活动鲜花"}]', NULL, 14, NULL, NULL, NULL, NULL, 'assets/flower-images/纯白月光花.webp', true),
  ('纯白木香花', '纯白木香花', '礼包花圃', '[{"detail": "礼包花圃", "channel": "礼包花圃"}]', NULL, 23, '元', 28.0, NULL, '月影藤生', 'assets/flower-images/纯白木香花.webp', false),
  ('纱粉嘉兰', '纱粉嘉兰', '花之密令', '[{"detail": "花之密令", "channel": "花之密令"}]', NULL, 23, NULL, NULL, '密令获取', '翠羽芳华', 'assets/flower-images/纱粉嘉兰.webp', false),
  ('纸鸢探春', '纸鸢探春', '活动鲜花', '[{"detail": "(花漾春山)", "channel": "活动鲜花"}]', NULL, 25, NULL, NULL, '活动获取', '活动专属（无花瓶关联）', 'assets/flower-images/纸鸢探春.webp', false),
  ('绀紫肖鸢尾', '绀紫肖鸢尾', '礼包花圃', '[{"detail": "", "channel": "礼包花圃"}]', NULL, 23, '元', 28.0, NULL, '幽木流芳', 'assets/flower-images/绀紫肖鸢尾.webp', true),
  ('绀紫飞燕草', '绀紫飞燕草', '花坊', '[{"detail": "花坊", "channel": "花坊"}]', NULL, 21, '花坊币', 5880.0, '145', '翠羽芳华', 'assets/flower-images/绀紫飞燕草.webp', false),
  ('绛橙嘉兰', '绛橙嘉兰', '礼包花圃', '[{"detail": "", "channel": "礼包花圃"}]', NULL, 23, '元', 28.0, NULL, '翠羽芳华', 'assets/flower-images/绛橙嘉兰.webp', false),
  ('custom_1775479605797_wvf2wm', '绛粉大岩桐', '鲜花礼包', '[{"detail": "", "channel": "鲜花礼包"}]', NULL, 23, NULL, NULL, NULL, NULL, 'assets/flower-images/绛粉大岩桐.webp', false),
  ('绛红报春花', '绛红报春花', 'VIP商店', '[{"detail": "VIP商店", "channel": "VIP商店"}]', NULL, 14, NULL, NULL, 'VIP获取', '枯木逢春', 'assets/flower-images/绛红报春花.webp', false),
  ('绛红玉叶金花', '绛红玉叶金花', '等级花', '[{"detail": "", "channel": "等级花"}]', NULL, 9, NULL, NULL, NULL, NULL, 'assets/flower-images/绛红玉叶金花.webp', true),
  ('绯云韵光', '绯云韵光', '活动鲜花', '[{"detail": "", "channel": "活动鲜花"}]', NULL, 25, NULL, NULL, NULL, NULL, 'assets/flower-images/绯云韵光.webp', true),
  ('绯色腊梅', '绯色腊梅', '星河映蕊', '[{"detail": "星河映蕊", "channel": "星河映蕊"}]', NULL, 21, NULL, NULL, '抽取获取', '雪梅迎春', 'assets/flower-images/绯色腊梅.webp', false),
  ('绯雪杰奎琳', '绯雪杰奎琳', '花坊', '[{"detail": "花坊", "channel": "花坊"}]', NULL, 14, '花坊币', 3880.0, '99', '镜华锦匣', 'assets/flower-images/绯雪杰奎琳.webp', false),
  ('绿叶苏铁', '绿叶苏铁', '花坊', '[{"detail": "花坊", "channel": "花坊"}]', NULL, 14, '花坊币', 3880.0, '99', '丹青瓷瓶', 'assets/flower-images/绿叶苏铁.webp', false),
  ('缃桃六初花', '缃桃六初花', '花之密令', '[{"detail": "花之密令", "channel": "花之密令"}]', NULL, 23, NULL, NULL, '密令获取', '枯木逢春', 'assets/flower-images/缃桃六初花.webp', false),
  ('缃黄瑞香花', '缃黄瑞香花', '礼包花圃', '[{"detail": "礼包花圃", "channel": "礼包花圃"}]', NULL, 23, NULL, NULL, '购齐(沐光映黄月季 丹红耧斗菜 松绿立金花)赠送', '枝鸣翠羽', 'assets/flower-images/缃黄瑞香花.webp', false),
  ('缘定鹊桥', '缘定鹊桥', '活动鲜花', '[{"detail": "(缘定鹊桥)", "channel": "活动鲜花"}]', NULL, 28, NULL, NULL, '活动获取', '活动专属（无花瓶关联）', 'assets/flower-images/缘定鹊桥.webp', false),
  ('胭粉音符花', '胭粉音符花', '花坊', '[{"detail": "", "channel": "花坊"}]', NULL, 21, '花坊币', 5880.0, NULL, NULL, 'assets/flower-images/胭粉音符花.webp', true),
  ('胭红蕨叶芍药', '胭红蕨叶芍药', '花坊', '[{"detail": "", "channel": "花坊"}]', NULL, 14, '花坊币', 3880.0, NULL, NULL, 'assets/flower-images/胭红蕨叶芍药.webp', true),
  ('胭脂芍药', '胭脂芍药', '花坊', '[{"detail": "花坊", "channel": "花坊"}]', NULL, 23, '花坊币', 5880.0, '145', '流波花樽', 'assets/flower-images/胭脂芍药.webp', false),
  ('芋紫剑兰', '芋紫剑兰', '花坊', '[{"detail": "花坊", "channel": "花坊"}]', NULL, 21, '花坊币', 5880.0, '145', '浮雕瓷壶', 'assets/flower-images/芋紫剑兰.webp', false),
  ('芍华茗宴', '芍华茗宴', '鲜花礼包', '[{"detail": "", "channel": "鲜花礼包"}]', NULL, 25, NULL, NULL, NULL, NULL, 'assets/flower-images/芍华茗宴.webp', true),
  ('花信未迟', '花信未迟', '鲜花礼包', '[{"detail": "", "channel": "鲜花礼包"}]', NULL, 25, '元', 68.0, NULL, NULL, 'assets/flower-images/花信未迟.webp', true),
  ('花宴流芳', '花宴流芳', '活动鲜花', '[{"detail": "(芳庭花宴)", "channel": "活动鲜花"}]', NULL, 28, NULL, NULL, '活动获取', '活动专属（无花瓶关联）', 'assets/flower-images/花宴流芳.webp', false),
  ('花屿闲趣', '花屿闲趣', '活动鲜花', '[{"detail": "", "channel": "活动鲜花"}]', NULL, 28, NULL, NULL, '活动获取', '活动专属（无花瓶关联）', 'assets/flower-images/花屿闲趣.webp', true),
  ('花引赠春', '花引赠春', '鲜花礼包', '[{"detail": "", "channel": "鲜花礼包"}]', NULL, 25, '元', 68.0, NULL, NULL, 'assets/flower-images/花引赠春.webp', true),
  ('花影泛舟', '花影泛舟', '鲜花礼包', '[{"detail": "", "channel": "鲜花礼包"}]', NULL, 25, '元', 68.0, NULL, NULL, 'assets/flower-images/花影泛舟.webp', true),
  ('花扇鹊嬉', '花扇鹊嬉', '活动鲜花', '[{"detail": "(缘定鹊桥)", "channel": "活动鲜花"}]', NULL, 25, NULL, NULL, '活动获取', '活动专属（无花瓶关联）', 'assets/flower-images/花扇鹊嬉.webp', false),
  ('花映长思', '花映长思', '活动鲜花', '[{"detail": "", "channel": "活动鲜花"}]', NULL, 28, NULL, NULL, NULL, NULL, 'assets/flower-images/花映长思.webp', true),
  ('花椅轻摇', '花椅轻摇', '活动鲜花', '[{"detail": "", "channel": "活动鲜花"}]', NULL, 25, NULL, NULL, '活动获取', '活动专属（无花瓶关联）', 'assets/flower-images/花椅轻摇.webp', true),
  ('花汀月舫', '花汀月舫', '鲜花礼包', '[{"detail": "", "channel": "鲜花礼包"}]', NULL, 25, '元', 68.0, NULL, NULL, 'assets/flower-images/花汀月舫.webp', true),
  ('花涧听泉', '花涧听泉', '活动鲜花', '[{"detail": "", "channel": "活动鲜花"}]', NULL, 28, NULL, NULL, NULL, NULL, 'assets/flower-images/花涧听泉.webp', true),
  ('花溪泊梦', '花溪泊梦', '鲜花礼包', '[{"detail": "", "channel": "鲜花礼包"}]', NULL, 25, '元', 68.0, NULL, NULL, 'assets/flower-images/花溪泊梦.webp', true),
  ('花溪灯语', '花溪灯语', '活动鲜花', '[{"detail": "", "channel": "活动鲜花"}]', NULL, 28, NULL, NULL, NULL, NULL, 'assets/flower-images/花溪灯语.webp', true),
  ('花漾春山', '花漾春山', '活动鲜花', '[{"detail": "(花漾春山)", "channel": "活动鲜花"}]', NULL, 28, NULL, NULL, '活动获取', '活动专属（无花瓶关联）', 'assets/flower-images/花漾春山.webp', false),
  ('花笼星语', '花笼星语', '礼包花圃', '[{"detail": "", "channel": "礼包花圃"}]', NULL, 25, '元', 68.0, NULL, '绮花幻蝶', 'assets/flower-images/花笼星语.webp', false),
  ('花笼流芳', '花笼流芳', '礼包花圃', '[{"detail": "", "channel": "礼包花圃"}]', NULL, 25, '元', 68.0, NULL, '绮花幻蝶', 'assets/flower-images/花笼流芳.webp', false),
  ('花笼琼光', '花笼琼光', '礼包花圃', '[{"detail": "", "channel": "礼包花圃"}]', NULL, 25, '元', 68.0, NULL, '绮花幻蝶', 'assets/flower-images/花笼琼光.webp', false),
  ('花筵鼓韵', '花筵鼓韵', '活动鲜花', '[{"detail": "", "channel": "活动鲜花"}]', NULL, 25, NULL, NULL, NULL, NULL, 'assets/flower-images/花筵鼓韵.webp', true),
  ('花约归时', '花约归时', '鲜花礼包', '[{"detail": "", "channel": "鲜花礼包"}]', NULL, 25, '元', 68.0, NULL, NULL, 'assets/flower-images/花约归时.webp', true),
  ('花露甜粥', '花露甜粥', '鲜花礼包', '[{"detail": "鲜花礼包", "channel": "鲜花礼包"}]', NULL, 25, '元', 68.0, NULL, '碧荷灵篮', 'assets/flower-images/花露甜粥.webp', false),
  ('芳华寻蝶', '芳华寻蝶', '活动鲜花', '[{"detail": "国色芳华 （第一期）", "channel": "活动鲜花"}]', NULL, 28, NULL, NULL, '活动获取', '活动专属（无花瓶关联）', 'assets/flower-images/芳华寻蝶.webp', false),
  ('芳翎昭锦', '芳翎昭锦', '活动鲜花', '[{"detail": "", "channel": "活动鲜花"}]', NULL, 28, NULL, NULL, NULL, NULL, '', true),
  ('芳蕊琼浆', '芳蕊琼浆', '活动鲜花', '[{"detail": "(芳庭花宴)", "channel": "活动鲜花"}]', NULL, 25, NULL, NULL, '活动获取', '活动专属（无花瓶关联）', 'assets/flower-images/芳蕊琼浆.webp', false),
  ('芳蕊琼莲', '芳蕊琼莲', '活动鲜花', '[{"detail": "", "channel": "活动鲜花"}]', NULL, 25, NULL, NULL, NULL, NULL, 'assets/flower-images/芳蕊琼莲.webp', true),
  ('苔绿贝壳花', '苔绿贝壳花', '活动鲜花', '[{"detail": "", "channel": "活动鲜花"}]', NULL, 14, NULL, NULL, NULL, NULL, 'assets/flower-images/苔绿贝壳花.webp', true),
  ('茉莉花', '茉莉花', '等级花', '[{"detail": "等级花", "channel": "等级花"}]', '22:00:00', 9, NULL, NULL, '等级解锁', '基础等级花（无花瓶关联）', 'assets/flower-images/茉莉花.webp', false),
  ('荷月·池光夏梦', '荷月·池光夏梦', '花灵', '[{"detail": "花灵", "channel": "花灵"}]', NULL, 28, '月令币', 3999.0, NULL, '碧荷灵篮', 'assets/flower-images/荷月·池光夏梦.webp', false),
  ('莹白露薇花', '莹白露薇花', '花坊', '[{"detail": "花坊", "channel": "花坊"}]', NULL, 21, '花坊币', 4880.0, '130', '蓝心涟漪', 'assets/flower-images/莹白露薇花.webp', false),
  ('菊月·花间飞鸢', '菊月·花间飞鸢', '花灵', '[{"detail": "花灵", "channel": "花灵"}]', NULL, 28, '月令币', 3999.0, NULL, '幽木流芳', 'assets/flower-images/菊月·花间飞鸢.webp', false),
  ('萤栖碧绡', '萤栖碧绡', '活动鲜花', '[{"detail": "", "channel": "活动鲜花"}]', NULL, 25, NULL, NULL, NULL, NULL, 'assets/flower-images/萤栖碧绡.webp', true),
  ('落英浮香', '落英浮香', '活动鲜花', '[{"detail": "", "channel": "活动鲜花"}]', NULL, 25, NULL, NULL, '活动获取', '活动专属（无花瓶关联）', 'assets/flower-images/落英浮香.webp', true),
  ('custom_1776067919449_zeoghh', '落霞橙牡丹菊', '鲜花礼包', '[{"detail": "", "channel": "鲜花礼包"}]', NULL, 25, NULL, NULL, NULL, NULL, 'assets/flower-images/落霞橙牡丹菊.webp', true),
  ('落霞灯笼花', '落霞灯笼花', '礼包花圃', '[{"detail": "礼包花圃", "channel": "礼包花圃"}]', NULL, 23, '元', 28.0, NULL, '翠羽芳华', 'assets/flower-images/落霞灯笼花.webp', false),
  ('葡萄紫牡丹菊', '葡萄紫牡丹菊', '礼包花圃', '[{"detail": "", "channel": "礼包花圃"}]', NULL, 25, '元', 68.0, NULL, '竹韵花影', 'assets/flower-images/葡萄紫牡丹菊.webp', false),
  ('葭月·栖舟泛漪', '葭月·栖舟泛漪', '花灵', '[{"detail": "花灵", "channel": "花灵"}]', NULL, 28, '月令币', 3999.0, NULL, '流波花樽', 'assets/flower-images/葭月·栖舟泛漪.webp', false),
  ('蒲公英', '蒲公英', '等级花', '[{"detail": "等级花", "channel": "等级花"}]', '18:40:00', 9, NULL, NULL, '等级解锁', '基础等级花（无花瓶关联）', 'assets/flower-images/蒲公英.webp', false),
  ('蓝叶苏铁', '蓝叶苏铁', '花坊', '[{"detail": "花坊", "channel": "花坊"}]', NULL, 23, '花坊币', 11800.0, '210', '丹青瓷瓶', 'assets/flower-images/蓝叶苏铁.webp', false),
  ('蓝星花', '蓝星花', '等级花', '[{"detail": "等级花", "channel": "等级花"}]', '08:40:00', 9, NULL, NULL, '等级解锁', '基础等级花（无花瓶关联）', 'assets/flower-images/蓝星花.webp', false),
  ('蓝矢车菊', '蓝矢车菊', '花坊', '[{"detail": "花坊", "channel": "花坊"}]', NULL, 14, '花坊币', 1680.0, '90', '紫藤流韵', 'assets/flower-images/蓝矢车菊.webp', false),
  ('蓝绣球', '蓝绣球', '等级花', '[{"detail": "等级花", "channel": "等级花"}]', '12:40:00', 9, NULL, NULL, '等级解锁', '基础等级花（无花瓶关联）', 'assets/flower-images/蓝绣球.webp', false),
  ('蓝色满天星', '蓝色满天星', '花坊', '[{"detail": "花坊", "channel": "花坊"}]', NULL, 14, '花坊币', 2880.0, '95', '浮雕瓷壶', 'assets/flower-images/蓝色满天星.webp', false),
  ('蓝花亚麻', '蓝花亚麻', '花灵', '[{"detail": "", "channel": "花灵"}]', NULL, 23, NULL, NULL, NULL, NULL, 'assets/flower-images/蓝花亚麻.webp', true),
  ('薄粉蕙兰', '薄粉蕙兰', '星河映蕊', '[{"detail": "星河映蕊", "channel": "星河映蕊"}]', NULL, 14, NULL, NULL, '抽取获取', '绿意翠瓶', 'assets/flower-images/薄粉蕙兰.webp', false),
  ('薄红虞美人', '薄红虞美人', '礼包花圃', '[{"detail": "礼包花圃", "channel": "礼包花圃"}]', NULL, 23, '元', 28.0, NULL, '竹韵花影', 'assets/flower-images/薄红虞美人.webp', false),
  ('薄藤铁线莲', '薄藤铁线莲', '花坊', '[{"detail": "花坊", "channel": "花坊"}]', '18:40:00', 14, '花坊币', 3880.0, NULL, NULL, 'assets/flower-images/薄藤铁线莲.webp', false),
  ('薰紫球根海棠', '薰紫球根海棠', '星河映蕊', '[{"detail": "", "channel": "星河映蕊"}]', NULL, 21, NULL, NULL, NULL, NULL, 'assets/flower-images/薰紫球根海棠.webp', true),
  ('薰紫香豌豆', '薰紫香豌豆', '花坊', '[{"detail": "", "channel": "花坊"}]', NULL, 14, NULL, NULL, '活动获取', '活动专属（无花瓶关联）', 'assets/flower-images/薰紫香豌豆.webp', false),
  ('藕粉长寿花', '藕粉长寿花', '礼包花圃', '[{"detail": "礼包花圃", "channel": "礼包花圃"}]', NULL, 23, '元', 28.0, NULL, '雪梅迎春', 'assets/flower-images/藕粉长寿花.webp', false),
  ('藤紫大花萱草', '藤紫大花萱草', '鲜花礼包', '[{"detail": "", "channel": "鲜花礼包"}]', NULL, 23, '元', 28.0, NULL, '碧荷灵篮', 'assets/flower-images/藤紫大花萱草.webp', true),
  ('藤黄露薇花', '藤黄露薇花', '花坊', '[{"detail": "花坊", "channel": "花坊"}]', NULL, 21, '花坊币', 4880.0, '130', '蓝心涟漪', 'assets/flower-images/藤黄露薇花.webp', false),
  ('虹霞仙芝', '虹霞仙芝', '星辰商店', '[{"detail": "星辰商店", "channel": "星辰商店"}]', NULL, 25, '月令币', 3999.0, NULL, '水舞苍穹', 'assets/flower-images/虹霞仙芝.webp', false),
  ('蜜合月见草', '蜜合月见草', '花坊', '[{"detail": "花坊", "channel": "花坊"}]', NULL, 21, '花坊币', 5880.0, '145', '幽木流芳', 'assets/flower-images/蜜合月见草.webp', false),
  ('蜜桃花毛莨', '蜜桃花毛莨', '礼包花圃', '[{"detail": "", "channel": "礼包花圃"}]', NULL, 23, '元', 28.0, NULL, '月影藤生', 'assets/flower-images/蜜桃花毛莨.webp', false),
  ('蜜粉白玉草', '蜜粉白玉草', '花灵', '[{"detail": "", "channel": "花灵"}]', NULL, 23, '月令币', 3999.0, NULL, '云腾绕梦', 'assets/flower-images/蜜粉白玉草.webp', true),
  ('蜜粉龙面花', '蜜粉龙面花', '礼包花圃', '[{"detail": "", "channel": "礼包花圃"}]', NULL, 23, '元', 28.0, NULL, '水舞苍穹', 'assets/flower-images/蜜粉龙面花.webp', false),
  ('蜜黄大岩桐', '蜜黄大岩桐', '鲜花礼包', '[{"detail": "", "channel": "鲜花礼包"}]', NULL, 23, '元', 28.0, NULL, '月影藤生', 'assets/flower-images/蜜黄大岩桐.webp', true),
  ('蜜黄针垫花', '蜜黄针垫花', '花坊', '[{"detail": "花坊", "channel": "花坊"}]', NULL, 14, '花坊币', 3880.0, NULL, NULL, 'assets/flower-images/蜜黄针垫花.webp', false),
  ('蝴蝶兰', '蝴蝶兰', '等级花', '[{"detail": "等级花", "channel": "等级花"}]', '05:33:00', 9, NULL, NULL, '等级解锁', '基础等级花（无花瓶关联）', 'assets/flower-images/蝴蝶兰.webp', false),
  ('蝶影梅书', '蝶影梅书', '礼包花圃', '[{"detail": "", "channel": "礼包花圃"}]', NULL, 25, '元', 68.0, NULL, '雪梅迎春', 'assets/flower-images/蝶影梅书.webp', false),
  ('褐红铁筷花', '褐红铁筷花', '花坊', '[{"detail": "花坊", "channel": "花坊"}]', NULL, 21, '花坊币', 5880.0, '145', '雪梅迎春', 'assets/flower-images/褐红铁筷花.webp', false),
  ('赤丹凤凰花', '赤丹凤凰花', '等级花', '[{"detail": "", "channel": "等级花"}]', NULL, 9, NULL, NULL, NULL, NULL, 'assets/flower-images/赤丹凤凰花.webp', true),
  ('赤晖石竹花', '赤晖石竹花', '礼包花圃', '[{"detail": "", "channel": "礼包花圃"}]', NULL, 23, '元', 28.0, NULL, '丹青瓷瓶', 'assets/flower-images/赤晖石竹花.webp', false),
  ('赤焰火焰兰', '赤焰火焰兰', '花坊', '[{"detail": "花坊", "channel": "花坊"}]', NULL, 21, '花坊币', 4880.0, '130', '花影流光', 'assets/flower-images/赤焰火焰兰.webp', false),
  ('赤霞太阳花', '赤霞太阳花', '星河映蕊', '[{"detail": "", "channel": "星河映蕊"}]', NULL, 21, NULL, NULL, NULL, NULL, 'assets/flower-images/赤霞太阳花.webp', true),
  ('赤霞火焰花', '赤霞火焰花', '活动鲜花', '[{"detail": "", "channel": "活动鲜花"}]', NULL, 25, NULL, NULL, '活动获取', '活动专属（无花瓶关联）', 'assets/flower-images/赤霞火焰花.webp', true),
  ('身有彩翼', '身有彩翼', '活动鲜花', '[{"detail": "", "channel": "活动鲜花"}]', NULL, 30, NULL, NULL, NULL, NULL, 'assets/flower-images/身有彩翼.webp', true),
  ('轮生冬青', '轮生冬青', '活动鲜花', '[{"detail": "(七日登录)", "channel": "活动鲜花"}]', '1900/1/1 09:20:00', 21, NULL, NULL, '活动获取', '活动专属（无花瓶关联）', 'assets/flower-images/轮生冬青.webp', false),
  ('轻粉蓝铃花', '轻粉蓝铃花', '活动鲜花', '[{"detail": "", "channel": "活动鲜花"}]', NULL, 14, NULL, NULL, NULL, NULL, 'assets/flower-images/轻粉蓝铃花.webp', true),
  ('轻紫大花葱', '轻紫大花葱', '花坊', '[{"detail": "花坊", "channel": "花坊"}]', NULL, 21, '花坊币', 5880.0, '145', '丹青瓷瓶', 'assets/flower-images/轻紫大花葱.webp', false),
  ('轻紫忘忧草', '轻紫忘忧草', 'VIP商店', '[{"detail": "VIP商店", "channel": "VIP商店"}]', NULL, 14, NULL, NULL, 'VIP获取', 'VIP专属（无花瓶关联）', 'assets/flower-images/轻紫忘忧草.webp', false),
  ('轻紫格桑花', '轻紫格桑花', '礼包花圃', '[{"detail": "礼包花圃", "channel": "礼包花圃"}]', NULL, 23, '元', 28.0, NULL, '幽蓝瓷瓶', 'assets/flower-images/轻紫格桑花.webp', false),
  ('轻紫翠珠', '轻紫翠珠', '花坊', '[{"detail": "花坊", "channel": "花坊"}]', NULL, 14, '花坊币', 3880.0, NULL, NULL, 'assets/flower-images/轻紫翠珠.webp', false),
  ('轻紫非洲堇', '轻紫非洲堇', '花坊', '[{"detail": "花坊", "channel": "花坊"}]', NULL, 14, '花坊币', 3880.0, '99', '月影藤生', 'assets/flower-images/轻紫非洲堇.webp', false),
  ('轻蓝贝母', '轻蓝贝母', 'VIP商店', '[{"detail": "", "channel": "VIP商店"}]', NULL, 14, NULL, NULL, 'VIP获取', 'VIP专属（无花瓶关联）', 'assets/flower-images/轻蓝贝母.webp', true),
  ('辉似朝阳', '辉似朝阳', '活动鲜花', '[{"detail": "", "channel": "活动鲜花"}]', NULL, 25, NULL, NULL, NULL, NULL, 'assets/flower-images/辉似朝阳.webp', true),
  ('迎春花', '迎春花', '花坊', '[{"detail": "花坊", "channel": "花坊"}]', '21:20:00', 14, '花坊币', 2880.0, NULL, NULL, 'assets/flower-images/迎春花.webp', false),
  ('连理双枝', '连理双枝', '活动鲜花', '[{"detail": "", "channel": "活动鲜花"}]', NULL, 25, NULL, NULL, NULL, NULL, 'assets/flower-images/连理双枝.webp', true),
  ('郁粉兜兰', '郁粉兜兰', 'VIP商店', '[{"detail": "", "channel": "VIP商店"}]', NULL, 14, NULL, NULL, NULL, NULL, 'assets/flower-images/郁粉兜兰.webp', true),
  ('酒红山月桂', '酒红山月桂', '鲜花礼包', '[{"detail": "", "channel": "鲜花礼包"}]', NULL, 23, '元', 28.0, NULL, NULL, 'assets/flower-images/酒红山月桂.webp', true),
  ('重瓣紫灯花', '重瓣紫灯花', '花灵', '[{"detail": "", "channel": "花灵"}]', NULL, 23, '月令币', 3999.0, NULL, '桃山灵泽', 'assets/flower-images/重瓣紫灯花.webp', true),
  ('金桂衔灯', '金桂衔灯', '活动鲜花', '[{"detail": "", "channel": "活动鲜花"}]', NULL, 25, NULL, NULL, NULL, NULL, 'assets/flower-images/金桂衔灯.webp', true),
  ('金橙海葵', '金橙海葵', '花坊', '[{"detail": "花坊", "channel": "花坊"}]', NULL, 21, '花坊币', 5880.0, '145', '水舞苍穹', 'assets/flower-images/金橙海葵.webp', false),
  ('金玉良缘', '金玉良缘', '活动鲜花', '[{"detail": "", "channel": "活动鲜花"}]', NULL, 23, '元', 28.0, NULL, '活动专属（无花瓶关联）', 'assets/flower-images/金玉良缘.webp', true),
  ('金白德鸢', '金白德鸢', '花坊', '[{"detail": "花坊", "channel": "花坊"}]', NULL, 21, '花坊币', 5880.0, '130', '碧荷灵篮', 'assets/flower-images/金白德鸢.webp', false),
  ('金盏菊', '金盏菊', '等级花', '[{"detail": "等级花", "channel": "等级花"}]', '14:40:00', 9, NULL, NULL, '等级解锁', '基础等级花（无花瓶关联）', 'assets/flower-images/金盏菊.webp', false),
  ('金盏蜀葵花', '金盏蜀葵花', '花坊', '[{"detail": "花坊", "channel": "花坊"}]', NULL, 14, '花坊币', 2880.0, '95', '翠羽芳华', 'assets/flower-images/金盏蜀葵花.webp', false),
  ('金缠腰', '金缠腰', '活动鲜花', '[{"detail": "国色芳华 （第三期）", "channel": "活动鲜花"}]', NULL, 25, NULL, NULL, '活动获取', '活动专属（无花瓶关联）', 'assets/flower-images/金缠腰.webp', false),
  ('金钟连翘', '金钟连翘', '星河映蕊', '[{"detail": "星河映蕊", "channel": "星河映蕊"}]', NULL, 14, NULL, NULL, '抽取获取', '绿意翠瓶', 'assets/flower-images/金钟连翘.webp', false),
  ('金鳞飞渡', '金鳞飞渡', '累计充值', '[{"detail": "累计充值", "channel": "累计充值"}]', NULL, 30, NULL, NULL, '充值奖励', '充值奖励（无花瓶关联）', 'assets/flower-images/金鳞飞渡.webp', false),
  ('铃兰', '铃兰', '等级花', '[{"detail": "等级花", "channel": "等级花"}]', '01:50:00', 9, NULL, NULL, '等级解锁', '基础等级花（无花瓶关联）', 'assets/flower-images/铃兰.webp', false),
  ('银白翠珠', '银白翠珠', '花坊', '[{"detail": "花坊", "channel": "花坊"}]', NULL, 14, '花坊币', 3880.0, NULL, NULL, 'assets/flower-images/银白翠珠.webp', false),
  ('银白耀星花', '银白耀星花', '花灵', '[{"detail": "", "channel": "花灵"}]', NULL, 23, '月令币', 3999.0, NULL, '桃山灵泽', 'assets/flower-images/银白耀星花.webp', true),
  ('银白雪柳', '银白雪柳', '礼包花圃', '[{"detail": "礼包花圃", "channel": "礼包花圃"}]', NULL, 23, NULL, NULL, '购齐(粉樱蝶舞玫瑰 橙黄虞美人 粉黛德鸢)赠送', '绿意翠瓶', 'assets/flower-images/银白雪柳.webp', false),
  ('阳月·芙香盈袖', '阳月·芙香盈袖', '花灵', '[{"detail": "花灵", "channel": "花灵"}]', NULL, 28, '月令币', 3999.0, NULL, '金盏生芳', 'assets/flower-images/阳月·芙香盈袖.webp', false),
  ('雅梨黄棣棠', '雅梨黄棣棠', '花灵', '[{"detail": "花灵", "channel": "花灵"}]', NULL, 23, '月令币', 3999.0, NULL, '金盏生芳', 'assets/flower-images/雅梨黄棣棠.webp', false),
  ('雅致西风莲', '雅致西风莲', '花灵', '[{"detail": "花灵", "channel": "花灵"}]', NULL, 23, '月令币', 3999.0, NULL, '紫藤流韵', 'assets/flower-images/雅致西风莲.webp', false),
  ('雏菊', '雏菊', '等级花', '[{"detail": "等级花", "channel": "等级花"}]', '07:20:00', 9, NULL, NULL, '等级解锁', '基础等级花（无花瓶关联）', 'assets/flower-images/雏菊.webp', false),
  ('雪白荼蘼花', '雪白荼蘼花', '等级花', '[{"detail": "等级花", "channel": "等级花"}]', NULL, 9, NULL, NULL, '等级解锁', '基础等级花（无花瓶关联）', 'assets/flower-images/雪白荼蘼花.webp', false),
  ('雪缨大花芙蓉', '雪缨大花芙蓉', '花之密令', '[{"detail": "", "channel": "花之密令"}]', NULL, 23, NULL, NULL, NULL, NULL, 'assets/flower-images/雪缨大花芙蓉.webp', true),
  ('雾白香豌豆', '雾白香豌豆', '花坊', '[{"detail": "", "channel": "花坊"}]', NULL, 14, NULL, NULL, '活动获取', '活动专属（无花瓶关联）', 'assets/flower-images/雾白香豌豆.webp', false),
  ('雾粉千鸟花', '雾粉千鸟花', '活动鲜花', '[{"detail": "(芳庭花宴)", "channel": "活动鲜花"}]', NULL, 14, NULL, NULL, '活动获取', '活动专属（无花瓶关联）', 'assets/flower-images/雾粉千鸟花.webp', false),
  ('雾粉麦冬花', '雾粉麦冬花', '花坊', '[{"detail": "花坊", "channel": "花坊"}]', NULL, 21, '花坊币', 4880.0, '130', '蓝心涟漪', 'assets/flower-images/雾粉麦冬花.webp', false),
  ('雾紫堇兰', '雾紫堇兰', '鲜花礼包', '[{"detail": "", "channel": "鲜花礼包"}]', NULL, 23, '元', 28.0, NULL, NULL, 'assets/flower-images/雾紫堇兰.webp', true),
  ('霁澜牡丹', '霁澜牡丹', '礼包花圃', '[{"detail": "礼包花圃", "channel": "礼包花圃"}]', NULL, 25, '元', 68.0, NULL, '翠金留芳', 'assets/flower-images/霁澜牡丹.webp', false),
  ('霁粉山月桂', '霁粉山月桂', '鲜花礼包', '[{"detail": "", "channel": "鲜花礼包"}]', NULL, 23, NULL, NULL, NULL, NULL, 'assets/flower-images/霁粉山月桂.webp', true),
  ('霁蓝紫藤花', '霁蓝紫藤花', '礼包花圃', '[{"detail": "礼包花圃", "channel": "礼包花圃"}]', NULL, 23, '元', 28.0, NULL, '镜华锦匣', 'assets/flower-images/霁蓝紫藤花.webp', false),
  ('霁蓝董兰', '霁蓝董兰', '花之密令', '[{"detail": "", "channel": "花之密令"}]', NULL, 23, NULL, NULL, NULL, NULL, 'assets/flower-images/霁蓝董兰.webp', true),
  ('霓光映树', '霓光映树', '活动鲜花', '[{"detail": "(欢雪颂冬)", "channel": "活动鲜花"}]', NULL, 25, NULL, NULL, '活动获取', '活动专属（无花瓶关联）', 'assets/flower-images/霓光映树.webp', false),
  ('霓粉垂丝茉莉', '霓粉垂丝茉莉', '礼包花圃', '[{"detail": "", "channel": "礼包花圃"}]', NULL, 23, '元', 28.0, NULL, '绮花幻蝶', 'assets/flower-images/霓粉垂丝茉莉.webp', true),
  ('霓粉花菱草', '霓粉花菱草', '花之密令', '[{"detail": "", "channel": "花之密令"}]', NULL, 14, NULL, NULL, NULL, NULL, 'assets/flower-images/霓粉花菱草.webp', true),
  ('霓羽翠云', '霓羽翠云', '花灵商店', '[{"detail": "", "channel": "花灵商店"}]', NULL, 25, NULL, NULL, NULL, NULL, 'assets/flower-images/霓羽翠云.webp', true),
  ('霜白垂筒花', '霜白垂筒花', '花坊', '[{"detail": "", "channel": "花坊"}]', NULL, 14, NULL, NULL, '活动获取', '活动专属（无花瓶关联）', 'assets/flower-images/霜白垂筒花.webp', false),
  ('霜白婆婆纳', '霜白婆婆纳', '花坊', '[{"detail": "", "channel": "花坊"}]', NULL, 14, NULL, NULL, '活动获取', '活动专属（无花瓶关联）', 'assets/flower-images/霜白婆婆纳.webp', false),
  ('霜白海葵', '霜白海葵', '礼包花圃', '[{"detail": "礼包花圃", "channel": "礼包花圃"}]', NULL, 23, NULL, NULL, '购齐(姑苏雨蒙 黄莺蔷薇花 藕粉长寿花)赠送', '水舞苍穹', 'assets/flower-images/霜白海葵.webp', false),
  ('霜白谷鸢尾', '霜白谷鸢尾', 'VIP商店', '[{"detail": "VIP商店", "channel": "VIP商店"}]', NULL, 14, NULL, NULL, 'VIP获取', 'VIP专属（无花瓶关联）', 'assets/flower-images/霜白谷鸢尾.webp', false),
  ('霜色麦冬花', '霜色麦冬花', '礼包花圃', '[{"detail": "礼包花圃", "channel": "礼包花圃"}]', NULL, 23, '元', 28.0, NULL, '蓝心涟漪', 'assets/flower-images/霜色麦冬花.webp', false),
  ('霜蓝玉簪花', '霜蓝玉簪花', '花坊', '[{"detail": "花坊", "channel": "花坊"}]', NULL, 14, '花坊币', 3880.0, NULL, '枯木逢春', 'assets/flower-images/霜蓝玉簪花.webp', false),
  ('霞晖帝王花', '霞晖帝王花', '礼包花圃', '[{"detail": "", "channel": "礼包花圃"}]', NULL, 25, '元', 68.0, NULL, '镜华锦匣', 'assets/flower-images/霞晖帝王花.webp', false),
  ('霞粉铁线莲', '霞粉铁线莲', '活动鲜花', '[{"detail": "(官方活动)", "channel": "活动鲜花"}]', '18:40:00', 14, NULL, NULL, '活动获取', '活动专属（无花瓶关联）', 'assets/flower-images/霞粉铁线莲.webp', false),
  ('青丝杨柳', '青丝杨柳', '花灵', '[{"detail": "花灵", "channel": "花灵"}]', NULL, 23, '月令币', 3999.0, NULL, '绿意翠瓶', 'assets/flower-images/青丝杨柳.webp', false),
  ('青山银桂', '青山银桂', '花坊', '[{"detail": "花坊", "channel": "花坊"}]', NULL, 21, '花坊币', 5880.0, '145', '流波花樽', 'assets/flower-images/青山银桂.webp', false),
  ('青璃火焰花', '青璃火焰花', '活动鲜花', '[{"detail": "", "channel": "活动鲜花"}]', NULL, 25, NULL, NULL, '活动获取', '活动专属（无花瓶关联）', 'assets/flower-images/青璃火焰花.webp', true),
  ('青碧华珊', '青碧华珊', '累计充值', '[{"detail": "累计充值", "channel": "累计充值"}]', NULL, 23, NULL, NULL, '充值奖励', '充值奖励（无花瓶关联）', 'assets/flower-images/青碧华珊.webp', false),
  ('青绿四照花', '青绿四照花', '活动鲜花', '[{"detail": "", "channel": "活动鲜花"}]', NULL, 14, NULL, NULL, NULL, NULL, 'assets/flower-images/青绿四照花.webp', true),
  ('青花瓷牡丹菊', '青花瓷牡丹菊', '鲜花礼包', '[{"detail": "", "channel": "鲜花礼包"}]', NULL, 25, '元', 68.0, NULL, '竹韵花影', 'assets/flower-images/青花瓷牡丹菊.webp', true),
  ('非洲菊', '非洲菊', '等级花', '[{"detail": "等级花", "channel": "等级花"}]', '16:00:00', 9, NULL, NULL, '等级解锁', '基础等级花（无花瓶关联）', 'assets/flower-images/非洲菊.webp', false),
  ('风铃花', '风铃花', '等级花', '[{"detail": "等级花", "channel": "等级花"}]', '17:20:00', 9, NULL, NULL, '等级解锁', '基础等级花（无花瓶关联）', 'assets/flower-images/风铃花.webp', false),
  ('飞花似梦', '飞花似梦', '活动鲜花', '[{"detail": "", "channel": "活动鲜花"}]', NULL, 28, NULL, NULL, '活动获取', '活动专属（无花瓶关联）', 'assets/flower-images/飞花似梦.webp', true),
  ('飞黄玉兰', '飞黄玉兰', '礼包花圃', '[{"detail": "礼包花圃", "channel": "礼包花圃"}]', NULL, 23, '元', 28.0, NULL, '流波花樽', 'assets/flower-images/飞黄玉兰.webp', false),
  ('香槟洋桔梗', '香槟洋桔梗', '等级花', '[{"detail": "等级花", "channel": "等级花"}]', '1900/1/1 05:20:00', 9, NULL, NULL, '等级解锁', '基础等级花（无花瓶关联）', 'assets/flower-images/香槟洋桔梗.webp', false),
  ('香槟玫瑰', '香槟玫瑰', '星河映蕊', '[{"detail": "星河映蕊", "channel": "星河映蕊"}]', NULL, 21, NULL, NULL, '抽取获取', '蓝心涟漪', 'assets/flower-images/香槟玫瑰.webp', false),
  ('香水百合', '香水百合', '花坊', '[{"detail": "花坊", "channel": "花坊"}]', '20:00:00', 14, '花坊币', 3880.0, NULL, NULL, 'assets/flower-images/香水百合.webp', false),
  ('香紫兔狸藻', '香紫兔狸藻', '活动鲜花', '[{"detail": "", "channel": "活动鲜花"}]', NULL, 14, NULL, NULL, '活动获取', '坠月浮星', 'assets/flower-images/香紫兔狸藻.webp', true),
  ('馥香花饼', '馥香花饼', '活动鲜花', '[{"detail": "(芳庭花宴)", "channel": "活动鲜花"}]', NULL, 25, NULL, NULL, '活动获取', '活动专属（无花瓶关联）', 'assets/flower-images/馥香花饼.webp', false),
  ('马上有福', '马上有福', '活动鲜花', '[{"detail": "(迎春接福)", "channel": "活动鲜花"}]', NULL, 25, NULL, NULL, '活动获取', '活动专属（无花瓶关联）', 'assets/flower-images/马上有福.webp', false),
  ('马上有财', '马上有财', '活动鲜花', '[{"detail": "(迎春接福)", "channel": "活动鲜花"}]', NULL, 25, NULL, NULL, '活动获取', '活动专属（无花瓶关联）', 'assets/flower-images/马上有财.webp', false),
  ('马上柿橙', '马上柿橙', '活动鲜花', '[{"detail": "(迎春接福)", "channel": "活动鲜花"}]', NULL, 25, NULL, NULL, '活动获取', '活动专属（无花瓶关联）', 'assets/flower-images/马上柿橙.webp', false),
  ('鱼灯映岁', '鱼灯映岁', '活动鲜花', '[{"detail": "(灯游逐宵)", "channel": "活动鲜花"}]', NULL, 25, NULL, NULL, '活动获取', '活动专属（无花瓶关联）', 'assets/flower-images/鱼灯映岁.webp', false),
  ('鸢花芳集', '鸢花芳集', '礼包花圃', '[{"detail": "", "channel": "礼包花圃"}]', NULL, 25, '元', 68.0, NULL, '翠羽芳华', 'assets/flower-images/鸢花芳集.webp', false),
  ('鸳鸯茉莉', '鸳鸯茉莉', '花坊', '[{"detail": "花坊", "channel": "花坊"}]', NULL, 21, '花坊币', 4880.0, '130', '花影流光', 'assets/flower-images/鸳鸯茉莉.webp', false),
  ('鹅黄报春花', '鹅黄报春花', '花坊', '[{"detail": "", "channel": "花坊"}]', NULL, 14, '花坊币', 3880.0, NULL, '枯木逢春', 'assets/flower-images/鹅黄报春花.webp', false),
  ('鹅黄铁筷花', '鹅黄铁筷花', '花坊', '[{"detail": "花坊", "channel": "花坊"}]', NULL, 21, '花坊币', 5880.0, '145', '雪梅迎春', 'assets/flower-images/鹅黄铁筷花.webp', false),
  ('鹊影芳扇', '鹊影芳扇', '鲜花礼包', '[{"detail": "鲜花礼包", "channel": "鲜花礼包"}]', NULL, 25, '元', 68.0, NULL, '翠羽芳华', 'assets/flower-images/鹊影芳扇.webp', false),
  ('鹤寄星河', '鹤寄星河', '活动鲜花', '[{"detail": "(折纸寄愿)", "channel": "活动鲜花"}]', NULL, 25, NULL, NULL, '活动获取', '活动专属（无花瓶关联）', 'assets/flower-images/鹤寄星河.webp', false),
  ('鹤望兰', '鹤望兰', '等级花', '[{"detail": "等级花", "channel": "等级花"}]', '14:00:00', 9, NULL, NULL, '等级解锁', '基础等级花（无花瓶关联）', 'assets/flower-images/鹤望兰.webp', false),
  ('黄澄蛾蝶花', '黄澄蛾蝶花', '礼包花圃', '[{"detail": "", "channel": "礼包花圃"}]', NULL, 23, NULL, NULL, NULL, NULL, 'assets/flower-images/黄澄蛾蝶花.webp', true),
  ('黄焰', '黄焰', '活动鲜花', '[{"detail": "", "channel": "活动鲜花"}]', NULL, 23, NULL, NULL, '活动获取', '翠羽芳华', 'assets/flower-images/黄焰.webp', true),
  ('黄玫瑰', '黄玫瑰', '等级花', '[{"detail": "等级花", "channel": "等级花"}]', '09:20:00', 9, NULL, NULL, '等级解锁', '基础等级花（无花瓶关联）', 'assets/flower-images/黄玫瑰.webp', false),
  ('黄白酢浆草', '黄白酢浆草', '花之密令', '[{"detail": "花之密令", "channel": "花之密令"}]', NULL, 14, NULL, NULL, '密令获取', '竹韵花影', 'assets/flower-images/黄白酢浆草.webp', false),
  ('黄白醡浆草', '黄白醡浆草', '花之密令', '[{"detail": "", "channel": "花之密令"}]', NULL, 14, NULL, NULL, '密令获取', '竹韵花影', 'assets/flower-images/黄白醡浆草.webp', true),
  ('黄百合', '黄百合', '等级花', '[{"detail": "等级花", "channel": "等级花"}]', '02:27:00', 9, NULL, NULL, '等级解锁', '基础等级花（无花瓶关联）', 'assets/flower-images/黄百合.webp', false),
  ('黄色丁香花', '黄色丁香花', '等级花', '[{"detail": "等级花", "channel": "等级花"}]', '1900/1/1 04:40:00', 9, NULL, NULL, '等级解锁', '基础等级花（无花瓶关联）', 'assets/flower-images/黄色丁香花.webp', false),
  ('黄色海棠花', '黄色海棠花', '花坊', '[{"detail": "花坊", "channel": "花坊"}]', NULL, 14, '花坊币', 3880.0, '99', '翠金留芳', 'assets/flower-images/黄色海棠花.webp', false),
  ('黄莺蔷薇花', '黄莺蔷薇花', '礼包花圃', '[{"detail": "礼包花圃", "channel": "礼包花圃"}]', NULL, 23, '元', 28.0, NULL, '浮雕瓷壶', 'assets/flower-images/黄莺蔷薇花.webp', false),
  ('黄郁金香', '黄郁金香', '等级花', '[{"detail": "等级花", "channel": "等级花"}]', '03:40:00', 9, NULL, NULL, '等级解锁', '基础等级花（无花瓶关联）', 'assets/flower-images/黄郁金香.webp', false),
  ('黄马蹄莲', '黄马蹄莲', '等级花', '[{"detail": "等级花", "channel": "等级花"}]', '18:00:00', 9, NULL, NULL, '等级解锁', '基础等级花（无花瓶关联）', 'assets/flower-images/黄马蹄莲.webp', false),
  ('黑曜大丽花', '黑曜大丽花', '花坊', '[{"detail": "花坊", "channel": "花坊"}]', NULL, 21, '花坊币', 4880.0, '130', '幽蓝瓷瓶', 'assets/flower-images/黑曜大丽花.webp', false),
  ('黑蕊白银莲', '黑蕊白银莲', '花坊', '[{"detail": "花坊", "channel": "花坊"}]', NULL, 21, '花坊币', 5880.0, '150', '翠金留芳', 'assets/flower-images/黑蕊白银莲.webp', false),
  ('黛紫洋紫荆', '黛紫洋紫荆', '花灵', '[{"detail": "花灵", "channel": "花灵"}]', NULL, 23, '月令币', 3999.0, NULL, '流波花樽', 'assets/flower-images/黛紫洋紫荆.webp', false),
  ('黛紫玉兰', '黛紫玉兰', '礼包花圃', '[{"detail": "礼包花圃", "channel": "礼包花圃"}]', NULL, 23, '元', 28.0, NULL, '流波花樽', 'assets/flower-images/黛紫玉兰.webp', false),
  ('黛紫绿绒蒿', '黛紫绿绒蒿', '礼包花圃', '[{"detail": "礼包花圃", "channel": "礼包花圃"}]', NULL, 23, NULL, NULL, '购齐(仙女散花 幻紫铁线莲 飞黄玉兰)赠送', '绿意翠瓶', 'assets/flower-images/黛紫绿绒蒿.webp', false),
  ('黛紫虞美人', '黛紫虞美人', '礼包花圃', '[{"detail": "礼包花圃", "channel": "礼包花圃"}]', NULL, 23, '元', 28.0, NULL, '竹韵花影', 'assets/flower-images/黛紫虞美人.webp', false),
  ('龙舟竞渡', '龙舟竞渡', '活动鲜花', '[{"detail": "", "channel": "活动鲜花"}]', NULL, 25, NULL, NULL, '活动获取', '活动专属（无花瓶关联）', 'assets/flower-images/龙舟竞渡.webp', true)
on conflict (id) do update set name = excluded.name, competition_score = excluded.competition_score, primary_channel = excluded.primary_channel, sources = excluded.sources, currency = excluded.currency, price = excluded.price, order_exp = excluded.order_exp, vase = excluded.vase, image_url = excluded.image_url;


-- ========== Realtime：把业务表加入 supabase_realtime publication（幂等） ==========
-- 说明：Supabase 项目创建时仅对当时存在的表启用 Realtime；用 SQL 新建的表需手动加入，
-- 否则 postgres_changes 收不到事件、前端实时刷新不生效。
do $$
declare _t text;
begin
  foreach _t in array array[
    'public.guilds','public.guild_members','public.flowers','public.flower_ownership',
    'public.competition_tasks','public.competition_logs'
  ] loop
    if not exists (
      select 1 from pg_publication_tables
      where pubname = 'supabase_realtime'
        and schemaname = 'public'
        and tablename = split_part(_t, '.', 2)
    ) then
      execute 'alter publication supabase_realtime add table ' || _t;
    end if;
  end loop;
end $$;
