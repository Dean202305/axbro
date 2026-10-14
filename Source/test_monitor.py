import importlib.util
import json
import tempfile
import unittest
from pathlib import Path
spec = importlib.util.spec_from_file_location('monitor', str(Path(__file__).with_name('monitor.py')))
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)

def event(kind, time='2026-10-13T10:00:00Z'):
    return (json.dumps({'type':'event_msg','timestamp':time,'payload':{'type':kind}})+'\n').encode()

class LifecycleTests(unittest.TestCase):
    def test_active_then_completed(self):
        lifecycle=m.Lifecycle()
        lifecycle.feed(event('task_started'))
        self.assertTrue(lifecycle.active_since(m.timestamp('2026-10-13T09:59:00Z')))
        lifecycle.feed(event('task_complete'))
        self.assertFalse(lifecycle.active_since(0))
    def test_aborted_and_restart(self):
        lifecycle=m.Lifecycle()
        lifecycle.feed(event('task_started')+event('turn_aborted'))
        self.assertFalse(lifecycle.active_since(0))
        lifecycle.feed(event('task_started'))
        self.assertFalse(lifecycle.active_since(m.timestamp('2026-10-13T11:00:00Z')))
    def test_partial_line_and_message_mentions(self):
        lifecycle=m.Lifecycle()
        line=event('task_started')
        lifecycle.feed(line[:17]);self.assertIsNone(lifecycle.event)
        lifecycle.feed(line[17:]);self.assertEqual(lifecycle.event,'task_started')
        lifecycle.feed(b'{"type":"response_item","payload":{"type":"task_complete"}}\n')
        self.assertEqual(lifecycle.event,'task_started')
    def test_file_truncation(self):
        with tempfile.TemporaryDirectory() as d:
            path=Path(d)/'log.jsonl';path.write_bytes(event('task_started'))
            lifecycle=m.Lifecycle();lifecycle.read(path)
            path.write_bytes(event('task_complete'))
            lifecycle.read(path);self.assertFalse(lifecycle.active_since(0))
    def test_elapsed(self):
        self.assertEqual(m.elapsed_seconds('2-01:02:03'),176523)
        self.assertEqual(m.elapsed_seconds('03:02'),182)

class UsageTests(unittest.TestCase):
    def monitor(self):
        monitor=m.Monitor();monitor.emit=lambda:None
        self.addCleanup(monitor.selector.close)
        return monitor
    def test_bucket_and_authoritative_reset_count(self):
        monitor=self.monitor()
        monitor.apply_usage({'rateLimits':{'primary':{'usedPercent':99}},'rateLimitsByLimitId':{'codex':{'primary':{'usedPercent':29}}},'rateLimitResetCredits':{'availableCount':2,'credits':[]}})
        self.assertEqual(monitor.snapshot['usage']['primary']['usedPercent'],29)
        self.assertEqual(monitor.snapshot['usage']['resetCount'],2)
    def test_missing_is_unknown_and_error_is_stale(self):
        monitor=self.monitor();monitor.apply_usage({'rateLimits':{'primary':None}})
        self.assertIsNone(monitor.snapshot['usage']['resetCount'])
        monitor.unavailable('offline')
        self.assertEqual(monitor.snapshot['usageState'],'stale')
        self.assertIsNotNone(monitor.snapshot['usage'])
    def test_never_use_another_model_bucket(self):
        monitor=self.monitor();monitor.apply_usage({'rateLimits':{'primary':{'usedPercent':0}},'rateLimitsByLimitId':{'other':{'primary':{'usedPercent':4}}}})
        self.assertEqual(monitor.snapshot['usageState'],'unavailable')
        self.assertIsNone(monitor.snapshot['usage'])

unittest.main()
