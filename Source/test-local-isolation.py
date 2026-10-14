import importlib.util
import os
import unittest
from pathlib import Path
from unittest.mock import patch
spec = importlib.util.spec_from_file_location('monitor', Path(__file__).with_name('monitor.py'))
m = importlib.util.module_from_spec(spec);spec.loader.exec_module(m)

class IsolationTests(unittest.TestCase):
    def test_other_user_processes_are_not_associated(self):
        processes = f'{os.getuid()+1} 123 00:05 /usr/local/bin/codex app-server\n'
        with patch.object(m.subprocess, 'check_output', return_value=processes):
            result = m.LocalTasks().scan(-1)
        self.assertEqual(result['count'], 0)
        self.assertEqual(result['state'], 'idle')
    def test_new_instance_has_no_saved_quota(self):
        monitor = m.Monitor()
        try:
            self.assertIsNone(monitor.snapshot['usage'])
            self.assertIsNone(monitor.snapshot['usageUpdatedAt'])
        finally:
            monitor.selector.close()
    def test_missing_login_does_not_supply_demo_data(self):
        monitor = m.Monitor();monitor.emit = lambda: None
        try:
            with patch.object(m, 'locate_cli', return_value=None): monitor.connect()
            self.assertEqual(monitor.snapshot['usageState'], 'unavailable')
            self.assertIsNone(monitor.snapshot['usage'])
        finally:
            monitor.selector.close()

unittest.main()
