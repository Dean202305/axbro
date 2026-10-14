#!/usr/bin/python3
"""Read-only Codex telemetry bridge. No inference, thread mutation or token copying."""
import datetime
import json
import os
from pathlib import Path
import selectors
import signal
import sqlite3
import subprocess
import sys
import time
sys.dont_write_bytecode = True  # Keep the signed application bundle read-only.

HOME = Path(os.environ.get('CODEX_HOME', str(Path.home() / '.codex')))


def locate_cli():
    candidates = [os.environ.get('CODEX_MINI_CLI', ''),
                  '/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex',
                  '/Applications/Codex.app/Contents/Resources/codex',
                  '/Applications/Codex.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex',
                  str(Path.home() / 'Applications/Codex.app/Contents/Resources/codex'),
                  '/opt/homebrew/bin/codex', '/usr/local/bin/codex']
    import shutil
    candidates.append(shutil.which('codex') or '')
    return next((p for p in candidates if p and os.access(p, os.X_OK)), None)


def elapsed_seconds(value):
    days, clock = (value.split('-', 1) if '-' in value else ('0', value))
    parts = [int(x) for x in clock.split(':')]
    seconds = 0
    for part in parts:
        seconds = seconds * 60 + part
    return int(days) * 86400 + seconds


def timestamp(value):
    try:
        return datetime.datetime.fromisoformat(value.replace('Z', '+00:00')).timestamp()
    except (ValueError, TypeError, AttributeError):
        return None


class Lifecycle:
    def __init__(self):
        self.offset = 0
        self.partial = b''
        self.event = None
        self.started = None
        self.inode = None
        self.anchor = b''

    def feed(self, data):
        lines = (self.partial + data).split(b'\n')
        self.partial = lines.pop()
        for line in lines:
            if not any(word in line for word in (b'"task_started"', b'"task_complete"', b'"turn_aborted"', b'"task_failed"')):
                continue
            try:
                record = json.loads(line)
                if record.get('type') != 'event_msg':
                    continue
                event = record.get('payload', {}).get('type')
                if event in ('task_started', 'task_complete', 'turn_aborted', 'task_failed'):
                    self.event = event
                    self.started = timestamp(record.get('timestamp')) if event == 'task_started' else None
            except (ValueError, AttributeError):
                continue

    def read(self, path):
        stat = os.stat(path)
        if stat.st_ino != self.inode or stat.st_size < self.offset:
            self.__init__()
            self.inode = stat.st_ino
        with open(path, 'rb') as file:
            if self.anchor:
                file.seek(self.offset - len(self.anchor))
                if file.read(len(self.anchor)) != self.anchor:
                    self.__init__()
                    self.inode = stat.st_ino
            file.seek(self.offset)
            while True:
                chunk = file.read(65536)
                if not chunk:
                    break
                self.feed(chunk)
                self.offset += len(chunk)
            file.seek(max(0, self.offset - 64))
            self.anchor = file.read(min(64, self.offset))

    def active_since(self, started):
        return self.event == 'task_started' and self.started is not None and self.started >= started - 2


