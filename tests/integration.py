#!/usr/bin/env python3
"""Black-box tests. All backends, HOME, and XDG paths are isolated in /tmp."""
import json
import os
from pathlib import Path
import subprocess
import socket
import sys
import tempfile
import time
import unittest

PICK = Path(__file__).resolve().parent.parent / 'contrib' / 'zpaper-pick'
FAKE_FZF = r'''#!/usr/bin/env python3
# Records each call and picks the first row whose label contains the next
# entry of FAKE_FZF_PICKS ("|"-separated, one per call); "cancel" exits 130.
import json, os, pathlib, sys
root = pathlib.Path(os.environ['FAKE_ROOT'])
rows = [r for r in sys.stdin.buffer.read().split(b'\0') if r]
calls = root / 'fzf-calls'
n = len(calls.read_text().splitlines()) if calls.exists() else 0
with calls.open('a') as f:
    f.write(json.dumps({'args': sys.argv[1:], 'rows': [r.decode() for r in rows]}) + '\n')
pick = os.environ.get('FAKE_FZF_PICKS', '').split('|')[n]
if pick == 'cancel':
    sys.exit(130)
for row in rows:
    if pick in row.decode().split('\t')[1]:
        sys.stdout.buffer.write(row + b'\0')
        sys.exit(0)
sys.exit(1)
'''
BINARY = Path(os.environ.get("ZPAPER_BIN", "zig-out/bin/zpaper")).resolve()
XRANDR = r'''#!/usr/bin/env python3
import os, pathlib, sys
monitors = pathlib.Path(os.environ['FAKE_ROOT']) / 'monitors'
if not monitors.exists():
    sys.exit(1)
lines = monitors.read_text().split()
print(f'Monitors: {len(lines)}')
for i, line in enumerate(lines):
    name, geometry = line.split('=')
    print(f' {i}: +{name} {geometry}  {name}')
'''
FAKE = r'''#!/usr/bin/env python3
import json, os, pathlib, sys, time
root = pathlib.Path(os.environ['FAKE_ROOT'])
args = sys.argv[1:]
with (root / 'calls').open('a') as f:
    f.write(json.dumps([pathlib.Path(sys.argv[0]).name, *args]) + '\n')
layout = json.loads((root / 'display.json').read_text())
if args == ['query']:
    for output, image in layout.items():
        prefix = 'awww-daemon: ' if pathlib.Path(sys.argv[0]).name == 'awww' else ''
        print(f'{prefix}{output}: 1920x1080, scale: 1, currently displaying: image: {image}')
    sys.exit(0)
if args and args[0] == 'img':
    image = args[1]
    output = args[args.index('--outputs') + 1] if '--outputs' in args else None
    if (root / 'slow').exists():
        time.sleep(10)
    if (root / 'fail').exists() and (root / 'fail').read_text() in (output, '*'):
        print('deliberate backend failure', file=sys.stderr)
        sys.exit(7)
    for name in ([output] if output else layout):
        layout[name] = image
    (root / 'display.json').write_text(json.dumps(layout))
else:
    (root / 'custom-args.json').write_text(json.dumps(args))
'''


