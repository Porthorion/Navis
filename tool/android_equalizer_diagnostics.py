#!/usr/bin/env python3
"""Exercise a running, isolated Android EQ sidecar through its owned API.

The sidecar must contain the two local diagnostics tone fixtures. Never targets
or configures the stable package. Pull its private handshake without printing it.
"""
import argparse
import json
import math
import subprocess
import time
import urllib.request
from pathlib import Path

parser = argparse.ArgumentParser()
parser.add_argument('--handshake', required=True, type=Path)
parser.add_argument('--output', required=True, type=Path)
parser.add_argument('--serial', required=True)
parser.add_argument('--package', default='com.navis.app.navis.eqcheck')
parser.add_argument('--port', default=19484, type=int)
parser.add_argument('--adb', default='adb')
parser.add_argument('--fixture-url')
args = parser.parse_args()
if args.package == 'com.navis.app.navis' or not args.package.startswith('com.navis.app.navis.'):
    parser.error('An isolated sidecar package is required')
args.output.mkdir(parents=True, exist_ok=True)
handshake = json.loads(args.handshake.read_text())
base = f'http://127.0.0.1:{args.port}'
adb = [args.adb, '-s', args.serial]
subprocess.run(adb + ['forward', f'tcp:{args.port}', 'tcp:'+str(handshake['port'])], check=True, stdout=subprocess.DEVNULL)
def api(route, body=None, artifact=None):
    payload = None if body is None else json.dumps(body).encode()
    request = urllib.request.Request(base + route, data=payload,
        headers={'Authorization': 'Bearer '+handshake['token'], 'Content-Type':'application/json'})
    with urllib.request.urlopen(request, timeout=30) as response:
        value = json.load(response)
    if artifact:
        (args.output / (artifact+'.json')).write_text(json.dumps(value, indent=2))
    return value

def settled():
    deadline = time.monotonic()+10
    while time.monotonic() < deadline:
        value = api('/v1/equalizer')
        if not value['application']['pending'] and value['application']['sampleRate']:
            assert value['failure'] is None, value
            assert value['configuration'] == value['persistedConfiguration'], value
            return value
        time.sleep(.1)
    raise AssertionError('EQ did not settle')

api('/v1/health', artifact='health')
if args.fixture_url:
    if not args.fixture_url.startswith('http://127.0.0.1:'):
        parser.error('Only a loopback test fixture is allowed')
    api('/v1/session/connect', {'url':args.fixture_url, 'username':'diagnostics',
        'password':'navis-auth-lifecycle-fixture'}, 'fixture-session')
    api('/v1/presentation/onboarding/complete', {})

api('/v1/playback/queue', {'songIds':['diagnostics-adjustment-tone-1','diagnostics-adjustment-tone-2']}, 'queue')
configuration = {'version':1,'mode':'advanced','enabled':True,'preampDb':0,
    'autoHeadroom':True,'filters':[{'type':'peaking','frequencyHz':440,'gainDb':12,'q':4,'enabled':True}]}
before = api('/v1/playback/status')
api('/v1/equalizer', {'action':'configure','configuration':configuration}, 'enabled')
value = settled()
assert value['application']['enabled'], value
assert math.isclose(value['application']['headroomDb'], -12.5, abs_tol=.01), value
(args.output/'settled.json').write_text(json.dumps(value,indent=2))
after = api('/v1/playback/status', artifact='after-enable')
assert before['queueLength'] == after['queueLength'], (before,after)
for preamp in [-1,-2,-3,-4,-5]:
    configuration['preampDb']=preamp
    api('/v1/equalizer', {'action':'configure','configuration':configuration})
settled()
api('/v1/playback/adjustments', {'speed':1.25,'pitchSemitones':2,'lockPitchToSpeed':False}, 'adjustments')
api('/v1/playback/seek', {'positionMs':15000}, 'seek')
api('/v1/playback/seek', {'positionMs':117000}, 'transition-seek')
deadline=time.monotonic()+15
while time.monotonic()<deadline:
    transition=api('/v1/playback/status')
    if transition['songId']=='diagnostics-adjustment-tone-2' and transition['playing'] and transition['playerPositionMs']>=5000:
        break
    time.sleep(.2)
else:
    raise AssertionError('Track transition did not complete')
api('/v1/equalizer', artifact='transition-equalizer')
assert settled()['application']['enabled']
api('/v1/playback/previous', {}, 'previous')
api('/v1/playback/next', {}, 'next')
settled()
api('/v1/playback/pause', {}, 'pause')
api('/v1/playback/play', {}, 'resume')
current = api('/v1/equalizer')
if any(p['name']=='Android headphones' for p in current['presets']):
    api('/v1/equalizer', {'action':'select','id':next(p['id'] for p in current['presets'] if p['name']=='Android headphones')})
    api('/v1/equalizer', {'action':'configure','configuration':configuration})
    api('/v1/equalizer', {'action':'update'}, 'saved')
else:
    api('/v1/equalizer', {'action':'save','name':'Android headphones'}, 'saved')
