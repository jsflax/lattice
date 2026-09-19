"""One <=60s Python-only detached-owner/escaped-descendant smoke. Never native work."""
import argparse
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import time

import detached_owner as owner
import guarded_runner as guard
import process_custody as pc

P=Path(__file__).resolve().parent
SMOKE=P.parents[1]/'validation/owned-page-sdk008-lifecycle-smoke-001'


def wait_for(predicate, deadline, description):
    while time.monotonic()<deadline:
        if predicate():return
        time.sleep(0.05)
    raise RuntimeError('timeout: '+description)


def signal_exact(saved, number):
    current=pc.identity(saved['pid'])
    if current is None:return
    if not pc.same(saved,current):raise RuntimeError('smoke identity changed')
    os.kill(saved['pid'],number)


def synthetic(role, root):
    child=None;stopping=False
    def stop(*_):
        nonlocal stopping
        stopping=True
    signal.signal(signal.SIGTERM,stop);signal.signal(signal.SIGINT,stop)
    owner.exclusive(root/('ready-'+role+'.json'),pc.identity(os.getpid()))
    try:
        following={'leader':'grandchild','grandchild':'macro'}.get(role)
        if following:
            child=subprocess.Popen([sys.executable,'-B',str(P/'smoke_lifecycle.py'),
                   '--role',following,'--root',str(root)],start_new_session=True,
                   stdin=subprocess.DEVNULL,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
        until=time.monotonic()+20
        while not stopping and time.monotonic()<until:time.sleep(0.05)
    finally:
        if child and child.poll() is None:
            child.terminate()
            try:child.wait(timeout=1)
            except subprocess.TimeoutExpired:child.kill();child.wait(timeout=1)
    return 0


def owner_body(root):
    result={'expectedStop':False,'nativeExecuted':False,'databaseOpened':False}
    env={'PATH':'/usr/bin:/bin','PYTHONDONTWRITEBYTECODE':'1'}
    with guard.Interrupts() as interrupts:
        runner=guard.GuardedRunner(root,root/'receipts',env,interrupts,
                free_floor=1,packet_ceiling=4*2**20,log_ceiling=65536,
                overall_seconds=45,reserve=5,poll_seconds=0.05,signal_grace=2)
        try:
            runner.run('synthetic',[sys.executable,'-B',str(P/'smoke_lifecycle.py'),
                       '--role','leader','--root',str(root)],cwd=root,timeout=25)
        except BaseException as error:
            result['error']={'type':type(error).__name__,'message':str(error)}
            result['expectedStop']=str(error)=='authorized owner stop requested'
        finally:
            owner.exclusive(root/'receipts/RESULT.json',result)
    return 1  # The commanded stop is intentionally a qualification failure.


def wrapper(root):
    value=owner.launch(root.with_name(root.name+'-owner'),lambda:owner_body(root),
                       {'scope':'Python-only smoke','runtimeRoot':str(root)},overall_seconds=45)
    owner.exclusive(root/'WRAPPER-ACK.json',value)
    time.sleep(30)
    return 0


def main():
    parser=argparse.ArgumentParser();parser.add_argument('--role',choices=['wrapper','leader','grandchild','macro'])
    parser.add_argument('--root',type=Path);args=parser.parse_args()
    if args.role:
        if args.role=='wrapper' and args.root is None:args.root=SMOKE
        if args.root!=SMOKE:raise RuntimeError('exact smoke root required')
        return wrapper(args.root) if args.role=='wrapper' else synthetic(args.role,args.root)
    started=time.monotonic();root=SMOKE;root.mkdir();(root/'receipts').mkdir()
    result={'success':False,'nativeExecuted':False,'databaseOpened':False,'networkUsed':False}
    foreign=launcher=None;foreign_id=launcher_id=owner_record=None
    def alarm(*_):raise RuntimeError('smoke absolute 55-second deadline')
    signal.signal(signal.SIGALRM,alarm);signal.alarm(55)
    try:
        foreign=subprocess.Popen([sys.executable,'-B','-c','import time; time.sleep(40)'],
                    stdin=subprocess.DEVNULL,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,start_new_session=True)
        foreign_id=pc.identity(foreign.pid)
        launcher=subprocess.Popen([sys.executable,'-B',str(P/'smoke_lifecycle.py'),
                    '--role','wrapper'],stdin=subprocess.DEVNULL,
                    stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,start_new_session=True)
        launcher_id=pc.identity(launcher.pid)
        deadline=started+35
        wait_for(lambda:(root/'WRAPPER-ACK.json').exists(),deadline,'detached owner acknowledgement')
        owner_record=json.loads((root/'WRAPPER-ACK.json').read_text())
        wait_for(lambda:all((root/('ready-'+x+'.json')).exists() for x in ['leader','grandchild','macro']),deadline,'synthetic descendants')
        known=[json.loads((root/('ready-'+x+'.json')).read_text()) for x in ['leader','grandchild','macro']]
        def all_observed():
            f=root/'receipts/synthetic.ownership.jsonl'
            if not f.exists():return False
            text=f.read_text()
            if text and not text.endswith('\n'):return False
            records=[json.loads(x) for x in text.splitlines()]
            observed={x['identity']['pid'] for x in records if x['event']=='owned'}
            return {x['pid'] for x in known}<=observed
        wait_for(all_observed,deadline,'ancestry custody of all synthetic descendants')
        if len({x['pgid'] for x in known})!=3:raise RuntimeError('separate groups not exercised')
        signal_exact(launcher_id,signal.SIGTERM);launcher.wait(timeout=2)
        time.sleep(0.2)
        if not pc.same(owner_record['identity'],pc.identity(owner_record['identity']['pid'])):
            raise RuntimeError('owner did not survive outer launcher interruption')
        result['ownerSurvivedOuterInterruption']=True
        owner.exclusive(root.with_name(root.name+'-owner')/'STOP.json',
                        {'nonce':owner_record['nonce'],'identity':owner_record['identity']})
        terminal=root.with_name(root.name+'-owner')/'TERMINAL.json'
        wait_for(terminal.exists,deadline,'owner terminal receipt')
        wait_for(lambda:not pc.same(owner_record['identity'],pc.identity(owner_record['identity']['pid'])),deadline,'detached owner exit')
        receipt=json.loads((root/'receipts/synthetic.json').read_text())
        stop=json.loads((root/'receipts/RESULT.json').read_text())
        if not stop['expectedStop'] or receipt['success'] or receipt['primaryError']['message']!='authorized owner stop requested':
            raise RuntimeError('first stop was not preserved as terminal failure')
        cleanup=receipt['cleanup']
        if not cleanup['ownedDescendantsGone'] or not cleanup['groupGone'] or not cleanup['leaderReaped'] or cleanup['errors']:
            raise RuntimeError('synthetic closure not proven')
        if any(pc.same(x,pc.identity(x['pid'])) for x in known):raise RuntimeError('synthetic descendant survived closure')
        if foreign.poll() is not None or not pc.same(foreign_id,pc.identity(foreign.pid)):
            raise RuntimeError('foreign control did not survive')
        result.update(success=True,syntheticProcesses=known,foreignControlSurvived=True,
                      firstFailurePreserved=True,completeClosure=cleanup,owner=owner_record,
                      terminal=json.loads(terminal.read_text()))
    except BaseException as error:
        result['firstFailure']={'type':type(error).__name__,'message':str(error)}
    finally:
        # Exact smoke-created Popen objects and birth identities only. No path-based signals.
        cleanup_errors=[]
        for process,saved in [(launcher,launcher_id),(foreign,foreign_id)]:
            if process is not None:
                try:
                    if process.poll() is None:signal_exact(saved,signal.SIGTERM)
                    process.wait(timeout=2)
                except BaseException as error:cleanup_errors.append(str(error))
        if owner_record and not (root.with_name(root.name+'-owner')/'TERMINAL.json').exists():
            try:
                stop=root.with_name(root.name+'-owner')/'STOP.json'
                if not stop.exists():owner.exclusive(stop,{'nonce':owner_record['nonce'],'identity':owner_record['identity']})
                wait_for((root.with_name(root.name+'-owner')/'TERMINAL.json').exists,started+52,'failure closure')
            except BaseException as error:cleanup_errors.append(str(error))
        signal.alarm(0)
        result['cleanupErrors']=cleanup_errors
        result['success']=result['success'] and not cleanup_errors
        result['elapsedSeconds']=time.monotonic()-started
        if result['elapsedSeconds']>=60:result['success']=False
        owner.exclusive(root/'SMOKE-RESULT.json',result)
    print(json.dumps({'success':result['success'],'result':str(root/'SMOKE-RESULT.json')}))
    return 0 if result['success'] else 1


if __name__=='__main__':raise SystemExit(main())