class LocalTasks:
    def __init__(self):
        self.cache = {}

    def scan(self, telemetry_pid):
        try:
            processes = subprocess.check_output(['/bin/ps', '-axo', 'uid=,pid=,etime=,command='], timeout=2, text=True)
            desktop_starts, cli_starts = [], []
            now = time.time()
            for row in processes.splitlines():
                fields = row.strip().split(None, 3)
                if len(fields) != 4:
                    continue
                uid, pid, elapsed, command = fields
                if int(uid) != os.getuid():
                    continue
                if int(pid) == telemetry_pid:
                    continue
                # Only Codex execution processes; exec-server remote is intentionally excluded.
                if 'codex' not in command or 'exec-server' in command:
                    continue
                if ' app-server' in command and ' generate-' not in command and ' proxy' not in command:
                    desktop_starts.append(now - elapsed_seconds(elapsed))
                elif command.split()[0].endswith('/codex') or command.split()[0] == 'codex':
                    if ' exec ' in command or len(command.split()) == 1:
                        cli_starts.append(now - elapsed_seconds(elapsed))
            if not desktop_starts and not cli_starts:
                self.cache.clear()
                return {'count': 0, 'state': 'idle', 'detail': '本机 Codex 未运行；不包含云端或其他设备。'}
            earliest = min(desktop_starts + cli_starts)
            databases = list(HOME.glob('state_*.sqlite'))
            if not databases:
                raise OSError('missing database')
            db = max(databases, key=lambda p: int(p.stem.split('_')[-1]))
            with sqlite3.connect(db.as_uri() + '?mode=ro', uri=True, timeout=0.2) as connection:
                rows = connection.execute('SELECT rollout_path, source FROM threads WHERE archived=0 AND updated_at >= ?',
                                          (int(earliest) - 2,)).fetchall()
            count, failed, seen = 0, False, set()
            for path, source in rows:
                # Agent children are execution within a chat, not additional user tasks.
                if source.startswith('{'):
                    try:
                        if 'subAgent' in json.loads(source):
                            continue
                    except ValueError:
                        continue
                starts = cli_starts if source in ('cli', 'exec') else desktop_starts
                if not starts:
                    continue
                try:
                    Path(path).resolve().relative_to(Path.home().resolve())
                except ValueError:
                    continue
                seen.add(path)
                lifecycle = self.cache.setdefault(path, Lifecycle())
                try:
                    lifecycle.read(path)
                    if lifecycle.active_since(min(starts)):
                        count += 1
                except OSError:
                    failed = True
            self.cache = {p: v for p, v in self.cache.items() if p in seen}
            if failed:
                return {'count': None, 'state': 'unknown', 'detail': '部分运行日志无法读取，请稍后刷新。'}
            return {'count': count, 'state': 'running' if count else 'idle',
                    'detail': '从本机任务开始／结束日志识别，等待输入也可能计入；不包含云端、其他设备或内部子代理。运行不代表持续产生用量。'}
        except (OSError, sqlite3.Error, subprocess.SubprocessError, ValueError):
            return {'count': None, 'state': 'unknown', 'detail': '暂时无法读取本机任务状态。'}


