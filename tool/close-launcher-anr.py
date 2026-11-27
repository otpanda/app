import sys,xml.etree.ElementTree as ET,re,subprocess,pathlib
p,name,iteration=sys.argv[1:]
r=ET.parse(p).getroot();nodes=list(r.iter('node'))
# Never match generic ANR wording or an OTPanda crash. Require exact system
# Launcher title and Android-owned close action in this same current hierarchy.
if not any(n.get('text')=="Pixel Launcher isn't responding" and n.get('package')=='android' for n in nodes):sys.exit(1)
button=next((n for n in nodes if n.get('text')=='Close app' and n.get('package')=='android'),None)
if button is None:sys.exit(2)
m=re.fullmatch(r'\[(\d+),(\d+)\]\[(\d+),(\d+)\]',button.get('bounds',''))
if not m:sys.exit(2)
x1,y1,x2,y2=map(int,m.groups())
prefix=pathlib.Path('repair-out')/(name+'-launcher-anr-'+iteration)
prefix.with_suffix('.xml').write_bytes(pathlib.Path(p).read_bytes())
with prefix.with_suffix('.png').open('wb')as f:subprocess.run(['adb','exec-out','screencap','-p'],stdout=f,check=True)
subprocess.run(['adb','shell','input','tap',str((x1+x2)//2),str((y1+y2)//2)],check=True)
print('Closed identified Pixel Launcher system ANR, not OTPanda')
