// 竞赛任务：添加任务/勾选完成/操作日志
const app = getApp();
const sb = app.globalData.sb;

Page({
  data: {
    tab: 'tasks',           // tasks/logs
    input: '',
    tasks: [],
    logs: [],
    loading: true
  },

  onLoad() {
    if (!app.globalData.me) {
      wx.reLaunch({ url: '/pages/login/login' });
      return;
    }
    this.refresh();
  },

  onShow() {
    if (this._loaded) this.refresh();
  },

  async refresh() {
    const ok = await app.loadTasks();
    this._loaded = true;
    if (ok) {
      const tasks = app.globalData.tasks.map(t => ({
        id: t.id,
        title: t.title,
        done: !!t.done,
        created_by: t.created_by || ''
      }));
      const logs = app.globalData.logs.slice().reverse().map(l => ({
        text: l.description,
        at: (l.created_at || '').replace('T', ' ').slice(5, 16)
      }));
      this.setData({ tasks, logs, loading: false });
    } else {
      this.setData({ loading: false });
    }
  },

  switchTab(e) {
    this.setData({ tab: e.currentTarget.dataset.t });
  },

  onInput(e) {
    this.setData({ input: e.detail.value });
  },

  async addTask() {
    const title = this.data.input.trim();
    if (!title) { wx.showToast({ title: '请输入任务内容', icon: 'none' }); return; }
    const me = app.globalData.me;
    try {
      await sb.insert('competition_tasks', {
        guild_id: app.globalData.config.GUILD_ID,
        title,
        done: false,
        created_by: me.id
      });
      this.setData({ input: '' });
      await this.refresh();
    } catch (e) {
      wx.showToast({ title: '添加失败：' + (e.message || e), icon: 'none' });
    }
  },

  async toggleTask(e) {
    const id = e.currentTarget.dataset.id;
    const done = e.currentTarget.dataset.done === 'true';
    const me = app.globalData.me;
    try {
      await sb.update('competition_tasks', { done: !done }, { id });
      await sb.insert('competition_logs', {
        guild_id: app.globalData.config.GUILD_ID,
        description: (done ? '取消完成' : '完成任务') + '：' + e.currentTarget.dataset.title,
        member_id: me.id
      });
      await this.refresh();
    } catch (err) {
      wx.showToast({ title: '操作失败：' + (err.message || err), icon: 'none' });
    }
  }
});