class Monitor:
    def __init__(self):
        self.selector = selectors.DefaultSelector()
        self.process = None
        self.buffer = b''
        self.identifier = 0
        self.pending = {}
        self.ready = False
        self.retry_at = 0
        self.usage_due = 0
        self.tasks_due = 0
        self.tasks = LocalTasks()
        self.snapshot = {'kind': 'snapshot', 'usage': None, 'usageUpdatedAt': None,
                         'usageState': 'loading', 'usageMessage': '正在连接 Codex…',
                         'tasks': {'count': None, 'state': 'loading', 'detail': '正在读取本机任务状态…'}}
        self.running = True
        signal.signal(signal.SIGTERM, self.stop)
        signal.signal(signal.SIGINT, self.stop)

    def emit(self):
        print(json.dumps(self.snapshot, ensure_ascii=False, separators=(',', ':')), flush=True)

    def stop(self, *_):
        self.running = False

    def close_server(self):
        if self.process:
            try:
                self.selector.unregister(self.process.stdout)
            except (KeyError, ValueError):
                pass
            if self.process.poll() is None:
                self.process.terminate()
                try:
                    self.process.wait(timeout=3)
                except subprocess.TimeoutExpired:
                    self.process.kill()
                    self.process.wait()
            self.process.stdin.close()
            self.process.stdout.close()
        self.process = None
        self.ready = False
        self.pending.clear()
        self.buffer = b''

    def unavailable(self, message):
        self.snapshot['usageState'] = 'stale' if self.snapshot['usage'] is not None else 'unavailable'
        self.snapshot['usageMessage'] = message
        self.emit()

    def connect(self):
        self.retry_at = time.monotonic() + 30
        cli = locate_cli()
        if not cli:
            self.unavailable('未找到 Codex，请安装并登录 Codex 后刷新。')
            return
        try:
            self.process = subprocess.Popen([cli, 'app-server', '--listen', 'stdio://'], stdin=subprocess.PIPE,
                                            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, bufsize=0)
            os.set_blocking(self.process.stdout.fileno(), False)
            self.selector.register(self.process.stdout, selectors.EVENT_READ, 'server')
            self.send('initialize', {'clientInfo': {'name': 'axbro', 'title': 'axbro', 'version': '1.14.6'},
                                     'capabilities': {'experimentalApi': True}})
        except OSError:
            self.close_server()
            self.unavailable('Codex 连接失败，30 秒后自动重试。')

    def send(self, method, params=None, notification=False):
        if not self.process:
            return
        packet = {'method': method}
        if params is not None:
            packet['params'] = params
        if not notification:
            self.identifier += 1
            packet['id'] = self.identifier
            self.pending[self.identifier] = (method, time.monotonic() + 25)
        self.process.stdin.write((json.dumps(packet) + '\n').encode())
        self.process.stdin.flush()

    def receive(self, packet):
        pending = self.pending.pop(packet.get('id'), None)
        if pending:
            method = pending[0]
            if 'error' in packet:
                self.unavailable('无法读取用量，请确认 Codex 已登录 ChatGPT。')
                if method == 'initialize':
                    self.close_server()
                return
            if method == 'initialize':
                self.send('initialized', notification=True)
                self.ready = True
                self.usage_due = 0
            elif method == 'account/rateLimits/read':
                self.apply_usage(packet.get('result', {}))
        elif packet.get('method') == 'account/rateLimits/updated':
            # Notification can omit reset credits: schedule an authoritative full read.
            self.usage_due = 0
        elif 'id' in packet and 'method' in packet:
            # This observer never approves execution, requests a login, or supplies tokens.
            self.process.stdin.write((json.dumps({'id': packet['id'], 'error': {'code': -32601, 'message': 'Read-only observer'}}) + '\n').encode())
            self.process.stdin.flush()

    def apply_usage(self, result):
        buckets = result.get('rateLimitsByLimitId')
        if isinstance(buckets, dict) and buckets:
            bucket = buckets.get('codex')
        else:
            bucket = result.get('rateLimits')
        if not isinstance(bucket, dict):
            self.unavailable('当前账户未提供 Codex 用量。')
            return
        credits = result.get('rateLimitResetCredits')
        self.snapshot.update(usage={'primary': bucket.get('primary'), 'secondary': bucket.get('secondary'),
                                    'resetCount': credits.get('availableCount') if isinstance(credits, dict) else None,
                                    'plan': bucket.get('planType'), 'allowed': result.get('ordinaryUsageAllowed')},
                             usageUpdatedAt=time.time(), usageState='live', usageMessage='')
        self.emit()

    def run(self):
        os.set_blocking(sys.stdin.fileno(), False)
        self.selector.register(sys.stdin, selectors.EVENT_READ, 'input')
        self.emit()
        try:
            while self.running:
                now = time.monotonic()
                if self.process is None and now >= self.retry_at:
                    self.connect()
                if self.process is not None:
                    if self.process.poll() is not None:
                        self.close_server()
                        self.unavailable('Codex 连接已断开，正在重连。')
                        self.retry_at = now + 5
                    elif any(deadline <= now for _, deadline in self.pending.values()):
                        self.close_server()
                        self.unavailable('读取用量超时，正在重连。')
                        self.retry_at = now + 5
                    elif self.ready and now >= self.usage_due and not any(m == 'account/rateLimits/read' for m, _ in self.pending.values()):
                        self.send('account/rateLimits/read')
                        self.usage_due = now + 5
                if now >= self.tasks_due:
                    tasks = self.tasks.scan(self.process.pid if self.process else -1)
                    if tasks != self.snapshot['tasks']:
                        self.snapshot['tasks'] = tasks
                        self.emit()
                    self.tasks_due = now + 5
                for key, _ in self.selector.select(timeout=0.5):
                    if key.data == 'input':
                        data = os.read(sys.stdin.fileno(), 4096)
                        if not data:
                            self.running = False
                            break
                        self.usage_due = 0
                        self.tasks_due = 0
                        self.retry_at = 0
                    elif self.process:
                        data = os.read(self.process.stdout.fileno(), 65536)
                        if not data:
                            continue
                        self.buffer += data
                        while b'\n' in self.buffer:
                            line, self.buffer = self.buffer.split(b'\n', 1)
                            try:
                                self.receive(json.loads(line))
                            except ValueError:
                                pass
        except (BrokenPipeError, OSError):
            pass
        finally:
            self.close_server()
            self.selector.close()


if __name__ == '__main__':
    Monitor().run()
