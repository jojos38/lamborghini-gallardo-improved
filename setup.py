import shutil
import os
import json
import urllib.request

need_new_ldoc = input('Do you want to update the LDoc files? (Y/n) ')
if need_new_ldoc.lower() == 'Y' or need_new_ldoc.lower() == 'y' or need_new_ldoc == '':
    if os.path.exists('docs'):
        shutil.rmtree('docs')
    if os.path.exists('.vscode'):
        shutil.rmtree('.vscode')
    urllib.request.urlretrieve('https://github.com/shawnjb/BeamNG/archive/refs/heads/master.zip', 'BeamNG.zip')
    shutil.unpack_archive('BeamNG.zip', 'BeamNG')
    os.remove('BeamNG.zip')
    shutil.move('BeamNG/BeamNG-master/src', 'docs')
    shutil.rmtree('BeamNG')
    settings_file_path = '.vscode/settings.json'
    if not os.path.exists(settings_file_path):
        os.makedirs('.vscode')
        with open(settings_file_path, 'w') as f:
            f.write('{}')
    with open(settings_file_path, 'r') as f:
        settings = json.load(f)
    if 'Lua.workspace.library' not in settings:
        settings['Lua.workspace.library'] = []
    settings['Lua.workspace.library'].append(os.getcwd().replace('\\', '/') + '/docs')

need_new_runtime = input('Do you want to update the Lua runtime? (Y/n) ')
if need_new_runtime.lower() == 'Y' or need_new_runtime.lower() == 'y' or need_new_runtime == '':
    settings['Lua.runtime.version'] = 'LuaJIT'

with open(settings_file_path, 'w') as f:
    json.dump(settings, f, indent=4)
