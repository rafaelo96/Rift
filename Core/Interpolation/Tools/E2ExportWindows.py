"""Export only bounded 10s diagnostic windows through existing VT decode, in <=49-frame chunks."""
from pathlib import Path
import os,subprocess,json,hashlib
ROOT=Path(__file__).resolve().parents[3];OUT=ROOT/'docs/diagnostics/assets/confidence-e2-2026-10-17'
SOURCE='/Users/rafael/Downloads/Avatar.Aang.el.ultimo.maestro.del.aire.2026.WEB-DL.4k.HDR-Dual-Lat.mkv'
SPIDER='/Users/rafael/Downloads/Spider.Man.Un.Nuevo.Dia.2026.1080p-Dual-Lat/Spider.Man.Un.Nuevo.Dia.2026.1080p-Dual-Lat.mkv'
for case,start,source in [('avatar69',69,SOURCE),('avatar300',300,SOURCE),('anime1082',1082,SOURCE),('spider180',180,SPIDER),('spider900',900,SPIDER),('spider3600',3600,SPIDER)]:
 dest=OUT/case/'sequence';dest.mkdir(parents=True,exist_ok=True);frames={};first=None
 for chunk in range(6):
  folder=OUT/case/f'chunk{chunk}';folder.mkdir(parents=True,exist_ok=True)
  if not (folder/'manifest.json').exists():
   with (folder/'export.log').open('w') as log:
    subprocess.run([str(ROOT/'.build/release/MVProbe'),source],env=dict(os.environ,MV_PAIRS='48',MV_SEEK_SEC=str(start+chunk*48/23.976),MV_TRAJECTORY_EXPORT=str(folder)),stdout=log,stderr=subprocess.STDOUT,check=True)
  m=json.loads((folder/'manifest.json').read_text())
  for i,t in enumerate(m['sourcePTS']):frames[round(t,6)]=(folder/f'source_{i}.u16',m['sha256'][i])
 ordered=sorted(frames);first=ordered[0];ordered=[t for t in ordered if t<=first+10.08]
 assert ordered[-1]-first>=10
 hashes=[]
 for i,t in enumerate(ordered):
  path,h=frames[t];target=dest/f'source_{i}.u16'
  if not target.exists():os.link(path,target)
  assert hashlib.sha256(target.read_bytes()).hexdigest()==h;hashes.append(h)
 (dest/'manifest.json').write_text(json.dumps(dict(source=source,width=1152,height=480,sourcePTS=ordered,sha256=hashes,scope='Bounded 10s window only; VT hardware decode; at most49 decoded planes per export process'),indent=2)+'\n')
 (OUT/case/'sequence-inputs.json').write_text((dest/'manifest.json').read_text())
 print(case,len(ordered),ordered[-1]-first,flush=True)