api('/v1/equalizer', {'action':'enable','enabled':False}, 'bypass')
assert not settled()['application']['enabled']
api('/v1/equalizer', {'action':'enable','enabled':True})
settled()
navigation = api('/v1/presentation/navigate', {'location':'/settings/equalizer'}, 'navigation')
assert navigation['actualLocation'] == '/settings/equalizer', navigation
api('/v1/presentation/dismiss-popup', {})
shot = api('/v1/presentation/screenshot', {'label':'eq-mobile'}, 'screenshot')
# Read the PNG produced by the app; do not substitute an OS screenshot.
remote = '/data/user/0/'+args.package+'/files/eq-diagnostics/'+shot['artifact']
with (args.output/'eq-mobile.png').open('wb') as output:
    subprocess.run(adb + ['exec-out','run-as',args.package,'cat',remote], check=True, stdout=output)
saved = api('/v1/equalizer')
identity = saved['selectedPresetId']
api('/v1/equalizer', {'action':'select','id':'builtin:bass'})
api('/v1/equalizer', {'action':'mode','mode':'advanced'})
api('/v1/equalizer', {'action':'mode','mode':'tenBand'})
api('/v1/equalizer', {'action':'select','id':identity})
assert api('/v1/equalizer')['configuration'] == saved['configuration']
api('/v1/presentation/equalizer', {'action':'dragBand', 'index':0, 'dx':40, 'dy':-12}, 'graph-drag-action')
dragged=api('/v1/equalizer', artifact='graph-drag')
assert dragged['configuration']['filters'][0]['frequencyHz'] != saved['configuration']['filters'][0]['frequencyHz'], dragged
api('/v1/equalizer', {'action':'undo'})
assert api('/v1/equalizer')['configuration'] == saved['configuration']
api('/v1/presentation/equalizer', {'action':'cancelDrag', 'index':0, 'dx':20, 'dy':-6})
assert api('/v1/equalizer')['configuration'] == saved['configuration']
api('/v1/presentation/equalizer', {'action':'selectBand'})
for action, label in [(None,'eq-mobile-graph'), ('edit','eq-mobile-band-editor')]:
    if action: api('/v1/presentation/equalizer', {'action':action,'index':0})
    shot = api('/v1/presentation/screenshot', {'label':label}, label)
    remote = '/data/user/0/'+args.package+'/files/eq-diagnostics/'+shot['artifact']
    with (args.output/(label+'.png')).open('wb') as output:
        subprocess.run(adb + ['exec-out','run-as',args.package,'cat',remote], check=True, stdout=output)
api('/v1/presentation/equalizer', {'action':'gain','value':'3.12735'})
preview = api('/v1/equalizer', artifact='live-preview')
assert preview['persistedConfiguration'] == saved['configuration'], preview
assert math.isclose(preview['application']['configuration']['filters'][0]['gainDb'],3.12735,abs_tol=1e-8), preview
api('/v1/presentation/equalizer', {'action':'cancel'})
cancel = api('/v1/equalizer', artifact='preview-cancel')
assert cancel['configuration'] == saved['configuration'], cancel
assert cancel['application']['configuration'] == saved['configuration'], cancel
api('/v1/equalizer', {'action':'select','id':'builtin:bass'})
restored = api('/v1/equalizer', artifact='restored-mode-draft')
assert restored['configuration']['mode'] == 'tenBand', restored
api('/v1/equalizer', {'action':'select','id':identity})
# Profile one continuous rendered drag with 32 active filters, then restore the
# precise saved fixture before background and restart checks.
dense=json.loads(json.dumps(saved['configuration']))
dense['filters']=[{'type':'peaking','frequencyHz':20*1000**(i/31),'gainDb':-.2,'q':1,'enabled':True} for i in range(32)]
api('/v1/equalizer', {'action':'configure','configuration':dense})
profile_before=api('/v1/equalizer')['interaction']
profile=api('/v1/presentation/equalizer', {'action':'profileGraph','index':15}, 'graph-profile')
profile_after=api('/v1/equalizer')['interaction']
assert profile['profile']['bands']==32 and profile['profile']['frames']>=100, profile
assert profile_after['workspaceWrites']-profile_before['workspaceWrites'] < 40, profile_after
assert profile_after['previewCommands']-profile_before['previewCommands'] < 180, profile_after
assert not profile_after['checkpointPending'], profile_after
shot=api('/v1/presentation/screenshot', {'label':'eq-mobile-32-bands'}, 'dense-screenshot')
remote='/data/user/0/'+args.package+'/files/eq-diagnostics/'+shot['artifact']
with (args.output/'eq-mobile-32-bands.png').open('wb') as output:
    subprocess.run(adb+['exec-out','run-as',args.package,'cat',remote],check=True,stdout=output)
api('/v1/equalizer', {'action':'configure','configuration':saved['configuration']})
subprocess.run(adb + ['shell','am','start' ,'-a','android.intent.action.MAIN','-c','android.intent.category.HOME'],
    check=True, stdout=subprocess.DEVNULL)
background_before=api('/v1/playback/status')
deadline=time.monotonic()+8
while time.monotonic()<deadline:
    progress=api('/v1/playback/status')
    if progress.get('positionMs',0) > background_before.get('positionMs',0)+500:
        break
    time.sleep(.2)
else:
    raise AssertionError('Playback did not advance in the background')
api('/v1/equalizer', artifact='background')
print('Android EQ bridge, native status, controls, persistence, and background checks passed')