class Integration(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='zp-test-')
        self.root = Path(self.tmp.name)
        self.bin = self.root / 'bin'
        self.bin.mkdir()
        for name in ['awww', 'swww', 'feh', 'custom-setter']:
            p = self.bin / name
            p.write_text(FAKE)
            p.chmod(0o755)
        xrandr = self.bin / 'xrandr'
        xrandr.write_text(XRANDR)
        xrandr.chmod(0o755)
        self.runtime = self.root / 'runtime'
        self.runtime.mkdir(mode=0o700)
        self.images = self.root / 'images'
        self.images.mkdir()
        self.pics = []
        for name in ['a image.png', 'b: image.png', 'c.png', 'd.png']:
            p = self.images / name
            p.write_bytes(b'fake image for backend fixture')
            self.pics.append(str(p))
        self.display = self.root / 'display.json'
        self.display.write_text(json.dumps({'DP-1': self.pics[0], 'HDMI-A-1': self.pics[1]}))
        self.cfg = self.root / 'config' / 'zpaper' / 'zpaperc'
        self.cfg.parent.mkdir(parents=True)
        self.config()
        self.env = {**os.environ, 'HOME': str(self.root),
                    'XDG_CONFIG_HOME': str(self.root / 'config'),
                    'XDG_STATE_HOME': str(self.root / 'state'),
                    'XDG_RUNTIME_DIR': str(self.runtime),
                    'PATH': str(self.bin) + ':' + os.environ['PATH'],
                    'FAKE_ROOT': str(self.root), 'WAYLAND_DISPLAY': 'fake', 'TZ': 'UTC0'}
        self.proc = None

    def tearDown(self):
        if self.proc and self.proc.poll() is None:
            self.proc.terminate()
            try:
                self.proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                self.proc.kill()
                self.proc.wait()
        if self.proc:
            self.proc.stdout.close()
            self.proc.stderr.close()
        self.tmp.cleanup()

    def config(self, extra='', backend='awww', interval='0'):
        self.cfg.write_text(f'backend = {backend}\nbackend_start = false\n'
                            f'dir = "{self.images}"\ninterval = {interval}\n'
                            f'timeout = 1s\n{extra}')

    def cmd(self, *args, ok=True):
        p = subprocess.run([str(BINARY), *args], env=self.env, text=True,
                           capture_output=True, timeout=15)
        if ok:
            self.assertEqual(p.returncode, 0, p.stderr + p.stdout)
        else:
            self.assertNotEqual(p.returncode, 0, p.stderr + p.stdout)
        return p

    def state(self):
        return json.loads((self.root / 'state' / 'zpaper' / 'state.json').read_text())

    def shown(self):
        return json.loads(self.display.read_text())

    def start(self, *args):
        self.proc = subprocess.Popen([str(BINARY), *(args or ('daemon',))], env=self.env,
                                     stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            if self.proc.poll() is not None:
                self.fail(self.proc.communicate())
            if list(self.runtime.glob('*/control.sock')):
                self.cmd('status')
                return
            time.sleep(.03)
        self.fail('daemon did not start')

    def test_daemon_config_defaults_to_oneshot(self):
        self.config(interval='30m')
        self.cmd()
        self.assertTrue(self.state()['current'])
        self.assertFalse(list(self.runtime.glob('*/control.sock')))
        self.config(extra='daemon = false\n', interval='30m')
        self.cmd()
        self.assertFalse(list(self.runtime.glob('*/control.sock')))
        self.start()  # Explicit daemon overrides daemon = false.
        self.cmd('stop')
        self.proc.wait(timeout=5)

    def test_daemon_config_only_changes_implicit_command(self):
        self.config(extra='daemon = true\n')
        self.cmd('next')
        self.cmd('--next')
        self.cmd('check')
        self.assertFalse(list(self.runtime.glob('*/control.sock')))
        self.start('--config', str(self.cfg))
        shown = self.shown()
        self.assertIn('already running', self.cmd(ok=False).stderr)
        self.assertEqual(shown, self.shown())
        self.cmd('next')
        self.config(extra='daemon = false\n')
        self.cmd('reload')
        self.assertIsNone(self.proc.poll())
        self.cmd('stop')
        self.proc.wait(timeout=5)

    def test_daemon_config_rejects_invalid_value_and_command_options(self):
        self.config(extra='daemon = yes\n')
        self.cmd('check', ok=False)
        self.config(extra='daemon = true\n')
        self.cmd('--output', 'DP-1', ok=False)
        self.assertFalse(list(self.runtime.glob('*/control.sock')))

    def test_layout_navigation_and_branch(self):
        initial = self.shown()
        self.cmd('set', self.pics[2], self.pics[3])
        changed = self.shown()
        self.assertEqual(changed, {'DP-1': self.pics[2], 'HDMI-A-1': self.pics[3]})
        self.cmd('previous')
        self.assertEqual(self.shown(), initial)
        self.cmd('next')
        self.assertEqual(self.shown(), changed)
        self.cmd('previous')
        self.cmd('set', self.pics[3], '--output', 'DP-1')
        self.assertEqual(len(self.state()['layouts']), 2)
        self.assertEqual(self.shown()['HDMI-A-1'], initial['HDMI-A-1'])

    def test_partial_failure_records_only_success(self):
        (self.root / 'fail').write_text('HDMI-A-1')
        p = self.cmd('set', self.pics[2], ok=False)
        self.assertIn('deliberate backend failure', p.stderr)
        actual = {e['output']: e['image'] for e in self.state()['current']}
        self.assertEqual(actual, self.shown())
        self.assertEqual(actual['DP-1'], self.pics[2])
        self.assertEqual(actual['HDMI-A-1'], self.pics[1])
        (self.root / 'fail').unlink()
        self.cmd('previous')
        self.assertEqual(self.shown()['DP-1'], self.pics[0])

    def test_total_failure_preserves_state(self):
        self.cmd('set', self.pics[2])
        before = self.state()
        (self.root / 'fail').write_text('*')
        self.cmd('next', ok=False)
        self.assertEqual(self.state(), before)

    def test_shuffle_survives_separate_processes(self):
        chosen = []
        for _ in range(4):
            self.cmd('next')
            chosen.append(self.shown()['DP-1'])
        self.assertEqual(len(set(chosen)), 4)
        self.cmd('next')
        self.assertNotEqual(self.shown()['DP-1'], chosen[-1])

    def test_favorite_exclusion_and_missing_files(self):
        self.cmd('favorite')
        self.assertEqual(set(self.state()['favorites']), set(self.pics[:2]))
        self.cmd('exclude', *self.pics[:3])
        self.cmd('next')
        self.assertEqual(self.shown()['DP-1'], self.pics[3])
        self.cmd('unfavorite', self.pics[0])
        self.assertEqual(self.state()['favorites'], [self.pics[1]])
        Path(self.pics[1]).unlink()
        self.cmd('random-favorite', ok=False)

    def test_import_is_idempotent_and_preserves_source(self):
        legacy = self.root / 'legacy'
        legacy.mkdir()
        history = f'2026-01-01 00:00:00|{self.pics[0]}\n2025-01-01 00:00:00|{self.pics[1]}\n'
        (legacy / 'wallpaper_history').write_text(history)
        (legacy / 'wallpaper_favorites').write_text(self.pics[1] + '\n')
        self.cmd('import-legacy', str(legacy))
        before = self.state()
        self.cmd('import-legacy', str(legacy))
        self.assertEqual(self.state(), before)
        self.assertEqual((legacy / 'wallpaper_history').read_text(), history)
        self.cmd('select', '2')
        self.assertEqual(self.shown()['DP-1'], self.pics[1])

    def test_custom_setter_quoted_embedded_placeholder(self):
        self.config(backend='custom', extra='setter = custom-setter "prefix=%s" "two words"\n')
        self.cmd('set', self.pics[0])
        argv = json.loads((self.root / 'custom-args.json').read_text())
        self.assertEqual(argv, ['prefix=' + self.pics[0], 'two words'])
        self.cmd('set', self.pics[1], '--output', 'DP-1', ok=False)

    def test_daemon_routing_lock_stop_and_hold_persistence(self):
        self.cmd('set', self.pics[2])
        self.cmd('hold', '2h', '--output', 'DP-1')
        self.start()
        self.cmd('daemon', ok=False)
        status = json.loads(self.cmd('status', '--json').stdout)
        self.assertTrue(status['daemon'])
        self.assertEqual(status['holds'][0]['output'], 'DP-1')
        self.cmd('set', self.pics[3], '--output', 'HDMI-A-1')
        self.assertEqual(self.shown()['DP-1'], self.pics[2])
        self.cmd('stop')
        self.proc.wait(timeout=5)
        self.assertFalse(json.loads(self.cmd('status', '--json').stdout)['daemon'])
        self.assertEqual(self.state()['holds'][0]['output'], 'DP-1')

    def test_automatic_rotation_respects_output_hold(self):
        self.cmd('set', self.pics[0])
        self.cmd('hold', '--output', 'DP-1')
        self.config(interval='1s')
        self.start()
        deadline = time.monotonic() + 5
        while self.shown()['HDMI-A-1'] == self.pics[0] and time.monotonic() < deadline:
            time.sleep(.1)
        self.assertEqual(self.shown()['DP-1'], self.pics[0])
        self.assertNotEqual(self.shown()['HDMI-A-1'], self.pics[0])
        self.cmd('resume')
        self.assertEqual(self.state()['holds'], [])

    def test_global_hold_and_expiry(self):
        self.cmd('set', self.pics[0])
        self.cmd('hold', '2s')
        self.config(interval='1s')
        self.start()
        time.sleep(.4)
        self.assertEqual(self.shown()['DP-1'], self.pics[0])
        deadline = time.monotonic() + 8
        while self.shown()['DP-1'] == self.pics[0] and time.monotonic() < deadline:
            time.sleep(.1)
        self.assertNotEqual(self.shown()['DP-1'], self.pics[0])

    def test_reload_keeps_good_config_on_error(self):
        self.start()
        self.config(interval='2s')
        self.cmd('reload')
        self.assertEqual(json.loads(self.cmd('status', '--json').stdout)['interval_seconds'], 2)
        self.cfg.write_text('interval = nonsense\n')
        p = self.cmd('reload', ok=False)
        self.assertIn('line 1', p.stderr)
        self.assertEqual(json.loads(self.cmd('status', '--json').stdout)['interval_seconds'], 2)
        self.cmd('hold')

    def test_timeout_and_invalid_config(self):
        (self.root / 'slow').touch()
        start = time.monotonic()
        p = self.cmd('set', self.pics[0], ok=False)
        self.assertIn('timed out', p.stderr)
        self.assertLess(time.monotonic() - start, 5)
        self.cfg.write_text('recursive = maybe\n')
        self.assertIn('line 1', self.cmd('check', ok=False).stderr)

    def test_reject_invalid_commands_before_changes(self):
        for args in [('set',), ('previous', '--output', 'DP-1'), ('next', '--history'),
                     ('set', self.pics[0], '--output', 'missing'), ('hold', '0'),
                     ('set', self.pics[0], '--json')]:
            self.cmd(*args, ok=False)
        self.assertFalse((self.root / 'calls').exists() and any('"img"' in x for x in (self.root / 'calls').read_text().splitlines()))

    def test_current_queries_external_changes(self):
        self.cmd('set', self.pics[0])
        self.display.write_text(json.dumps({'DP-1': self.pics[3], 'HDMI-A-1': self.pics[2]}))
        result = json.loads(self.cmd('current', '--json').stdout)
        self.assertEqual(result['source'], 'backend')
        self.assertEqual(result['outputs'][0]['image'], self.pics[3])
        self.cmd('set', self.pics[1])
        self.cmd('previous')
        self.assertEqual(self.shown()['DP-1'], self.pics[3])

    def test_swww_and_feh_adapters(self):
        self.config(backend='swww')
        self.cmd('set', self.pics[2], '--output', 'DP-1')
        self.assertEqual(self.shown()['DP-1'], self.pics[2])
        self.config(backend='feh')
        self.cmd('set', self.pics[3])
        self.assertEqual(json.loads((self.root / 'custom-args.json').read_text()), ['--bg-fill', self.pics[3]])
        self.config(backend='auto')
        self.env['PATH'] = os.path.relpath(self.bin) + ':' + os.environ['PATH']
        self.cmd('set', self.pics[1], '--output', 'DP-1')
        self.assertEqual(self.shown()['DP-1'], self.pics[1])
        calls = [json.loads(line) for line in (self.root / 'calls').read_text().splitlines()]
        self.assertEqual(calls[-1][0], 'awww')


    def test_relative_paths_use_client_working_directory(self):
        relative_config = os.path.relpath(self.cfg)
        self.cmd('--config', relative_config, 'check')
        self.cmd('set', os.path.relpath(self.pics[2]))
        self.assertEqual(self.shown()['DP-1'], self.pics[2])
        self.start()
        self.cmd('set', os.path.relpath(self.pics[3]))
        self.assertEqual(self.shown()['DP-1'], self.pics[3])

    def test_invalid_daemon_start_config_has_diagnostic(self):
        self.cfg.write_text('interval = invalid\n')
        p = self.cmd('daemon', ok=False)
        self.assertIn('config line 1', p.stderr)

    def test_disconnected_output_restore_reports_partial(self):
        self.cmd('set', self.pics[2], self.pics[3])
        self.display.write_text(json.dumps({'DP-1': self.pics[2]}))
        p = self.cmd('previous', ok=False)
        self.assertIn('disconnected', p.stderr)
        self.assertEqual(self.shown(), {'DP-1': self.pics[0]})
        self.assertEqual(self.state()['current'], [{'output': 'DP-1', 'image': self.pics[0]}])

    def wait_for(self, predicate, timeout=8):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if predicate():
                return True
            time.sleep(.1)
        return predicate()

    def test_refresh_alias_reapplies_saved_layout(self):
        self.cmd('set', self.pics[2], self.pics[3])
        self.display.write_text(json.dumps({'DP-1': '', 'HDMI-A-1': ''}))
        self.cmd('refresh')
        self.assertEqual(self.shown(), {'DP-1': self.pics[2], 'HDMI-A-1': self.pics[3]})

    def test_refresh_is_not_a_new_choice(self):
        self.install_hook()
        self.config('on_change = theme-hook %s\n', interval='1h')
        self.cmd('set', self.pics[2], self.pics[3])
        self.assertTrue(self.wait_for(lambda: len(self.hook_calls()) == 1))
        before = self.state()
        time.sleep(1.1)
        self.display.write_text(json.dumps({'DP-1': '', 'HDMI-A-1': ''}))
        self.cmd('refresh')
        self.assertEqual(self.shown(), {'DP-1': self.pics[2], 'HDMI-A-1': self.pics[3]})
        after = self.state()
        for key in ('images', 'layouts', 'cursor', 'next_due', 'seen', 'collection_progress'):
            self.assertEqual(after.get(key), before.get(key), key)
        time.sleep(.5)
        self.assertEqual(len(self.hook_calls()), 1)

    def test_startup_restore_restarts_overdue_timer(self):
        self.config(interval='1h')
        self.cmd('set', self.pics[2], self.pics[3])
        path = self.root / 'state' / 'zpaper' / 'state.json'
        saved = self.state()
        saved['next_due'] = int(time.time()) - 600
        path.write_text(json.dumps(saved))
        self.start()
        state = self.state()
        self.assertGreater(state['next_due'], time.time() + 3000)
        self.assertEqual(state['images'], saved['images'])
        time.sleep(1)
        self.assertEqual(self.shown(), {'DP-1': self.pics[2], 'HDMI-A-1': self.pics[3]})

    def test_hotplug_restores_returning_output_without_new_history(self):
        self.cmd('set', self.pics[2], self.pics[3])
        self.start()
        layouts = len(self.state()['layouts'])
        images = self.state()['images']
        self.display.write_text(json.dumps({'DP-1': self.pics[2]}))
        time.sleep(2.5)
        self.display.write_text(json.dumps({'DP-1': self.pics[2], 'HDMI-A-1': ''}))
        self.assertTrue(self.wait_for(lambda: self.shown().get('HDMI-A-1') == self.pics[3]), self.shown())
        self.assertEqual(len(self.state()['layouts']), layouts)
        self.assertEqual(self.state()['images'], images)

    def test_hotplug_restores_renderer_reset(self):
        self.cmd('set', self.pics[2], self.pics[3])
        self.start()
        self.display.write_text(json.dumps({'DP-1': '', 'HDMI-A-1': ''}))
        self.assertTrue(self.wait_for(lambda: self.shown() == {'DP-1': self.pics[2], 'HDMI-A-1': self.pics[3]}), self.shown())

    def test_hotplug_new_output_gets_fresh_image(self):
        self.cmd('set', self.pics[2])
        self.cmd('hold')
        self.start()
        time.sleep(2.5)
        shown = self.shown()
        shown['DP-2'] = ''
        self.display.write_text(json.dumps(shown))
        self.assertTrue(self.wait_for(lambda: self.shown().get('DP-2') in self.pics), self.shown())
        # The display changes before the daemon saves state; wait for both.
        def recorded():
            current = {entry['output']: entry['image'] for entry in self.state()['current']}
            return current.get('DP-2') == self.shown()['DP-2']
        self.assertTrue(self.wait_for(recorded), self.state()['current'])
        self.assertEqual(self.shown()['DP-1'], self.pics[2])

    def test_hotplug_leaves_external_changes(self):
        self.cmd('set', self.pics[2])
        self.start()
        self.display.write_text(json.dumps({'DP-1': self.pics[3], 'HDMI-A-1': self.pics[2]}))
        time.sleep(3)
        self.assertEqual(self.shown()['DP-1'], self.pics[3])

    def test_hotplug_can_be_disabled(self):
        self.config('hotplug = false\n')
        self.cmd('set', self.pics[2])
        self.start()
        self.display.write_text(json.dumps({'DP-1': '', 'HDMI-A-1': ''}))
        time.sleep(3)
        self.assertEqual(self.shown(), {'DP-1': '', 'HDMI-A-1': ''})

    def feh_calls(self):
        calls = [json.loads(line) for line in (self.root / 'calls').read_text().splitlines()]
        return [call for call in calls if call[0] == 'feh']

    EDP = 'eDP-1=1920/344x1080/194+0+0'
    HDMI = 'HDMI-1=2560/597x1440/336+1920+0'

    def monitors(self, *entries):
        (self.root / 'monitors').write_text(' '.join(entries))

    def test_feh_hotplug_reapplies_on_monitor_change(self):
        self.config(backend='feh')
        self.monitors(self.EDP)
        self.cmd('set', self.pics[2])
        self.start()
        time.sleep(2.5)
        before = len(self.feh_calls())
        layouts = len(self.state()['layouts'])
        self.monitors(self.EDP, self.HDMI)
        self.assertTrue(self.wait_for(lambda: len(self.feh_calls()) > before))
        call = self.feh_calls()[-1]
        self.assertEqual(call[:3], ['feh', '--bg-fill', self.pics[2]])
        # A monitor zpaper has never seen gets a fresh image and a new layout.
        self.assertIn(call[3], self.pics)
        self.assertTrue(self.wait_for(lambda: len(self.state()['layouts']) == layouts + 1))
        settled = len(self.feh_calls())
        time.sleep(2.5)
        self.assertEqual(len(self.feh_calls()), settled)
        # Unplug and replug: the known image comes back, without a new layout.
        self.monitors(self.EDP)
        self.assertTrue(self.wait_for(lambda: self.feh_calls()[-1] == ['feh', '--bg-fill', self.pics[2]]))
        self.monitors(self.EDP, self.HDMI)
        self.assertTrue(self.wait_for(lambda: self.feh_calls()[-1] == call))
        self.assertEqual(len(self.state()['layouts']), layouts + 1)

    def record_per_output_then_switch_to_feh(self):
        # A layout recorded under Wayland, then a login to an X11 session.
        self.cmd('set', self.pics[2], self.pics[3])
        first = self.state()['current'][0]['image']
        self.config(backend='feh')
        return first

    def test_feh_restores_layout_recorded_per_output(self):
        first = self.record_per_output_then_switch_to_feh()
        self.monitors(self.EDP)
        self.start()
        self.assertEqual(self.feh_calls()[-1], ['feh', '--bg-fill', first])
        self.assertEqual(self.state()['current'], [{'output': 'eDP-1', 'image': first}])

    def test_feh_sets_each_monitor_in_xrandr_order(self):
        self.config(backend='feh')
        self.monitors(self.HDMI, self.EDP)
        self.cmd('set', self.pics[0], self.pics[1])
        self.assertEqual(self.feh_calls()[-1], ['feh', '--bg-fill', self.pics[0], self.pics[1]])
        self.cmd('set', self.pics[2], '--output', 'eDP-1')
        self.assertEqual(self.feh_calls()[-1], ['feh', '--bg-fill', self.pics[0], self.pics[2]])
        current = json.loads(self.cmd('current', '--json').stdout)['outputs']
        self.assertEqual(current, [{'output': 'HDMI-1', 'image': self.pics[0]},
                                   {'output': 'eDP-1', 'image': self.pics[2]}])
        self.cmd('set', self.pics[3], '--output', 'DP-9', ok=False)
        self.cmd('previous')
        self.assertEqual(self.feh_calls()[-1], ['feh', '--bg-fill', self.pics[0], self.pics[1]])

    def test_feh_output_collections(self):
        self.make_collections()
        self.config(extra=self.collection_sections + '[output.HDMI-1]\ncollection = work\n', backend='feh')
        self.monitors(self.EDP, self.HDMI)
        self.assertNotIn('ignored', self.cmd('check').stdout)
        self.cmd('next')
        call = self.feh_calls()[-1]
        self.assertIn(call[2], self.pics)
        self.assertIn(call[3], self.work_pics)
        self.assertIn('HDMI-1: ' + call[3] + ' [collection work]', self.cmd('status').stdout)

    def test_feh_session_switch_restores_each_sessions_layout(self):
        self.config(backend='feh')
        self.monitors(self.EDP, self.HDMI)
        self.cmd('set', self.pics[0], self.pics[1])
        self.config()
        self.cmd('set', self.pics[2], self.pics[3])
        self.config(backend='feh')
        self.start()
        self.assertEqual(self.feh_calls()[-1], ['feh', '--bg-fill', self.pics[0], self.pics[1]])

    def test_wayland_session_switch_restores_each_sessions_layout(self):
        # niri, then qtile, then back to niri: the reverse of the test above.
        self.cmd('set', self.pics[2], self.pics[3])
        self.config(backend='feh')
        self.monitors(self.EDP, self.HDMI)
        self.cmd('set', self.pics[0], self.pics[1])
        self.config()
        self.display.write_text(json.dumps({'DP-1': '', 'HDMI-A-1': ''}))
        self.start()
        self.assertEqual(self.shown(), {'DP-1': self.pics[2], 'HDMI-A-1': self.pics[3]})
        current = {entry['output']: entry['image'] for entry in self.state()['current']}
        self.assertEqual(current, {'DP-1': self.pics[2], 'HDMI-A-1': self.pics[3]})
        self.display.write_text(json.dumps({'DP-1': '', 'HDMI-A-1': ''}))
        self.cmd('refresh')
        self.assertEqual(self.shown(), {'DP-1': self.pics[2], 'HDMI-A-1': self.pics[3]})

    def test_feh_global_state_becomes_per_monitor(self):
        # State from 0.8 or a session without xrandr: one image for all.
        self.config(backend='feh')
        self.cmd('set', self.pics[0])
        self.assertEqual(self.state()['current'], [{'output': '*', 'image': self.pics[0]}])
        self.monitors(self.EDP, self.HDMI)
        current = json.loads(self.cmd('current', '--json').stdout)['outputs']
        self.assertEqual([entry['image'] for entry in current], [self.pics[0], self.pics[0]])
        self.cmd('set', self.pics[1], '--output', 'HDMI-1')
        self.assertEqual(self.feh_calls()[-1], ['feh', '--bg-fill', self.pics[0], self.pics[1]])

    def test_feh_previous_onto_layout_recorded_per_output(self):
        first = self.record_per_output_then_switch_to_feh()
        self.cmd('set', self.pics[0])
        layouts = len(self.state()['layouts'])
        self.cmd('previous')
        self.assertEqual(self.feh_calls()[-1], ['feh', '--bg-fill', first])
        state = self.state()
        self.assertEqual(len(state['layouts']), layouts)
        self.assertEqual(state['cursor'], layouts - 2)
        self.cmd('next')
        self.assertEqual(self.feh_calls()[-1], ['feh', '--bg-fill', self.pics[0]])

    def test_feh_hotplug_without_xrandr_is_skipped(self):
        self.config(backend='feh')
        self.cmd('set', self.pics[2])
        self.start()
        started = len(self.feh_calls())
        time.sleep(2.5)
        self.assertEqual(self.cmd('status').returncode, 0)
        self.assertEqual(len(self.feh_calls()), started)

    def hook_calls(self):
        path = self.root / 'hook-calls'
        if not path.exists():
            return []
        return [json.loads(line) for line in path.read_text().splitlines()]

    def install_hook(self):
        hook = self.bin / 'theme-hook'
        hook.write_text('#!/usr/bin/env python3\nimport json, os, pathlib, sys\n'
                        'with (pathlib.Path(os.environ["FAKE_ROOT"]) / "hook-calls").open("a") as f:\n'
                        '    f.write(json.dumps(sys.argv[1:]) + "\\n")\n')
        hook.chmod(0o755)

    def test_on_change_runs_once_per_change_with_placeholders(self):
        self.install_hook()
        self.config('on_change = theme-hook --image "%s" --output %o\n')
        self.cmd('set', self.pics[2], self.pics[3])
        self.assertTrue(self.wait_for(lambda: len(self.hook_calls()) == 1))
        self.assertEqual(self.hook_calls()[0], ['--image', self.pics[2], '--output', 'DP-1'])
        self.cmd('set', self.pics[1], '--output', 'HDMI-A-1')
        self.assertTrue(self.wait_for(lambda: len(self.hook_calls()) == 2))
        self.assertEqual(self.hook_calls()[1], ['--image', self.pics[1], '--output', 'HDMI-A-1'])

    def test_on_change_appends_image_and_failures_do_not_fail_change(self):
        self.install_hook()
        self.config('on_change = theme-hook\n')
        self.cmd('set', self.pics[2])
        self.assertTrue(self.wait_for(lambda: self.hook_calls() == [[self.pics[2]]]))
        self.config('on_change = missing-hook-program\n')
        self.cmd('set', self.pics[3])
        self.assertEqual(self.shown()['DP-1'], self.pics[3])
        log = self.root / 'state' / 'zpaper' / 'on_change.log'
        self.assertTrue(self.wait_for(lambda: log.exists() and 'missing-hook-program' in log.read_text()))

    def test_on_change_not_run_for_failed_change(self):
        self.install_hook()
        self.config('on_change = theme-hook\n')
        (self.root / 'fail').write_text('*')
        self.cmd('set', self.pics[2], ok=False)
        time.sleep(.5)
        self.assertEqual(self.hook_calls(), [])

    def test_on_change_runs_for_feh(self):
        self.install_hook()
        self.config('on_change = theme-hook %o\n', backend='feh')
        self.cmd('set', self.pics[2])
        self.assertTrue(self.wait_for(lambda: self.hook_calls() == [['*', self.pics[2]]]))

    def pick(self, *args, picks, ok=True, preview='true'):
        fzf = self.bin / 'fzf'
        fzf.write_text(FAKE_FZF)
        fzf.chmod(0o755)
        link = self.bin / 'zpaper'
        if not link.exists():
            link.symlink_to(BINARY)
        env = {**self.env, 'FAKE_FZF_PICKS': '|'.join(picks), 'ZPAPER_PICK_PREVIEW': preview}
        p = subprocess.run([sys.executable, str(PICK), *args], env=env, text=True,
                           capture_output=True, timeout=15)
        if ok:
            self.assertEqual(p.returncode, 0, p.stderr + p.stdout)
        else:
            self.assertNotEqual(p.returncode, 0, p.stderr + p.stdout)
        return p

    def fzf_calls(self):
        return [json.loads(line) for line in (self.root / 'fzf-calls').read_text().splitlines()]

    def test_pick_monitor_first_then_history_image(self):
        self.cmd('set', self.pics[2])
        self.cmd('set', self.pics[3])
        self.pick(picks=['HDMI-A-1', 'c.png'])
        self.assertEqual(self.shown(), {'DP-1': self.pics[3], 'HDMI-A-1': self.pics[2]})
        monitor, image = self.fzf_calls()
        labels = [row.split('\t')[1] for row in monitor['rows']]
        self.assertTrue(labels[0].startswith('DP-1') and labels[1].startswith('HDMI-A-1'))
        self.assertTrue(labels[-1].startswith('all'))
        # Hidden third field previews the monitor's current wallpaper.
        self.assertEqual(monitor['rows'][0].split('\t')[2], self.pics[3])
        self.assertIn('--preview=true {3..}', monitor['args'])
        self.assertEqual([row.split('\t')[1] for row in image['rows']], [self.pics[3], self.pics[2]])

    def test_pick_monitor_step_with_feh(self):
        self.config(backend='feh')
        self.monitors(self.EDP, self.HDMI)
        self.cmd('set', self.pics[2])
        self.cmd('set', self.pics[3])
        self.pick(picks=['HDMI-1', 'c.png'])
        self.assertEqual(self.feh_calls()[-1], ['feh', '--bg-fill', self.pics[3], self.pics[2]])
        monitor, _ = self.fzf_calls()
        labels = [row.split('\t')[1] for row in monitor['rows']]
        self.assertEqual([label.split()[0] for label in labels], ['eDP-1', 'HDMI-1', 'all'])

    def test_pick_all_outputs(self):
        self.cmd('set', self.pics[2], self.pics[3])
        self.cmd('set', self.pics[1])
        self.pick(picks=['all', 'd.png'])
        self.assertEqual(self.shown(), {'DP-1': self.pics[3], 'HDMI-A-1': self.pics[3]})

    def test_pick_positional_output_skips_monitor_step_and_filters(self):
        self.cmd('set', self.pics[2])
        self.cmd('set', self.pics[3])
        self.pick('c.png', 'HDMI-A-1', picks=['c.png'], preview='')
        self.assertEqual(self.shown()['HDMI-A-1'], self.pics[2])
        (call,) = self.fzf_calls()
        self.assertEqual(len(call['rows']), 1)

    def test_pick_browse_uses_monitor_collection(self):
        self.assign_outputs(**{'HDMI-A-1': 'work'})
        self.cmd('next')
        self.pick('--browse', picks=['HDMI-A-1', '2.png'])
        self.assertEqual(self.shown()['HDMI-A-1'], self.work_pics[2])
        self.assertEqual(sorted(row.split('\t')[1] for row in self.fzf_calls()[1]['rows']), self.work_pics)

    def test_pick_named_collection_and_no_preview(self):
        self.make_collections()
        self.pick('-C', 'quiet', '--all', '--no-preview', picks=['1.png'])
        self.assertEqual(self.shown(), {'DP-1': self.quiet_pics[1], 'HDMI-A-1': self.quiet_pics[1]})
        self.assertFalse(any(arg.startswith('--preview') for arg in self.fzf_calls()[0]['args']))

    def test_pick_cancel_changes_nothing(self):
        self.cmd('set', self.pics[2])
        before = self.shown()
        self.pick(picks=['cancel'], ok=False)
        self.assertEqual(self.shown(), before)

    def test_corrupt_state_is_not_overwritten(self):
        self.cmd('hold')
        path = self.root / 'state' / 'zpaper' / 'state.json'
        path.write_text('{invalid')
        self.cmd('set', self.pics[0], ok=False)
        self.assertEqual(path.read_text(), '{invalid')
        self.assertFalse((self.root / 'calls').exists())

    def test_stale_socket_recovery(self):
        self.start()
        self.proc.kill()
        self.proc.wait(timeout=5)
        self.proc.stdout.close()
        self.proc.stderr.close()
        self.start()
        self.cmd('set', self.pics[2])
        self.assertEqual(self.shown()['DP-1'], self.pics[2])

    def test_config_mismatch_and_cross_runtime_lock(self):
        self.start()
        alternate = self.root / 'alternate'
        alternate.write_text(self.cfg.read_text())
        self.assertIn('different config', self.cmd('--config', str(alternate), 'next', ok=False).stderr)
        other = self.root / 'other-runtime'
        other.mkdir(mode=0o700)
        self.env['XDG_RUNTIME_DIR'] = str(other)
        self.assertIn('owns the state', self.cmd('daemon', ok=False).stderr)

    def test_invalid_socket_request_keeps_daemon_healthy(self):
        self.start()
        path = next(self.runtime.glob('*/control.sock'))
        with socket.socket(socket.AF_UNIX) as peer:
            peer.connect(str(path))
            peer.sendall(b'{bad json}\n')
            result = peer.recv(8192)
        self.assertFalse(json.loads(result)['ok'])
        self.cmd('set', self.pics[2])
        self.assertEqual(self.shown()['DP-1'], self.pics[2])

    def test_empty_directory_and_new_files(self):
        for pic in self.pics:
            Path(pic).unlink()
        self.cmd('next', ok=False)
        Path(self.pics[0]).touch()
        self.cmd('next')
        self.assertEqual(self.shown()['DP-1'], self.pics[0])
        Path(self.pics[1]).touch()
        self.cmd('next')
        self.assertEqual(self.shown()['DP-1'], self.pics[1])

    def test_missing_custom_executable(self):
        self.config(backend='custom', extra='setter = /nonexistent/zpaper-test-setter %s\n')
        p = self.cmd('set', self.pics[0], ok=False)
        self.assertIn('cannot execute', p.stderr)

    def test_zero_interval_never_rotates_and_global_backend_resets_mapping(self):
        self.cmd('set', self.pics[2])
        self.start()
        time.sleep(1.2)
        self.assertEqual(self.shown()['DP-1'], self.pics[2])
        self.cmd('stop')
        self.proc.wait(timeout=5)
        self.config(backend='feh')
        self.cmd('set', self.pics[0])
        self.assertEqual(self.state()['current'], [{'output': '*', 'image': self.pics[0]}])


    def make_collections(self, default=None, interval='0'):
        self.quiet = self.root / 'quiet'
        self.work = self.root / 'work'
        self.quiet.mkdir(exist_ok=True)
        self.work.mkdir(exist_ok=True)
        self.quiet_pics = []
        self.work_pics = []
        for directory, result in [(self.quiet, self.quiet_pics), (self.work, self.work_pics)]:
            for n in range(3):
                path = directory / f'{n}.png'
                path.touch()
                result.append(str(path))
        self.collection_sections = (f'[collection.quiet]\ndir = "{self.quiet}"\ninterval = 45m\n'
                                    f'[collection.work]\ndir = "{self.work}"\ninterval = {interval}\n')
        self.config(extra=(f'collection = {default}\n' if default else '') + self.collection_sections)

    def test_named_collections_switch_and_inspect(self):
        self.make_collections()
        entries = json.loads(self.cmd('collections', '--json').stdout)
        self.assertEqual([x['name'] for x in entries], ['default', 'quiet', 'work'])
        self.assertTrue(entries[0]['active'])
        self.assertEqual(json.loads(self.cmd('list', 'quiet', '--json').stdout), self.quiet_pics)
        self.cmd('use', 'quiet')
        self.assertIn(self.shown()['DP-1'], self.quiet_pics)
        status = json.loads(self.cmd('status', '--json').stdout)
        self.assertEqual(status['collection'], 'quiet')
        self.assertEqual(status['interval_seconds'], 2700)
        self.assertEqual(json.loads(self.cmd('list', '--json').stdout), self.quiet_pics)
        self.cmd('use', 'default')
        self.assertIn(self.shown()['DP-1'], self.pics)
        self.assertEqual(self.state()['collection'], 'default')

    def test_independent_collection_shuffle_survives_switches(self):
        self.make_collections()
        quiet, work = [], []
        for _ in range(3):
            self.cmd('use', 'quiet')
            quiet.append(self.shown()['DP-1'])
            self.cmd('use', 'work')
            work.append(self.shown()['DP-1'])
        self.assertEqual(set(quiet), set(self.quiet_pics))
        self.assertEqual(set(work), set(self.work_pics))
        progress = {p['name']: p['seen'] for p in self.state()['collection_progress']}
        self.assertEqual(set(progress['quiet']), set(quiet))
        self.assertEqual(set(progress['work']), set(work))

    def test_collection_switch_failure_is_transactional(self):
        self.make_collections()
        self.cmd('use', 'quiet')
        before = self.state()
        self.cmd('use', 'unknown', ok=False)
        self.assertEqual(self.state(), before)
        for path in self.work_pics:
            Path(path).unlink()
        self.cmd('use', 'work', ok=False)
        self.assertEqual(self.state(), before)
        Path(self.work_pics[0]).touch()
        (self.root / 'fail').write_text('*')
        self.cmd('use', 'work', ok=False)
        self.assertEqual(self.state(), before)

    def test_partial_collection_switch_and_holds(self):
        self.make_collections()
        self.cmd('use', 'quiet')
        previous = self.shown()['HDMI-A-1']
        self.cmd('hold')
        (self.root / 'fail').write_text('HDMI-A-1')
        result = self.cmd('use', 'work', ok=False)
        self.assertIn('active collection: work', result.stderr)
        self.assertEqual(self.state()['collection'], 'work')
        self.assertIn(self.shown()['DP-1'], self.work_pics)
        self.assertEqual(self.shown()['HDMI-A-1'], previous)
        self.assertEqual(self.state()['holds'][0]['until'], -1)

    def test_default_collection_and_restart_selection(self):
        self.make_collections(default='quiet')
        self.cmd('next')
        self.assertIn(self.shown()['DP-1'], self.quiet_pics)
        self.cmd('use', 'work')
        selected = self.shown()
        progress = self.state()['collection_progress']
        self.start()
        self.assertEqual(self.shown(), selected)
        self.assertEqual(self.state()['collection_progress'], progress)
        self.assertEqual(json.loads(self.cmd('status', '--json').stdout)['collection'], 'work')
        self.cmd('use', 'default')
        self.assertIn(self.shown()['DP-1'], self.pics)

    def test_collection_reload_protects_active_and_updates_interval(self):
        self.make_collections()
        self.cmd('use', 'quiet')
        self.start()
        self.config(extra=f'[collection.work]\ndir={self.work}\n')
        result = self.cmd('reload', ok=False)
        self.assertIn('remove active collection', result.stderr)
        self.assertEqual(json.loads(self.cmd('status', '--json').stdout)['collection'], 'quiet')
        self.config(extra=self.collection_sections.replace('45m', '15m'))
        self.cmd('reload')
        self.assertEqual(json.loads(self.cmd('status', '--json').stdout)['interval_seconds'], 900)
        self.cmd('use', 'work')
        self.config(extra=f'[collection.work]\ndir={self.work}\n')
        self.cmd('reload')
        self.assertEqual([c['name'] for c in json.loads(self.cmd('collections', '--json').stdout)], ['default', 'work'])

    def test_collection_interval_drives_daemon_rotation(self):
        self.make_collections(interval='1s')
        self.cmd('use', 'work')
        selected = self.shown()['DP-1']
        self.start()
        deadline = time.monotonic() + 5
        while self.shown()['DP-1'] == selected and time.monotonic() < deadline:
            time.sleep(.1)
        self.assertNotEqual(self.shown()['DP-1'], selected)
        self.assertIn(self.shown()['DP-1'], self.work_pics)

    def test_collection_inheritance_and_recursion(self):
        self.make_collections()
        nested = self.quiet / 'nested'
        nested.mkdir()
        path = nested / 'nested.png'
        path.touch()
        self.config(interval='12m', extra=f'recursive=true\n[collection.quiet]\ndir={self.quiet}\n[collection.work]\ndir={self.work}\nrecursive=false\n')
        entries = json.loads(self.cmd('collections', '--json').stdout)
        self.assertEqual(entries[1]['interval_seconds'], 720)
        self.assertTrue(entries[1]['recursive'])
        self.assertFalse(entries[2]['recursive'])
        self.assertIn(str(path), json.loads(self.cmd('list', 'quiet', '--json').stdout))

    def test_legacy_v1_state_upgrades_preserving_default_progress(self):
        self.cmd('next')
        old = self.state()
        old['version'] = 1
        old.pop('collection')
        old.pop('collection_progress')
        old.pop('schedule_cursor')
        path = self.root / 'state' / 'zpaper' / 'state.json'
        path.write_text(json.dumps(old))
        self.cmd('next')
        updated = self.state()
        self.assertEqual(updated['version'], 4)
        self.assertEqual(updated['collection'], 'default')
        self.assertEqual(len(updated['seen']), 2)
        self.assertIn(old['seen'][0], updated['seen'])

    def test_missing_saved_collection_can_be_recovered(self):
        self.make_collections()
        self.cmd('use', 'quiet')
        self.config()
        status = json.loads(self.cmd('status', '--json').stdout)
        self.assertEqual(status['collection'], 'quiet')
        self.assertFalse(status['collection_available'])
        self.assertIn("saved collection 'quiet'", self.cmd('daemon', ok=False).stderr)
        self.cmd('next', ok=False)
        self.cmd('use', 'default')
        self.assertIn(self.shown()['DP-1'], self.pics)


    def enable_schedule(self, collection='quiet'):
        self.make_collections()
        self.cfg.write_text(self.cfg.read_text() + f'[schedule]\n00:00 = {collection}\n')

    def wait_collection(self, name):
        deadline = time.monotonic() + 7
        while time.monotonic() < deadline:
            status = json.loads(self.cmd('status', '--json').stdout)
            if status['collection'] == name:
                return status
            time.sleep(.1)
        self.fail(f'daemon did not switch to {name}')

    def assign_outputs(self, extra='', interval='0', **assignments):
        self.make_collections(interval=interval)
        sections = ''.join(f'[output.{output}]\ncollection = {name}\n' for output, name in assignments.items())
        self.config(extra=extra + self.collection_sections + sections, interval=interval)

    def test_reload_switches_reassigned_outputs_now(self):
        self.assign_outputs()
        self.cmd('set', self.pics[2], self.pics[3])
        self.start()
        self.assign_outputs(**{'HDMI-A-1': 'work'})
        result = self.cmd('reload').stdout
        self.assertIn('HDMI-A-1:', result)
        self.assertIn(self.shown()['HDMI-A-1'], self.work_pics)
        self.assertEqual(self.shown()['DP-1'], self.pics[2])
        # A second reload without changes leaves the wallpaper alone.
        shown = self.shown()
        self.cmd('reload')
        self.assertEqual(self.shown(), shown)
        # Removing the section returns the output to the active collection.
        self.assign_outputs()
        self.cmd('reload')
        self.assertIn(self.shown()['HDMI-A-1'], self.pics)
        self.assertEqual(self.shown()['DP-1'], self.pics[2])

    def test_reload_keeps_held_output_on_reassignment(self):
        self.assign_outputs()
        self.cmd('set', self.pics[2], self.pics[3])
        self.start()
        self.cmd('hold', '--output', 'HDMI-A-1')
        self.assign_outputs(**{'HDMI-A-1': 'work', 'DP-1': 'quiet'})
        self.cmd('reload')
        self.assertEqual(self.shown()['HDMI-A-1'], self.pics[3])
        self.assertIn(self.shown()['DP-1'], self.quiet_pics)

    def test_output_collection_rotation_draws_per_monitor(self):
        self.assign_outputs(**{'HDMI-A-1': 'work'})
        for _ in range(4):
            self.cmd('next')
            self.assertIn(self.shown()['DP-1'], self.pics)
            self.assertIn(self.shown()['HDMI-A-1'], self.work_pics)
        progress = {entry['name']: entry['seen'] for entry in self.state()['collection_progress']}
        self.assertTrue(set(progress['work']) <= set(self.work_pics))
        self.assertTrue(set(self.state()['seen']) <= set(self.pics))

    def test_output_collection_next_for_one_output(self):
        self.assign_outputs(**{'HDMI-A-1': 'work'})
        self.cmd('set', self.pics[2])
        self.cmd('next', '--output', 'HDMI-A-1')
        self.assertEqual(self.shown()['DP-1'], self.pics[2])
        self.assertIn(self.shown()['HDMI-A-1'], self.work_pics)

    def test_use_only_changes_unassigned_outputs(self):
        self.assign_outputs(**{'HDMI-A-1': 'work'})
        self.cmd('next')
        kept = self.shown()['HDMI-A-1']
        self.cmd('use', 'quiet')
        self.assertIn(self.shown()['DP-1'], self.quiet_pics)
        self.assertEqual(self.shown()['HDMI-A-1'], kept)
        status = json.loads(self.cmd('status', '--json').stdout)
        self.assertEqual(status['collection'], 'quiet')
        self.assertEqual(status['output_collections'], [{'output': 'HDMI-A-1', 'collection': 'work'}])
        listing = self.cmd('collections').stdout
        self.assertIn('outputs HDMI-A-1', listing)

    def test_use_with_every_output_assigned_switches_without_change(self):
        self.assign_outputs(**{'DP-1': 'work', 'HDMI-A-1': 'work'})
        self.cmd('next')
        before = self.shown()
        result = self.cmd('use', 'quiet')
        self.assertIn('own collection', result.stdout)
        self.assertEqual(self.shown(), before)
        self.assertEqual(json.loads(self.cmd('status', '--json').stdout)['collection'], 'quiet')

    def test_schedule_with_every_output_assigned_does_not_stall_rotation(self):
        self.assign_outputs(interval='1s', **{'DP-1': 'work', 'HDMI-A-1': 'work'})
        self.cfg.write_text(self.cfg.read_text() + '[schedule]\n00:00 = quiet\n')
        self.start()
        self.wait_collection('quiet')
        self.assertTrue(self.wait_for(lambda: self.shown()['DP-1'] in self.work_pics), self.shown())
        selected = self.shown()['DP-1']
        self.assertTrue(self.wait_for(lambda: self.shown()['DP-1'] != selected))
        self.assertIn(self.shown()['DP-1'], self.work_pics)

    def test_assigned_collection_rotates_on_its_own_interval(self):
        self.make_collections(interval='1s')  # work rotates every second
        self.config(extra=self.collection_sections + '[output.HDMI-A-1]\ncollection = work\n')  # global interval 0
        self.cmd('next')
        main = self.shown()['DP-1']
        side = self.shown()['HDMI-A-1']
        self.start()
        self.assertTrue(self.wait_for(lambda: self.shown()['HDMI-A-1'] != side), self.shown())
        self.assertIn(self.shown()['HDMI-A-1'], self.work_pics)
        self.assertEqual(self.shown()['DP-1'], main)
        self.assertIn('rotation work: every 1s', self.cmd('status').stdout)
        self.cmd('hold', '--output', 'HDMI-A-1')
        held = self.shown()['HDMI-A-1']
        time.sleep(2.5)
        self.assertEqual(self.shown()['HDMI-A-1'], held)

    def test_hotplug_new_output_uses_its_collection(self):
        self.assign_outputs(**{'DP-2': 'work'})
        self.cmd('set', self.pics[2])
        self.start()
        time.sleep(2.5)
        shown = self.shown()
        shown['DP-2'] = ''
        self.display.write_text(json.dumps(shown))
        self.assertTrue(self.wait_for(lambda: self.shown().get('DP-2') in self.work_pics), self.shown())

    def test_output_sections_ignored_for_global_backend(self):
        # One config shared by a Wayland and an X11 session.
        self.make_collections()
        self.config(extra=self.collection_sections + '[output.DP-1]\ncollection = work\n', backend='feh')
        self.assertIn('sections are ignored', self.cmd('check').stdout)
        self.cmd('next')
        self.assertEqual(len(self.feh_calls()), 1)
        status = self.cmd('status').stdout
        self.assertIn('sections are ignored', status)
        self.assertNotIn('[collection', status)

    def test_schedule_startup_and_inspection(self):
        self.enable_schedule()
        result = json.loads(self.cmd('schedule', '--json').stdout)
        self.assertTrue(result['status']['enabled'])
        self.assertEqual(result['status']['current']['collection'], 'quiet')
        self.assertTrue(result['status']['pending'])
        self.assertEqual(result['rules'], [{'minute': 0, 'collection': 'quiet'}])
        self.start()
        self.wait_collection('quiet')
        self.assertIn(self.shown()['DP-1'], self.quiet_pics)
        self.assertFalse(self.state()['schedule_cursor']['manual'])

    def test_schedule_manual_override_survives_restart_and_can_resume(self):
        self.enable_schedule()
        self.cmd('use', 'work')
        before = self.shown()
        self.assertTrue(self.state()['schedule_cursor']['manual'])
        self.start()
        self.assertEqual(self.shown(), before)
        self.assertEqual(json.loads(self.cmd('status', '--json').stdout)['collection'], 'work')
        self.cmd('schedule', 'resume')
        self.assertIn(self.shown()['DP-1'], self.quiet_pics)
        self.assertFalse(self.state()['schedule_cursor']['manual'])

    def test_schedule_catches_up_after_missed_days(self):
        self.enable_schedule()
        self.cmd('use', 'work')
        saved = self.state()
        saved['schedule_cursor']['key'] -= 3 * 1440
        (self.root / 'state' / 'zpaper' / 'state.json').write_text(json.dumps(saved))
        self.start()
        self.wait_collection('quiet')
        self.assertIn(self.shown()['DP-1'], self.quiet_pics)
        self.assertEqual(len(self.state()['layouts']), len(saved['layouts']) + 1)

    def test_schedule_respects_global_hold_then_catches_up(self):
        self.enable_schedule()
        self.cmd('set', self.pics[2])
        self.cmd('hold')
        self.cmd('schedule', 'resume')
        self.start()
        self.assertEqual(self.shown()['DP-1'], self.pics[2])
        self.assertIsNone(self.state()['schedule_cursor'])
        self.cmd('resume')
        self.wait_collection('quiet')
        self.assertIn(self.shown()['DP-1'], self.quiet_pics)

    def test_schedule_preserves_output_holds(self):
        self.enable_schedule()
        self.cmd('set', self.pics[0])
        self.cmd('hold', '--output', 'DP-1')
        self.cmd('schedule', 'resume')
        self.assertEqual(self.shown()['DP-1'], self.pics[0])
        self.assertIn(self.shown()['HDMI-A-1'], self.quiet_pics)
        self.assertEqual(self.state()['collection'], 'quiet')

    def test_schedule_all_outputs_held_defers_switch(self):
        self.enable_schedule()
        self.cmd('use', 'work')
        before = self.shown()
        self.cmd('hold', '--output', 'DP-1,HDMI-A-1')
        self.cmd('schedule', 'resume')
        self.assertEqual(self.shown(), before)
        self.assertEqual(self.state()['collection'], 'work')
        self.assertIsNone(self.state()['schedule_cursor'])
        self.start()
        self.cmd('resume', '--output', 'HDMI-A-1')
        self.wait_collection('quiet')
        self.assertEqual(self.shown()['DP-1'], before['DP-1'])

    def test_schedule_backend_failure_does_not_consume_occurrence(self):
        self.enable_schedule()
        self.cmd('use', 'work')
        before = self.state()
        (self.root / 'fail').write_text('*')
        result = self.cmd('schedule', 'resume', ok=False)
        self.assertIn('deliberate backend failure', result.stderr)
        self.assertEqual(self.state(), before)
        (self.root / 'fail').unlink()
        self.cmd('schedule', 'resume')
        self.assertEqual(self.state()['collection'], 'quiet')

    def test_schedule_reload_reconciles_new_policy_and_rejects_bad_rules(self):
        self.enable_schedule()
        self.start()
        self.wait_collection('quiet')
        valid = self.cfg.read_text()
        self.cfg.write_text(valid.replace('00:00 = quiet', '00:00 = missing'))
        self.cmd('reload', ok=False)
        self.assertEqual(json.loads(self.cmd('schedule', '--json').stdout)['rules'][0]['collection'], 'quiet')
        self.cfg.write_text(valid.replace('00:00 = quiet', '00:00 = work'))
        self.cmd('reload')
        self.wait_collection('work')
        self.assertIn(self.shown()['DP-1'], self.work_pics)

    def test_schedule_same_collection_restores_on_restart(self):
        self.enable_schedule()
        self.cmd('schedule', 'resume')
        expected = self.shown()
        self.display.write_text(json.dumps({'DP-1': self.pics[0], 'HDMI-A-1': self.pics[0]}))
        self.start()
        self.assertEqual(self.shown(), expected)
        self.assertFalse(self.state()['schedule_cursor']['manual'])

    def test_schedule_without_rules_is_optional(self):
        result = json.loads(self.cmd('schedule', '--json').stdout)
        self.assertFalse(result['status']['enabled'])
        self.cmd('schedule', 'resume', ok=False)
        self.cmd('schedule', 'bogus', ok=False)
        self.cmd('schedule', 'resume', '--json', ok=False)

    def test_backend_autostart_detaches_output_and_preserves_logs(self):
        self.config(extra='backend_start = true\n')
        # Replace the duplicate false setting rather than allowing duplicate keys.
        self.cfg.write_text(self.cfg.read_text().replace('backend_start = false\n', ''))
        client = self.bin / 'awww'
        client.write_text(FAKE.replace("if args == ['query']:", "if args == ['query'] and not (root / 'backend-ready').exists():\n    sys.exit(1)\nif args == ['query']:"))
        daemon = self.bin / 'awww-daemon'
        daemon.write_text("""#!/usr/bin/env python3
import os, pathlib, time
root = pathlib.Path(os.environ['FAKE_ROOT'])
(root / 'backend.pid').write_text(str(os.getpid()))
print('fake renderer started', flush=True)
(root / 'backend-ready').touch()
for _ in range(200):
    if (root / 'write-log').exists():
        os.write(2, b'fake renderer still alive\\n')
        (root / 'logged').touch()
        break
    time.sleep(.05)
time.sleep(10)
""")
        daemon.chmod(0o755)
        try:
            self.cmd('set', self.pics[2])
            (self.root / 'write-log').touch()
            deadline = time.monotonic() + 3
            while not (self.root / 'logged').exists() and time.monotonic() < deadline:
                time.sleep(.05)
            self.assertTrue((self.root / 'logged').exists(), 'renderer lost its logging pipe')
            log = self.root / 'state' / 'zpaper' / 'awww-daemon.log'
            self.assertIn('fake renderer started', log.read_text())
            self.assertIn('fake renderer still alive', log.read_text())
            self.assertEqual(log.stat().st_mode & 0o777, 0o600)
        finally:
            pidfile = self.root / 'backend.pid'
            if pidfile.exists():
                try:
                    os.kill(int(pidfile.read_text()), 9)
                except ProcessLookupError:
                    pass

    def custom_program(self, body):
        program = self.bin / 'migration-setter'
        program.write_text('#!/usr/bin/env python3\nimport os, pathlib, time\n' + body)
        program.chmod(0o755)
        self.config(backend='custom', extra=f'setter = {program} %s\n')

    def test_subprocess_failed_exec_does_not_leak_daemon_resources(self):
        self.config(backend='custom', extra='setter = /nonexistent/zpaper-setter %s\n')
        self.start()
        fds = Path(f'/proc/{self.proc.pid}/fd')
        children = Path(f'/proc/{self.proc.pid}/task/{self.proc.pid}/children')
        baseline = len(list(fds.iterdir()))
        missing_interpreter = self.bin / 'missing-interpreter'
        missing_interpreter.write_text('#!/nonexistent/zpaper-interpreter\n')
        missing_interpreter.chmod(0o755)
        not_executable = self.bin / 'not-executable'
        not_executable.write_text('not executable')
        not_executable.chmod(0o600)
        for executable in ('/nonexistent/zpaper-setter', missing_interpreter, not_executable):
            with self.subTest(executable=executable):
                self.config(backend='custom', extra=f'setter = {executable} %s\n')
                self.cmd('reload')
                for _ in range(8):
                    self.assertIn('cannot execute', self.cmd('set', self.pics[0], ok=False).stderr)
        self.cmd('status')
        time.sleep(.1)
        self.assertEqual(children.read_text().strip(), '')
        self.assertLessEqual(len(list(fds.iterdir())), baseline + 1)

    def test_subprocess_drains_both_pipes(self):
        self.custom_program("for _ in range(32):\n    os.write(1, b'o' * 8192)\n    os.write(2, b'e' * 8192)\n")
        self.cmd('set', self.pics[0])
        self.assertEqual(self.state()['current'][0]['image'], self.pics[0])

    def test_subprocess_output_limits_preserve_state(self):
        self.cmd('set', self.pics[0])
        saved = self.state()
        for fd in (1, 2):
            with self.subTest(fd=fd):
                self.custom_program(f'while True:\n    os.write({fd}, b"x" * 8192)\n')
                result = self.cmd('set', self.pics[1], ok=False)
                self.assertIn('output exceeds 1 MiB', result.stderr)
                self.assertEqual(saved, self.state())

    def test_subprocess_closed_pipes_still_has_deadline(self):
        self.custom_program('os.close(1)\nos.close(2)\ntime.sleep(30)\n')
        start = time.monotonic()
        result = self.cmd('set', self.pics[0], ok=False)
        self.assertIn('timed out', result.stderr)
        self.assertLess(time.monotonic() - start, 4)

    def test_subprocess_descendant_pipe_timeout_kills_group(self):
        pidfile = self.root / 'descendant.pid'
        self.custom_program(f'''pid = os.fork()
if pid:
    pathlib.Path({str(pidfile)!r}).write_text(str(pid))
    os._exit(0)
time.sleep(30)
''')
        try:
            start = time.monotonic()
            result = self.cmd('set', self.pics[0], ok=False)
            self.assertIn('timed out', result.stderr)
            self.assertLess(time.monotonic() - start, 4)
            pid = int(pidfile.read_text())
            proc = Path(f'/proc/{pid}/stat')

            def gone():
                # The process can be reaped between checks; treat that as gone.
                try:
                    return proc.read_text().split()[2] == 'Z'
                except (FileNotFoundError, ProcessLookupError):
                    return True
            deadline = time.monotonic() + 2
            while not gone() and time.monotonic() < deadline:
                time.sleep(.02)
            self.assertTrue(gone(), 'descendant survived timeout')
        finally:
            if pidfile.exists():
                try:
                    os.kill(int(pidfile.read_text()), 9)
                except ProcessLookupError:
                    pass

    def test_socket_fragmented_request_and_idle_timeout(self):
        self.start()
        path = next(self.runtime.glob('*/control.sock'))
        with socket.socket(socket.AF_UNIX) as peer:
            peer.settimeout(8)
            peer.connect(str(path))
            peer.sendall(b'{"action":')
            time.sleep(.1)
            peer.sendall(b'"status"}\n')
            data = b''
            while b'\n' not in data:
                data += peer.recv(8192)
            self.assertTrue(json.loads(data)['ok'])
        with socket.socket(socket.AF_UNIX) as peer:
            peer.settimeout(8)
            peer.connect(str(path))
            peer.sendall(b'{')
            self.assertEqual(peer.recv(8192), b'')
        self.cmd('status')
        self.cmd('stop')
        self.proc.wait(timeout=5)
        self.assertFalse(path.exists())

    def test_legacy_v2_state_preserves_collection_progress(self):
        self.make_collections()
        self.cmd('use', 'quiet')
        old = self.state()
        old['version'] = 2
        old.pop('schedule_cursor')
        path = self.root / 'state' / 'zpaper' / 'state.json'
        path.write_text(json.dumps(old))
        self.cmd('hold')
        updated = self.state()
        self.assertEqual(updated['version'], 4)
        self.assertEqual(updated['collection'], old['collection'])
        self.assertEqual(updated['collection_progress'], old['collection_progress'])
        self.assertEqual(updated['current'], old['current'])


if __name__ == '__main__':
    unittest.main(verbosity=2)
