import subprocess,re,sys,xml.etree.ElementTree as E
subprocess.run(['adb','shell','uiautomator','dump','/sdcard/tap.xml'],check=True)
subprocess.run(['adb','pull','/sdcard/tap.xml','back-out/tap.xml'],check=True)
for n in E.parse('back-out/tap.xml').iter('node'):
 if sys.argv[1] in (n.get('text','')+' '+n.get('content-desc','')):
  b=list(map(int,re.findall(r'\d+',n.get('bounds',''))))
  if len(b)==4:
   subprocess.run(['adb','shell','input','tap',str((b[0]+b[2])//2),str((b[1]+b[3])//2)],check=True);break
else:raise SystemExit('control not found: '+sys.argv[1])
