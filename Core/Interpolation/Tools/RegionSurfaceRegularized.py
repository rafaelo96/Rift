"""Offline surface-label experiment; no production runtime or quality claim."""
import argparse
import json
from pathlib import Path
import numpy as np
from RegionSurfaceProbe import load, regions, match
from feature_correspondence_probe import sample


def solve(first,last,forward,backward,iterations=16):
    h,w=first.shape[:2]
    la,a=regions(first,2/255)
    lb,b=regions(last,2/255)
    matches=match(a,b,lb)
    reverse={(m['target'],m['source']) for m in match(b,a,la)}
    matches=[m for m in matches if (m['source'],m['target']) in reverse]
    # An identity layer and the unmodified dense field remain available everywhere.
    models=[None,{'linear':np.eye(2),'translation':np.zeros(2)}]+matches
    gy,gx=np.mgrid[:h:4,:w:4]
    points=np.stack([gx,gy],axis=-1).astype(np.float32)
    mh,mw=gx.shape
    output=[]
    states=[]
    for direction,(source,target,base,labels,region_list) in enumerate([
            (first,last,forward,la,a),(last,first,backward,lb,b)]):
        lookup={r['id']:r for r in region_list}
        velocity=[]
        cost=[]
        for index,model in enumerate(models):
            if index==0:
                v=base[::8,::8,:2]/2
            else:
                matrix=np.asarray(model['linear'],dtype=np.float32)
                shift=np.asarray(model['translation'],dtype=np.float32)/2
                if direction:
                    matrix=np.linalg.inv(matrix)
                    shift=-matrix @ shift
                projected=np.einsum('ij,hwj->hwi',matrix,points,optimize=False)+shift
                v=projected-points
            error=np.zeros((mh,mw),dtype=np.float32)
            for oy in (-3,-1,1,3):
                for ox in (-3,-1,1,3):
                    for c,weight in enumerate([1,2,2]):
                        value=sample(source[...,c],gx+ox,gy+oy)
                        other=sample(target[...,c],gx+ox+v[...,0],gy+oy+v[...,1])
                        error+=weight*np.minimum(abs(value-other),.08)/16
            end=points+v
            outside=(end[...,0]<0)|(end[...,0]>=w)|(end[...,1]<0)|(end[...,1]>=h)
            error+=outside*.1
            if index>=2:
                region=lookup[model['target'] if direction else model['source']]
                delta=points-region['center']
                inv=np.linalg.inv((region['eigenvectors']*region['eigenvalues']) @ region['eigenvectors'].T)
                distance=np.einsum('hwi,ij,hwj->hw',delta,inv,delta,optimize=False)
                # A model may extend across narrow contours, not across unrelated objects.
                error+=.04*np.clip((distance-9)/9,0,1)
                # A matched connected region supplies evidence where flat pixels have none.
                support=labels[gy,gx]==region['id']
                error-=.015*float(model['score'])*support
            velocity.append(v)
            cost.append(error)
        velocities=np.stack(velocity)
        unary=np.stack(cost)
        states.append({'velocities':velocities,'unary':unary,'assignment':unary.argmin(0),'source':source,'base':base})
    yy,xx=np.mgrid[:mh,:mw]
    for iteration in range(iterations):
        for direction,state in enumerate(states):
            velocities,unary,assignment,source=(state[k] for k in ['velocities','unary','assignment','source'])
            opposite=states[1-direction]
            for parity in (0,1):
                total=unary.copy()
                for dy,dx in [(0,-1),(0,1),(-1,0),(1,0)]:
                    ny=np.clip(yy+dy,0,mh-1);nx=np.clip(xx+dx,0,mw-1)
                    neighbor=assignment[ny,nx]
                    other=velocities[neighbor,ny,nx]
                    source_color=source[gy,gx]
                    neighbor_color=source[gy[ny,nx],gx[ny,nx]]
                    edge=np.exp(-30*np.abs(source_color-neighbor_color).sum(-1))
                    difference=np.linalg.norm(velocities-other[None],axis=-1)
                    penalty=.015*edge[None]*np.minimum(difference/4,1)
                    same=(np.arange(len(models))[:,None,None]==neighbor[None]) & (np.arange(len(models))[:,None,None]>0)
                    total+=np.where(same,0,penalty)
                if iteration>1:
                    end=points[None]+velocities
                    nx=np.clip(np.rint(end[...,0]/4).astype(int),0,mw-1)
                    ny=np.clip(np.rint(end[...,1]/4).astype(int),0,mh-1)
                    selected=opposite['assignment'][ny,nx]
                    reverse_velocity=opposite['velocities'][selected,ny,nx]
                    closure=np.linalg.norm(velocities+reverse_velocity,axis=-1)
                    same=(np.arange(len(models))[:,None,None]==selected)&(np.arange(len(models))[:,None,None]>0)
                    inside=(end[...,0]>=0)&(end[...,0]<w)&(end[...,1]>=0)&(end[...,1]<h)
                    total+=np.where(same,0,.025*np.minimum(closure/4,1))*inside*(unary<.04)
                proposed=total.argmin(0)
                mask=(yy+xx)%2==parity
                assignment[mask]=proposed[mask]
    for direction,state in enumerate(states):
        assignment,base=state['assignment'],state['base']
        fy,fx=np.mgrid[:h*2,:w*2]
        selected=assignment[np.minimum(fy//8,mh-1),np.minimum(fx//8,mw-1)]
        result=base.copy()
        full_points=np.stack([fx,fy],axis=-1).astype(np.float32)
        for index,model in enumerate(models[1:],1):
            mask=selected==index
            matrix=np.asarray(model['linear'],dtype=np.float32)
            shift=np.asarray(model['translation'],dtype=np.float32)
            if direction:
                matrix=np.linalg.inv(matrix);shift=-matrix @ shift
            q=full_points[mask]
            result[mask,:2]=np.einsum('ij,nj->ni',matrix,q,optimize=False)+shift-q
        output.append(result)
        print('direction',direction,'coupled labels',np.bincount(assignment.ravel(),minlength=len(models)).tolist())
    return output,matches


def selfcheck():
    first=np.zeros((64,64,3),dtype=np.float32)
    first[:]=[.15,.5,.5]
    first[16:48,16:40]=[.5,.3,.6]
    last=np.zeros_like(first)
    last[:]=[.15,.5,.5]
    last[16:48,20:44]=[.5,.3,.6]
    field=np.zeros((128,128,4),dtype=np.float32)
    field[:,:,2]=1
    result,models=solve(first,last,field,field)
    assert len(models)==1
    assert np.max(abs(result[0][40:88,40:72,0]-8))<1e-4
    assert np.max(abs(result[1][40:88,48:80,0]+8))<1e-4
    static,_=solve(first,first,field,field,iterations=4)
    assert np.array_equal(static[0][:,:,:2],field[:,:,:2])
    assert all(np.isfinite(f).all() for f in result)
    print('RegionSurfaceRegularized: known flat-surface translation and static identity passed')


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('folder',type=Path,nargs='?')
    parser.add_argument('forward',type=Path,nargs='?')
    parser.add_argument('backward',type=Path,nargs='?')
    parser.add_argument('output',type=Path,nargs='?')
    parser.add_argument('--selfcheck',action='store_true')
    args=parser.parse_args()
    if args.selfcheck:
        selfcheck()
    else:
        if not all([args.folder,args.forward,args.backward,args.output]):
            parser.error('folder, forward, backward and output required')
        first,last=load(args.folder,0),load(args.folder,1)
        if first.shape!=last.shape:parser.error('dimensions must match')
        h,w=first.shape[:2]
        fields=[]
        for path in [args.forward,args.backward]:
            values=np.fromfile(path,dtype='<f4')
            if values.size!=h*w*16 or not np.isfinite(values).all():parser.error('invalid bounded field')
            fields.append(values.reshape(h*2,w*2,4))
        result,matches=solve(first,last,*fields)
        args.output.mkdir(parents=True,exist_ok=True)
        for i,field in enumerate(result):field.astype('<f4').tofile(args.output/f'field{i}.f32')
        (args.output/'models.json').write_text(json.dumps(matches,indent=2))
