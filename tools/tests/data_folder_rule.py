# The data folder rule and the app's wiring, checked from the source (run_mode2 stage 1 and update_check.sh):
# only the app picks the real data folder, before it makes anything that reads it.
import os
os.chdir(os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..'))
from pathlib import Path
s = Path('app/macos/main.swift').read_text()
call, start = s.find('AccountStore.useRealHome()'), s.find('AppDelegate()')
assert 0 <= call < start, 'main.swift must call AccountStore.useRealHome() before AppDelegate()'
assert s.count('useRealHome()') == 1, 'only main.swift chooses the real data folder'
import subprocess
users = subprocess.run(['grep', '-rl', '--include=*.swift', 'useRealHome()', 'app', 'tools'], capture_output=True, text=True).stdout.split()
assert sorted(users) == ['app/macos/main.swift', 'app/modules/AIAccounts/Accounts.swift', 'tools/tests/real_home.swift'], users
# The runtime's one public test hook (a fake CLI for runtime_contract.swift) is never set by the app.
hooked = subprocess.run(['grep', '-rl', '--include=*.swift', 'toolForTests', 'app/macos'], capture_output=True, text=True).stdout.split()
assert hooked == [], hooked
# C0: every `extension Discussion` is classified in docs/modules-history.md ("Chat, step C0"): a = Chat takes it whole, b = a shell
# whose logic is another module's public function. A new block fails here until it gets its row (and the table).
import glob, re
expected = {'AgentRooms': 'a', 'Attachments': 'aaa', 'ChatFind': 'a', 'ChatSearch': 'a', 'ChatTools': 'a', 'Collaboration': 'a', 'Debate': 'a', 'Delegate': 'b',
            'DeviceSync': 'a', 'Enterprise': 'ab', 'Meeting': 'ba', 'Peer': 'b', 'ProjectChat': 'b', 'ProjectCreate': 'b',
            'RoomDocuments': 'a', 'Route': 'a', 'SidebarProjects': 'a', 'Solo': 'aa', 'SpaceView': 'b', 'SubRoomViews': 'a', 'TodoChatsApp': 'a', 'Vote': 'a'}
def blocks(text):
    lines, out, i = text.split('\n'), [], 0
    while i < len(lines):
        if lines[i].startswith('extension Discussion'):
            j = i
            while lines[j] != '}': j += 1
            out.append('\n'.join(lines[i:j + 1])); i = j
        i += 1
    return out
# C1: the blocks live in AIChat now (with Discussion's state); the app adds none (it sees only public names).
assert not [f for f in glob.glob('app/macos/*.swift') if blocks(Path(f).read_text())], 'the app has no extension Discussion (C1)'
found = {Path(f).stem: blocks(Path(f).read_text()) for f in sorted(glob.glob('app/modules/AIChat/*.swift'))}
found = {k: v for k, v in found.items() if v}
assert {k: len(v) for k, v in found.items()} == {k: len(v) for k, v in expected.items()}, ({k: len(v) for k, v in found.items()}, 'classify new extension Discussion blocks in docs/MODULES.md')
assert sum(len(v) for v in found.values()) == 27, 'the C0 table has 27 rows'
# The chat side calls none of these by name: the app connects them (ChatLinksApp.swift) or the module reads them.
direct = re.compile(r'PlanLink|DeviceSync\b(?!\.swift)|NativeSessions\.purgeRoom|WorkspaceBackup\.purgeRoom|RoomDocuments\.directory')
chat = Path('app/modules/AIChat/Discussion.swift').read_text()
hits = [m.group() for m in direct.finditer(chat)] + [(k, m.group()) for k, v in found.items() for b in v for m in direct.finditer(b)]
assert hits == [], hits
call, start = s.find('ChatLinksApp.connect()'), s.find('AppDelegate()')
assert 0 <= s.find('useRealHome()') < call < start and s.count('ChatLinksApp.connect()') == 1, 'main.swift connects the chat store once, before AppDelegate()'
screens = s.find('ChatScreensApp.connect()')
assert call < screens < start and s.count('ChatScreensApp.connect()') == 1, 'main.swift connects the chat window to the app screens once, before AppDelegate()'
# I: Integrations (outside MCP, AI Face, Mac control) holds no tool provider: ToolHub's providers are the app's or a feature
# module's. Only the app imports it; it depends on lower modules only.
import os
integ = sorted(glob.glob('app/modules/AIIntegrations/*.swift'))
assert integ and not [f for f in integ if re.search(r'\bToolProvider\b|\bToolHub\b|\bToolContext\b', Path(f).read_text())], 'no tool provider in AIIntegrations'
assert Path('app/modules/AIIntegrations/dependencies').read_text().split() == ['AIAccounts', 'AILocalization', 'AIRuntime', 'AIWorkspace']
assert [f for f in glob.glob('app/modules/*/*.swift') if re.search(r'^import AIIntegrations', Path(f).read_text(), re.M)] == [], 'feature modules do not import AIIntegrations'
assert all(f'extension {n}: @retroactive ToolProvider' in Path('app/macos/' + f).read_text() for n, f in
           [('FaceLink', 'ToolHub.swift'), ('ExternalMCP', 'ExternalMCPTools.swift')]), 'the app makes the two providers'
# AI Face's link starts after the bridge's sockets (FaceLink no longer opens them itself).
assert s.find('ToolHub.shared.start()') < s.find('ToolHub.shared.startLegacyFaceSocket(at: FaceLink.socketPath)') < s.find('FaceLink.shared.start()')
# The 13 tool providers in their order (first(where:) picks by it): the app lists them, six are AIChat's (DelegateLink since sub-room P2).
hub = Path('app/macos/ToolHub.swift').read_text()
order = re.search(r'static var appProviders: \[ToolProvider\] \{ \[(.*?)\] \}', hub).group(1).replace(' ', '').split(',')
assert order == ['FaceLink.shared', 'GitLink.shared', 'PlanLink.shared', 'PeerLink.shared', 'ConveneLink.shared', 'DelegateLink.shared', 'ChatLink.shared',
                 'MemoryLink.shared', 'ProjectMakerLink.shared', 'TaskLink.shared', 'TodoAddLink.shared', 'StorageLink.shared', 'ExternalMCP.shared'], order
# App files see a module's public names only; @testable is for tests.
assert subprocess.run(['grep', '-rl', '@testable', 'app'], capture_output=True, text=True).stdout.split() == [], 'no @testable import in app files'
