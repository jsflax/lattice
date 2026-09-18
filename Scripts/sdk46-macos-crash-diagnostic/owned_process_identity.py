"""Read-only Darwin identity observation inside the existing owned-command poll."""
import copy
import ctypes as C
import os
from pathlib import Path
import time

MAX_MEMBERS = 64
MAX_ERRORS = 64
PATH_BYTES = 4096


class BSDInfo(C.Structure):
    _fields_ = [(name,C.c_uint32) for name in (
        'flags','status','xstatus','pid','ppid','uid','gid','ruid','rgid','svuid','svgid','rfu1')] + [
        ('comm',C.c_char*16),('name',C.c_char*32)] + [
        (name,C.c_uint32) for name in ('nfiles','pgid','pjobc','tdev','tpgid')] + [
        ('nice',C.c_int32),('start_seconds',C.c_uint64),('start_microseconds',C.c_uint64)]


def validate_layout():
    assert C.sizeof(BSDInfo) == 136
    assert {n:getattr(BSDInfo,n).offset for n in ('pid','ppid','pgid','start_seconds','start_microseconds')} == {
        'pid':12,'ppid':16,'pgid':100,'start_seconds':120,'start_microseconds':128}


class Darwin:
    def __init__(self):
        validate_layout()
        self.lib = C.CDLL('/usr/lib/libproc.dylib',use_errno=True)
        self.lib.proc_listpids.argtypes = [C.c_uint32,C.c_uint32,C.c_void_p,C.c_int]
        self.lib.proc_listpids.restype = C.c_int
        self.lib.proc_pidinfo.argtypes = [C.c_int,C.c_int,C.c_uint64,C.c_void_p,C.c_int]
        self.lib.proc_pidinfo.restype = C.c_int
        self.lib.proc_pidpath.argtypes = [C.c_int,C.c_void_p,C.c_uint32]
        self.lib.proc_pidpath.restype = C.c_int

    def info(self,pid):
        value=BSDInfo()
        if self.lib.proc_pidinfo(pid,3,0,C.byref(value),C.sizeof(value)) != C.sizeof(value):
            raise OSError(C.get_errno(),'proc_pidinfo missing or short')
        if value.pid != pid or not value.start_seconds or value.start_microseconds >= 1000000:
            raise ValueError('invalid process birth identity')
        return {'pid':value.pid,'ppid':value.ppid,'pgid':value.pgid,'status':value.status,
                'birthSeconds':value.start_seconds,'birthMicroseconds':value.start_microseconds}

    def members(self,pgid):
        buffer=(C.c_int*(MAX_MEMBERS+1))()
        length=self.lib.proc_listpids(2,pgid,buffer,C.sizeof(buffer))
        if length <= 0 or length % C.sizeof(C.c_int) or length > C.sizeof(buffer):
            raise OSError(C.get_errno(),'invalid group PID inventory')
        count=length//C.sizeof(C.c_int)
        return [pid for pid in list(buffer)[:min(count,MAX_MEMBERS)] if pid>0], count>MAX_MEMBERS

    def path(self,pid):
        buffer=C.create_string_buffer(PATH_BYTES)
        length=self.lib.proc_pidpath(pid,buffer,PATH_BYTES)
        if not 0 < length <= PATH_BYTES or b'\0' not in buffer.raw:
            raise OSError(C.get_errno(),'missing bounded executable path')
        raw=buffer.raw.split(b'\0',1)[0]
        if not raw or len(raw)>=PATH_BYTES:raise ValueError('executable path bounds')
        path=os.fsdecode(raw)
        if not path.startswith('/') or any(ord(c)<32 for c in path):raise ValueError('invalid executable path')
        return path


def identity(value):
    return tuple(value[k] for k in ('pid','pgid','birthSeconds','birthMicroseconds'))


class Observer:
    def __init__(self,arm,*,backend=None,clock=time.time):
        self.arm,self.backend,self.clock=arm,backend,clock
        self.leader=None;self.rows={};self.errors=[];self.omitted=0;self.attempts=0;self.truncated=False
        self.begin=None;self.end=None

    def error(self,error):
        if len(self.errors)<MAX_ERRORS:self.errors.append({'type':type(error).__name__,'message':str(error)[:512]})
        else:self.omitted+=1

    def observe(self,process):
        self.attempts+=1
        now=self.clock();self.begin=self.begin or now;self.end=now
        try:
            if process.poll() is not None:return
            if self.backend is None:self.backend=Darwin()
            before=self.backend.info(process.pid)
            if before['pgid']!=process.pid or before['status']==5:raise ValueError('leader is not live owned group anchor')
            anchor=identity(before)
            if self.leader is not None and self.leader!=anchor:raise ValueError('leader identity changed')
            self.leader=anchor
            members,truncated=self.backend.members(process.pid);self.truncated |= truncated
            accepted=[]
            for pid in members:
                try:
                    first=self.backend.info(pid)
                    if first['pgid']!=process.pid or first['status']==5:continue
                    path=self.backend.path(pid)
                    second=self.backend.info(pid)
                    if identity(first)!=identity(second) or first['ppid']!=second['ppid'] or second['status']==5:
                        raise ValueError('member changed during identity observation')
                    accepted.append((second,path))
                except (OSError,ValueError) as error:self.error(error)
            after=self.backend.info(process.pid)
            if process.poll() is not None or identity(after)!=anchor or after['status']==5:
                raise ValueError('leader no longer anchors collected members')
            observed=self.clock()
            for info,path in accepted:
                key=(*identity(info),path)
                if key not in self.rows:
                    if len(self.rows)>=MAX_MEMBERS:self.truncated=True;continue
                    self.rows[key]={**info,'executable':path,'procName':Path(path).name,
                                    'firstObservedEpoch':observed,'lastObservedEpoch':observed}
                else:self.rows[key]['lastObservedEpoch']=observed
        except Exception as error:self.error(error)

    def snapshot(self):
        return {'arm':self.arm,'method':'live anchored owned group libproc identity; no argv/environment',
                'leaderIdentity':list(self.leader) if self.leader else None,'members':copy.deepcopy(list(self.rows.values())),
                'attempts':self.attempts,'beginEpoch':self.begin,'endEpoch':self.end,'errors':copy.deepcopy(self.errors),
                'errorsOmitted':self.omitted,'inventoryTruncated':self.truncated,
                'coverageComplete':False,'samplingSeconds':0.5,'limits':{'members':MAX_MEMBERS,'errors':MAX_ERRORS,'pathBytes':PATH_BYTES},
                'limitation':'sampling can miss a short-lived helper; missing identity is unattributed'}
