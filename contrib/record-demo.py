#!/usr/bin/env python3
"""Generate the README demo from real CLI calls and isolated mock displays.

Needs a built zpaper, Python 3 and Pillow. Uses the integration fixtures, never
real HOME/XDG paths or a real renderer. The picker selection is scripted.
"""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import textwrap
from PIL import Image, ImageDraw, ImageFont

ROOT = Path(__file__).resolve().parent.parent
SIZE = (1080, 700)
BG, PANEL, FG, MUTED, ACCENT = '#101b24', '#1a2a36', '#edf4f0', '#a0b5c2', '#80dfb0'


def font(size, mono=False):
    name = 'DejaVuSansMono.ttf' if mono else 'DejaVuSans.ttf'
    path = Path('/usr/share/fonts/truetype/dejavu') / name
    if not path.exists():
        path = Path('/usr/share/fonts/TTF') / name
    return ImageFont.truetype(str(path), size) if path.exists() else ImageFont.load_default(size=size)


def wallpaper(path, colors, variant):
    # Deliberately simple generated placeholders, not screenshots of a desktop.
    image = Image.new('RGB', (440, 220), colors[0])
    draw = ImageDraw.Draw(image)
    draw.ellipse((300, 20, 375, 95), fill=colors[1])
    draw.polygon([(0, 220), (0, 155), (100 + variant * 25, 55), (250, 220)], fill=colors[2])
    draw.polygon([(125, 220), (300 - variant * 20, 95), (440, 175), (440, 220)], fill=colors[3])
    image.save(path)


def frame(title, command, output, shown, picker=None):
    image = Image.new('RGB', SIZE, BG)
    draw = ImageDraw.Draw(image)
    draw.text((40, 24), 'zpaper', font=font(33), fill=FG)
    draw.text((40, 70), title, font=font(24), fill=ACCENT)
    draw.text((650, 36), 'WALLPAPER ROTATION WITH MEMORY', font=font(14), fill=MUTED)
    for i, (name, collection) in enumerate([('DP-1', 'landscapes'), ('HDMI-A-1', 'portraits')]):
        x, y = 40 + i * 520, 125
        draw.rounded_rectangle((x, y, x + 480, y + 265), radius=12, fill=PANEL)
        path = Path(shown[name])
        with Image.open(path) as wallpaper_image:
            image.paste(wallpaper_image.resize((440, 220)), (x + 20, y + 15))
        draw.text((x + 20, y + 239), f'{name}  /  {collection}  /  {path.stem}', font=font(14), fill=FG)
    draw.rounded_rectangle((40, 415, 1040, 635), radius=12, fill='#091218')
    draw.text((60, 435), '$ ' + command, font=font(21, True), fill=ACCENT)
    lines = output.strip().splitlines()
    if picker:
        lines = picker + lines
    wrapped = [part for line in lines for part in textwrap.wrap(line, width=79) or ['']]
    for i, line in enumerate(wrapped[:6]):
        draw.text((60, 475 + i * 23), line, font=font(17, True), fill=FG)
    draw.text((40, 661), 'Real CLI run • mock renderer • scripted picker • generated placeholder images', font=font(15), fill=MUTED)
    return image


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', type=Path, default=ROOT / 'zig-out/bin/zpaper')
    parser.add_argument('--output', type=Path, default=ROOT / 'docs/media/demo.gif')
    args = parser.parse_args()
    os.environ['ZPAPER_BIN'] = str(args.binary.resolve())
    spec = importlib.util.spec_from_file_location('zpaper_integration', ROOT / 'tests/integration.py')
    fixtures = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(fixtures)
    case = fixtures.Integration()
    case.setUp()
    frames, transcript = [], []
    try:
        folders = [case.root / 'landscapes', case.root / 'portraits']
        palettes = [('#8abcb7', '#f8dc8a', '#426f78', '#274d64'), ('#bfa4bf', '#f6d6b4', '#755777', '#493d60')]
        for folder, palette, names in zip(folders, palettes, [('alpine', 'dunes'), ('fern', 'iris')]):
            folder.mkdir()
            for i, name in enumerate(names):
                wallpaper(folder / f'{name}.png', palette, i)
        case.config(extra=f'''hotplug = false
[collection.landscapes]
dir = "{folders[0]}"
interval = 30m
[collection.portraits]
dir = "{folders[1]}"
interval = 45m
[output.DP-1]
collection = landscapes
[output.HDMI-A-1]
collection = portraits
''')
        # Start from a known layout; next then picks the other image in each
        # collection, so the recording is reproducible despite random selection.
        case.cmd('set', str(folders[0] / 'alpine.png'), str(folders[1] / 'fern.png'))
        case.start()

        def capture(title, command, result, picker=None):
            output = result.stdout.replace(str(case.root) + '/', 'demo/')
            shown = case.shown()
            frames.append(frame(title, command, output, shown, picker))
            transcript.append({'title': title, 'command': command, 'stdout': output,
                               'display': {k: str(Path(v).relative_to(case.root)) for k, v in shown.items()},
                               'picker': picker})

        capture('Two monitors. Independent collections.', 'zpaper next', case.cmd('next'))
        both = case.shown()
        capture('Rotate just the landscape monitor.', 'zpaper next --output DP-1', case.cmd('next', '--output', 'DP-1'))
        assert case.shown()['HDMI-A-1'] == both['HDMI-A-1']
        capture('Undo restores the previous desktop layout.', 'zpaper previous', case.cmd('previous'))
        assert case.shown() == both
        result = case.pick('--browse', picks=['HDMI-A-1', 'fern.png'], preview='')
        assert case.shown()['HDMI-A-1'] == str(folders[1] / 'fern.png')
        capture('Pick a monitor, then an image.', 'zpaper-pick --browse', result,
                ['Monitor> HDMI-A-1', 'Image>   fern.png  (collection portraits)'])
        capture('Keep one monitor steady for two hours.', 'zpaper hold 2h --output HDMI-A-1', case.cmd('hold', '2h', '--output', 'HDMI-A-1'))
        report = json.loads(case.cmd('explain', '--output', 'HDMI-A-1', '--json').stdout)['outputs'][0]
        assert report['held'] and report['collection'] == 'portraits'
        # Text is verbatim CLI output; first six lines fit the terminal panel.
        capture('See the policy behind each output.', 'zpaper explain --output HDMI-A-1', case.cmd('explain', '--output', 'HDMI-A-1'))
    finally:
        case.tearDown()
    args.output.parent.mkdir(parents=True, exist_ok=True)
    frames[0].save(args.output, save_all=True, append_images=frames[1:], duration=[3200] * len(frames), loop=0, optimize=True)
    frames[0].save(args.output.with_suffix('.png'))
    args.output.with_suffix('.json').write_text(json.dumps(transcript, indent=2) + '\n')
    print(f'Wrote {len(frames)} verified frames to {args.output}')


if __name__ == '__main__':
    main()
