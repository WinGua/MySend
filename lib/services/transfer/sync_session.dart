/// 服务端单槽同步会话。同步任务同时占用两端，固定设备顺序避免交叉死锁。
/// 租约用于回收进程退出遗留的会话；请求执行期间绝不回收。
class SyncSession {
  final void Function(String task, String reason)? onEnded;
  final Duration lease;
  final DateTime Function() now;
  String? _owner;
  String? _task;
  DateTime? _deadline;
  int _active = 0;
  bool _releasing = false;
  String? _endingReason;
  String? get task {
    _expire();
    return _task;
  }

  String? get owner {
    _expire();
    return _owner;
  }

  SyncSession(
      {this.lease = const Duration(seconds: 45),
      DateTime Function()? now,
      this.onEnded})
      : now = now ?? DateTime.now;

  void _expire() {
    if (_active == 0 &&
        _deadline != null &&
        (_releasing || !now().isBefore(_deadline!))) {
      clear(reason: _endingReason ?? (_releasing ? '同步未正常结束' : '连接超时，同步已中断'));
    }
  }

  bool get busy {
    _expire();
    return _task != null;
  }

  bool matches(String owner, String task) {
    _expire();
    return !_releasing && _owner == owner && _task == task;
  }

  bool acquire(String owner, String task) {
    _expire();
    if (owner.isEmpty ||
        task.isEmpty ||
        task.length > 128 ||
        (_task != null && !matches(owner, task))) return false;
    _owner = owner;
    _task = task;
    _deadline = now().add(lease);
    return true;
  }

  bool renew(String owner, String task) {
    if (!matches(owner, task)) return false;
    _deadline = now().add(lease);
    return true;
  }

  bool enter(String owner, String task) {
    if (!renew(owner, task)) return false;
    _active++;
    return true;
  }

  void leave() {
    if (_active <= 0) throw StateError('同步活动请求计数不匹配');
    _active--;
    if (!_releasing) _deadline = now().add(lease);
    _expire();
  }

  void release(String owner, String task) {
    if (!matches(owner, task)) return;
    _releasing = true;
    _expire();
  }

  bool cancel(String owner, String task) {
    if (!matches(owner, task)) return false;
    _releasing = true;
    _endingReason = '同步已取消';
    _expire();
    return true;
  }

  void clear({String reason = '同步连接已断开'}) {
    if (_active > 0) {
      _releasing = true;
      _endingReason = reason;
      return;
    }
    final task = _task;
    _owner = null;
    _task = null;
    _deadline = null;
    _releasing = false;
    _endingReason = null;
    if (task != null) onEnded?.call(task, reason);
  }
}
