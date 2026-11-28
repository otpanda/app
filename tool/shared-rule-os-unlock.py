# Disposable emulator test driver. Uses only the fixture's synthetic screen lock.
import subprocess,time,xml.etree.ElementTree as ET,pathlib,sys
out=pathlib.Path(sys.argv[1]);out.mkdir(exist_ok=True,parents=True)
def adb(*args):return subprocess.run(['adb',*args],capture_output=True,text=True,timeout=15).stdout
for i in range(240):
 time.sleep(2)
 if (out/'stop-os-driver').exists():break
 try:
  adb('shell','uiautomator','dump','/sdcard/rule-ui.xml');s=adb('shell','cat','/sdcard/rule-ui.xml');root=ET.fromstring(s)
  texts=[(n.get('text',''),n.get('resource-id','')) for n in root.iter('node')]
  # Only system credential entry, never a Flutter text field or any account prompt.
  if any('pinEntry' in rid or 'passwordEntry' in rid for _,rid in texts):
   (out/f'os-credential-{i}.xml').write_text(s);adb('shell','screencap','-p',f'/sdcard/os-rule-{i}.png');subprocess.run(['adb','pull',f'/sdcard/os-rule-{i}.png',str(out/f'os-rule-{i}.png')],capture_output=True)
   adb('shell','input','text','864291');adb('shell','input','keyevent','66');print('FIXTURE_OS_CREDENTIAL_SUBMITTED',flush=True)
  else:
   for n in root.iter('node'):
    if n.get('package') in ['com.android.systemui','com.google.android.permissioncontroller','com.android.settings'] and any(k in n.get('text','').lower() for k in ['use pin','use screen lock','use password']):
     import re
     a=list(map(int,re.findall(r'\d+',n.get('bounds',''))))
     if len(a)==4:adb('shell','input','tap',str((a[0]+a[2])//2),str((a[1]+a[3])//2));break
 except Exception as e:print(type(e).__name__,flush=True)
