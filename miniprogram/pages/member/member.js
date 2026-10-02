// 成员面板：我的（成员卡列表）+ 全体聚合（每花一行显示各成员状态，只读）
const app = getApp();

Page({
  data: {
    me: null,
    mode: 'mine',           // mine / agg
    aggFilter: 'all',       // all/have/cult/none
    members: [],            // 成员卡数据（mine 模式）
    aggFlowers: [],         // 聚合花列表（agg 模式）
    aggCount: '0/0'
  },

  onLoad() {
    if (!app.globalData.me) {
      wx.reLaunch({ url: '/pages/login/login' });
      return;
    }
    this.setData({ me: app.globalData.me });
    this.refresh();
    this._loaded = true;
  },

  async refresh() {
    await app.loadAll();
    this.renderMine();
    this.renderAgg();
  },

  onShow() {
    // 从别处返回时刷新共享数据
    if (this._loaded && app.globalData.flowers.length) {
      this.refresh();
    }
  },

  switchMode(e) {
    this.setData({ mode: e.currentTarget.dataset.m });
    if (this.data.mode === 'agg') this.renderAgg();
  },

  // ===== 我的：成员卡片 =====
  renderMine() {
    const g = app.globalData;
    const members = g.members.map(m => {
      let own = 0, cult = 0;
      Object.keys(g.ownersIndex).forEach(fid => {
        if ((g.ownersIndex[fid] || []).indexOf(m.id) !== -1) own++;
      });
      Object.keys(g.cultIndex).forEach(fid => {
        if ((g.cultIndex[fid] || []).indexOf(m.id) !== -1) cult++;
      });
      const isMe = m.id === g.me.id;
      return {
        id: m.id,
        name: m.name,
        role: m.role || '成员',
        own, cult,
        total: own + cult,
        isMe,
        meTag: isMe ? '我' : ''
      };
    });
    this.setData({ members });
  },

  // ===== 全体聚合 =====
  setAggFilter(e) {
    this.setData({ aggFilter: e.currentTarget.dataset.f });
    this.renderAgg();
  },

  renderAgg() {
    const g = app.globalData;
    const filt = this.data.aggFilter;
    const list = g.flowers.filter(f => {
      const ownIds = g.ownersIndex[f.id] || [];
      const cultIds = g.cultIndex[f.id] || [];
      if (filt === 'have' && !ownIds.length) return false;
      if (filt === 'cult' && !cultIds.length) return false;
      if (filt === 'none' && (ownIds.length || cultIds.length)) return false;
      return true;
    }).sort((a, b) => b.competition_score - a.competition_score);

    const rows = list.map(f => {
      const badges = g.members.map(m => {
        if ((g.ownersIndex[f.id] || []).indexOf(m.id) !== -1) return { name: m.name, cls: 'own', ch: '✓' };
        if ((g.cultIndex[f.id] || []).indexOf(m.id) !== -1) return { name: m.name, cls: 'cult', ch: '🌱' };
        return null;
      }).filter(Boolean);
      return {
        id: f.id,
        name: f.name,
        score: f.competition_score || '',
        badges,
        none: !badges.length
      };
    });
    this.setData({ aggFlowers: rows, aggCount: list.length + '/' + g.flowers.length });
  },

  logout() {
    wx.showModal({
      title: '退出登录',
      content: '确定退出当前账号吗？',
      success: r => {
        if (r.confirm) {
          app.globalData.me = null;
          wx.removeStorageSync('fb_me');
          wx.reLaunch({ url: '/pages/login/login' });
        }
      }
    });
  }
});
