from pathlib import Path
import subprocess,tempfile,shutil,plistlib,re
app=Path(__file__).resolve().parents[2]/'AI Illuminati.app'
keychain=Path.home()/'Library/Keychains/login.keychain-db'
identities=subprocess.check_output(['security','find-identity','-v','-p','codesigning',str(keychain)],text=True)
identity=re.search(r'([0-9A-F]{40}) "AI Illuminati Local Signing"',identities).group(1)
def details(path):
 r=subprocess.run(['codesign','-d','-r-','--verbose=4',str(path)],capture_output=True,text=True,check=True)
 text=r.stdout+r.stderr
 req=next(x.split('designated => ',1)[1] for x in text.splitlines() if 'designated => ' in x)
 codehash=re.search(r'^CDHash=(.+)$',text,re.M).group(1)
 assert 'flags=0x2(adhoc)' not in text
 return req,codehash
oldreq,oldhash=details(app)
root=Path(tempfile.mkdtemp(prefix='ai-signing-check-'))
try:
 variant=root/'Variant.app';shutil.copytree(app,variant)
 info=variant/'Contents/Info.plist'
 data=plistlib.loads(info.read_bytes());data['CFBundleVersion']='0.1-signing-verification'
 info.write_bytes(plistlib.dumps(data))
 subprocess.run(['codesign','--force','--sign',identity,'--keychain',str(keychain),'--requirements','=designated => '+oldreq,str(variant)],check=True,capture_output=True)
 newreq,newhash=details(variant)
 assert oldhash != newhash, 'test must use different code hashes'
 assert oldreq == newreq, 'designated requirement changed'
 subprocess.run(['codesign','--verify','--strict','-R','='+oldreq,str(variant)],check=True,capture_output=True)
 print('PASS: different build hashes, identical certificate-based app identity, new build satisfies previous identity requirement')
 print('Identity:',oldreq)
finally:shutil.rmtree(root)
