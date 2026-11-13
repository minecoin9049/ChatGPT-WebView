"""Preserve the upstream app icon, without using its executable or entitlements."""
import pathlib
import plistlib
import shutil
import zipfile

app = pathlib.Path('build/Build/Products/Release-iphoneos/ChatGPTCompat.app')
assert (app / 'ChatGPTCompat').is_file()
assert (app / 'Mobile.js').is_file(), 'Mobile.js must be a bundled resource'
info_path = app / 'Info.plist'
info = plistlib.loads(info_path.read_bytes())
assert info['MinimumOSVersion'] == '16.0', info['MinimumOSVersion']
assert info['CFBundleShortVersionString'] == '0.3'
assert info['CFBundleVersion'] == '3'

with zipfile.ZipFile('ChatGPTWebView.ipa') as ipa:
    infos = [n for n in ipa.namelist() if n.startswith('Payload/') and n.endswith('.app/Info.plist') and n.count('/') == 2]
    assert len(infos) == 1, infos
    original = plistlib.loads(ipa.read(infos[0]))
    prefix = infos[0].rsplit('/', 1)[0] + '/'
    icon_keys = ['CFBundleIcons', 'CFBundleIcons~ipad', 'CFBundleIconFiles', 'CFBundleIconFile', 'CFBundleIconName']
    copied_keys = []
    for key in icon_keys:
        if key in original:
            info[key] = original[key]
            copied_keys.append(key)
    assert copied_keys, 'Original IPA has no icon metadata'
    copied_assets = []
    for name in ipa.namelist():
        if not name.startswith(prefix):
            continue
        relative = name[len(prefix):]
        if '/' not in relative and (relative == 'Assets.car' or relative.lower().endswith('.png')):
            (app / relative).write_bytes(ipa.read(name))
            copied_assets.append(relative)
    assert copied_assets, 'Original icon assets missing'
    print('Restored upstream icon metadata:', copied_keys)
    print('Restored original artwork:', copied_assets)

info_path.write_bytes(plistlib.dumps(info, fmt=plistlib.FMT_BINARY))
payload = pathlib.Path('Payload')
payload.mkdir(exist_ok=True)
shutil.copytree(app, payload / app.name, dirs_exist_ok=True)
with zipfile.ZipFile('ChatGPTCompat-0.3.ipa', 'w', compression=zipfile.ZIP_DEFLATED) as out:
    for file in sorted(payload.rglob('*')):
        if file.is_file():
            out.write(file, file.as_posix())
print('Validated iOS 16 build, Mobile.js, version, icon and IPA layout')
