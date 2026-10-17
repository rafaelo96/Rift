"""Sequential before/after replay of the existing static-protection fixtures."""
from pathlib import Path
import os,re,subprocess,sys
ROOT=Path(__file__).resolve().parents[3]
OUT=ROOT/'docs/diagnostics/assets/dense-oracle-static-2026-10-17'
OLD=ROOT/'docs/diagnostics/assets/oracle-static-2026-10-17'

def main():
    phase=sys.argv[1];assert phase in ['before','after','disabled']
    flag='1' if phase=='after' else '0'
    if phase=='before':
        source=(ROOT/'Core/Interpolation/Swift/DenseMotionShaders.swift').read_text().split('"""')[1]
        source=re.sub(r'#ifdef DENSE_STATIC_MOTION\n.*?#endif\n','',source,flags=re.S)
        if (OUT/'baseline.metal').exists():assert (OUT/'baseline.metal').read_text()==source
        else:(OUT/'baseline.metal').write_text(source)
    binary=str(ROOT/'.build/release/MVProbe')
    def run(log,**env):
        with log.open('w') as f:
            subprocess.run([binary],cwd=ROOT,env=dict(os.environ,RIFT_STATIC_MOTION_GUARD=flag,MV_STATIC_BASELINE=str(OUT/'baseline.metal'),**env),stdout=f,stderr=subprocess.STDOUT,check=True)
    run(OUT/f'synthetic-{phase}.log',MV_STATIC_CHECK='1',MV_STATIC_OUTPUT=str(OUT/f'synthetic-{phase}'),MV_STATIC_EXPECT_FIXED='1' if flag=='1' else '0',MV_STATIC_STRICT_STATIONARY='1')
    for case,seek in [('avatar69','69'),('avatar300','300'),('anime1082','1082')]:
        run(OUT/f'{case}-static-{phase}.log',MV_STATIC_REAL=str(OLD/case/'oracle-on'),MV_STATIC_OUTPUT=str(OUT/case/f'static-{phase}'))
        run(OUT/f'{case}-regression-{phase}.log',MV_DENSE='1',MV_DENSE_PATCH='1',MV_DENSE_FOUR='1',MV_DENSE_GROUND_TRUTH='1',MV_LAMBDA='1',MV_TEMA='0',MV_PAIRS='6',MV_DUMP='0',MV_SEEK_SEC=seek,MV_DENSE_OUTPUT=str(OUT/case/f'regression-{phase}'))
        print(phase,case,flush=True)
if __name__=='__main__': main()
