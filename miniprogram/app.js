// app.js 小程序入口
const config = require('./utils/config.js');
const sb = require('./utils/supabase.js');

App({
  globalData: {
    config,
    sb,
    me: null,          // {id, name, role}
    guild: null,       // 公会信息
    members: [],       // 成员列表
    flowers: [],       // 花朵列表（含拥有关系聚合）
    ownersIndex: {},   // flower_id -> [member_id]（已拥有）
    cultIndex: {},     // flower_id -> [member_id]（待培育）
    tasks: [],
    logs: []
  },

  onLaunch() {
    // 恢复会话
    const saved = wx.getStorageSync('fb_me');
    if (saved) {
      this.globalData.me = saved;
    }
    if (!config.SUPABASE_URL || config.SUPABASE_URL.indexOf('你的项目') !== -1) {
      wx.showModal({
        title: '未配置后端',
        content: '请先在 miniprogram/utils/config.js 中填入你的 Supabase 项目 URL 与 anon key（详见 README.md）。',
        showCancel: false
      });
    }
  },

  async loadAll() {
    const g = this.globalData;
    try {
      const [home, extra, guild, members] = await Promise.all([
        sb.rpc('get_guild_home_data'),
        sb.rpc('get_guild_extra_data'),
        sb.get('guilds', { select: '*', id: config.GUILD_ID }),
        sb.get('guild_members', { select: '*', guild_id: config.GUILD_ID, status: 'active', order: 'created_at' })
      ]);
      g.guild = guild && guild[0] ? guild[0] : { name: '（公会名称待设置）' };
      g.members = members || [];
      g.ownersIndex = {};
      g.cultIndex = {};
      (home.flowers || []).forEach(hf => {
        g.ownersIndex[hf.id] = (hf.owners || []).map(o => o.member_id);
      });
      Object.entries(extra.cultivation || {}).forEach(([fid, mids]) => { g.cultIndex[fid] = mids; });
      g.flowers = (extra.flowers || []).map(f => {
        const hf = (home.flowers || []).find(h => h.id === f.id) || {};
        return Object.assign({}, f, { owners: hf.owners || [], cultivation: extra.cultivation[f.id] || [] });
      });
      return true;
    } catch (e) {
      console.error('loadAll failed', e);
      return false;
    }
  },

  async loadTasks() {
    const g = this.globalData;
    try {
      const [t, l] = await Promise.all([
        sb.get('competition_tasks', { select: '*', guild_id: config.GUILD_ID }),
        sb.get('competition_logs', { select: '*', guild_id: config.GUILD_ID })
      ]);
      g.tasks = t || [];
      g.logs = l || [];
      return true;
    } catch (e) {
      console.error('loadTasks failed', e);
      return false;
    }
  },

  imgUrl(imageUrl) {
    // 相对路径 -> 拼接 IMG_BASE；无图返回空
    if (!imageUrl) return '';
    if (/^https?:\/\//.test(imageUrl)) return imageUrl;
    const base = config.IMG_BASE;
    if (!base) return '';
    return base.replace(/\/+$/, '') + '/' + imageUrl.replace(/^\/+/, '');
  }
});
