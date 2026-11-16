import 'package:flutter_test/flutter_test.dart';
import 'package:mysend/services/transfer/sync_session.dart';
import 'package:mysend/models/remote_sync_state.dart';

void main() {
  test('过期会话回收，迟到的 release 不会释放新任务', () {
    var now = DateTime.utc(2026);
    final session = SyncSession(now: () => now);
    expect(session.acquire('a', 'old'), isTrue);
    expect(session.acquire('b', 'new'), isFalse);
    now = now.add(const Duration(seconds: 46));
    expect(session.acquire('b', 'new'), isTrue);
    session.release('a', 'old');
    expect(session.matches('b', 'new'), isTrue);
  });
  test('安静断线的租约过期会结束接收端窗口状态', () {
    var now = DateTime.utc(2026);
    final progress = RemoteSyncTracker();
    final session = SyncSession(now: () => now, onEnded: progress.interrupted);
    session.acquire('a', 'task');
    progress.begin(task: 'task', peerName: '电脑', mappingName: '音乐', total: 1);
    now = now.add(const Duration(seconds: 46));
    expect(session.busy, isFalse);
    expect(progress.value!.finished, isTrue);
    expect(progress.value!.error, contains('超时'));
    progress.dispose();
  });
  test('请求执行期间不会过期或提前释放', () {
    var now = DateTime.utc(2026);
    final session = SyncSession(now: () => now);
    session.acquire('a', 'task');
    expect(session.enter('a', 'task'), isTrue);
    now = now.add(const Duration(minutes: 15));
    expect(session.acquire('b', 'other'), isFalse);
    session.release('a', 'task');
    expect(session.enter('a', 'task'), isFalse);
    expect(session.acquire('b', 'other'), isFalse);
    session.leave();
    expect(session.acquire('b', 'other'), isTrue);
  });
}
