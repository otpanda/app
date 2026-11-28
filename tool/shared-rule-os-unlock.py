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
  if i%5==0:
   (out/f'ui-{i}.xml').write_text(s)
   (out/f'focus-{i}.txt').write_text(adb('shell','dumpsys','window','windows'))
   print('OS_DRIVER_UI',i,[(n.get('package'),n.get('text'),n.get('resource-id'),n.get('class')) for n in root.iter('node') if n.get('text') or 'EditText' in n.get('class','')],flush=True)
   adb('shell','screencap','-p',f'/sdcard/rule-diag-{i}.png');subprocess.run(['adb','pull',f'/sdcard/rule-diag-{i}.png',str(out/f'ui-{i}.png')],capture_output=True)
  systemEditors=[n for n in root.iter('node') if n.get('package') in ['com.android.systemui','com.android.settings','com.google.android.permissioncontroller'] and ('EditText' in n.get('class','') or any(v in n.get('resource-id','').lower() for v in ['pinentry','passwordentry','pin_entry','password_entry']))]
  # Only system credential entry, never a Flutter text field or any account prompt.
  if systemEditors:
   (out/f'os-credential-{i}.xml').write_text(s);adb('shell','screencap','-p',f'/sdcard/os-rule-{i}.png');subprocess.run(['adb','pull',f'/sdcard/os-rule-{i}.png',str(out/f'os-rule-{i}.png')],capture_output=True)
   import re
   bounds=list(map(int,re.findall(r'\d+',systemEditors[0].get('bounds',''))))
   if len(bounds)==4:adb('shell','input','tap',str((bounds[0]+bounds[2])//2),str((bounds[1]+bounds[3])//2))
   adb('shell','input','text','864291');adb('shell','input','keyevent','66');print('FIXTURE_OS_CREDENTIAL_SUBMITTED',flush=True)
  else:
   for n in root.iter('node'):
    if n.get('package') in ['com.android.systemui','com.google.android.permissioncontroller','com.android.settings'] and any(k in n.get('text','').lower() for k in ['use pin','use screen lock','use password']):
     import re
     a=list(map(int,re.findall(r'\d+',n.get('bounds',''))))
     if len(a)==4:adb('shell','input','tap',str((a[0]+a[2])//2),str((a[1]+a[3])//2));break
 except Exception as e:print(type(e).__name__,flush=True)
