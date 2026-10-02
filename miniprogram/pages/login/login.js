// 登录页：昵称下拉 + 密码（sha256 与 guild_members.password_hash 比对）
const app = getApp();
const sb = app.globalData.sb;

Page({
  data: {
    guildName: '花册公会',
    members: [],
    memberNames: [],
    memberIdx: -1,
    password: '',
    error: '',
    loading: false
  },

  onLoad() {
    if (app.globalData.me) {
      wx.reLaunch({ url: '/pages/flowers/flowers' });
      return;
    }
    this.fetchMembers();
  },

  async fetchMembers() {
    try {
      const guild = await sb.get('guilds', { select: 'name,id', id: app.globalData.config.GUILD_ID });
      const members = await sb.get('guild_members', {
        select: 'id,name,role,password_hash', guild_id: app.globalData.config.GUILD_ID, status: 'active', order: 'created_at'
      });
      if (guild && guild[0]) this.setData({ guildName: guild[0].name });
      this.setData({
        members: members || [],
        memberNames: (members || []).map(m => m.name + (m.role ? '（' + m.role + '）' : ''))
      });
    } catch (e) {
      this.setData({ error: '成员加载失败：' + (e.message || e) });
    }
  },

  onMemberChange(e) {
    this.setData({ memberIdx: Number(e.detail.value), error: '' });
  },

  onPasswordInput(e) {
    this.setData({ password: e.detail.value, error: '' });
  },

  async onLogin() {
    const idx = this.data.memberIdx;
    if (idx < 0) { this.setData({ error: '请先选择昵称' }); return; }
    if (!this.data.password) { this.setData({ error: '请输入密码' }); return; }
    const m = this.data.members[idx];
    if (!m.password_hash) { this.setData({ error: '该成员未设置密码，请联系管理员' }); return; }

    this.setData({ loading: true, error: '' });
    const hash = sb.sha256Hex(this.data.password);
    if (hash !== m.password_hash) {
      this.setData({ loading: false, error: '密码错误，请重试' });
      return;
    }
    const me = { id: m.id, name: m.name, role: m.role };
    app.globalData.me = me;
    wx.setStorageSync('fb_me', me);
    wx.reLaunch({ url: '/pages/flowers/flowers' });
  }
});
