"""Small identity/report joins for the unchanged ordinary SwiftPM diagnostic."""
import copy
import datetime
from decimal import Decimal
import re
import hashlib
import math
import os
from pathlib import Path
import stat
import struct
import uuid
import parse_report
import macho_identity

NAMES = ('CrashControl','swiftpm-testing-helper','xctest','LatticePackageTests')
MAX_IMAGES = 4
MAX_DESCRIPTORS = 129  # control + at most64 observations per original two arms


def require(value,message):
    if not value:raise ValueError(message)


def fingerprint(info):
    return (info.st_dev,info.st_ino,info.st_size,info.st_mtime_ns,info.st_ctime_ns)


def image_identity(path,allowed_types=(2,8)):
    """Bounded header read plus existing-style streaming full SHA; no native tool."""
    path=Path(path)
    fd=os.open(path,os.O_RDONLY|os.O_NOFOLLOW|os.O_NONBLOCK)
    with os.fdopen(fd,'rb') as stream:
        before=os.fstat(stream.fileno())
        require(stat.S_ISREG(before.st_mode) and 32<=before.st_size<=2*2**30,'image file type/size')
        header=stream.read(32)
        magic,cpu,subtype,kind,count,size,flags,reserved=struct.unpack('<8I',header)
        require(magic==0xfeedfacf and cpu==0x0100000c and kind in allowed_types,'unsupported image format/type; thin arm64 required')
        require(0<count<=256 and 8*count<=size<=65536 and 32+size<=before.st_size,'image load command bounds')
        commands=stream.read(size);require(len(commands)==size,'truncated image commands')
        cursor=0;found=None
        for _ in range(count):
            require(cursor+8<=size,'truncated image command header')
            command,length=struct.unpack_from('<2I',commands,cursor)
            require(length>=8 and length%8==0 and cursor+length<=size,'invalid image command extent')
            if command==0x1b:
                require(length==24 and found is None,'invalid/duplicate image LC_UUID')
                raw=commands[cursor+8:cursor+24];require(any(raw),'nil image LC_UUID');found=str(uuid.UUID(bytes=raw))
            cursor+=length
        require(cursor==size and found is not None,'image command span/missing LC_UUID')
        # Hash exactly the same FD whose header supplied UUID, in bounded memory.
        stream.seek(0);digest=hashlib.sha256();read=0
        while True:
            block=stream.read(min(2**20,before.st_size-read+1))
            if not block:break
            read+=len(block);require(read<=before.st_size,'image grew during hashing');digest.update(block)
        after=os.fstat(stream.fileno())
    require(read==before.st_size and fingerprint(before)==fingerprint(after)==fingerprint(path.stat(follow_symlinks=False)),
            'image identity changed during read')
    return {'path':str(path),'sha256':digest.hexdigest(),'uuid':found,'bytes':read,'fileType':kind,
            'format':'thin little-endian arm64 Mach-O','loadCommands':count,'loadCommandBytes':size}


class Images:
    def __init__(self,swift_path,xctest_path,inventory_sink=None):
        swift=Path(swift_path).resolve(strict=True);xctest=Path(xctest_path).resolve(strict=True)
        require(swift.parent.name=='bin' and swift.parent.parent.name=='usr','unexpected selected Swift toolchain layout')
        self.selectedSwift=str(swift);self.selectedXCTest=str(xctest);self.images={};self.errors=[];self.bundle=None
        candidates=[swift.parent.parent/'libexec/swift/pm/swiftpm-testing-helper',swift.parent/'swiftpm-testing-helper',xctest]
        for path in candidates:
            real=None
            try:
                real=path.resolve(strict=True)
                require(real.name in ('swiftpm-testing-helper','xctest'),'unexpected exact helper basename')
                proof=image_identity(real,(2,))
                self.images[str(real)]=proof
            except (OSError,ValueError) as error:self.errors.append({
                'path':str(path),'resolvedPath':str(real) if real is not None else None,
                'errorType':type(error).__name__,'error':str(error)[:512]})
        # Preserve candidate evidence before mandatory admission can throw.
        # The optional sink must finish successfully before any SDK checkout.
        if inventory_sink is not None:inventory_sink(self.snapshot())
        require(any(Path(k).name=='swiftpm-testing-helper' for k in self.images),'no exact supported SwiftPM helper image; SDK checkout blocked')

    def add_bundle(self,path,sha):
        path=Path(path).resolve(strict=True);proof=image_identity(path)
        require(path.name=='LatticePackageTests' and proof['sha256']==sha,'compiled bundle image/hash mismatch')
        require(len(self.images)<MAX_IMAGES,'image inventory cap')
        self.images[str(path)]=proof;self.bundle=proof

    def lookup(self,path):
        try:return self.images.get(str(Path(path).resolve(strict=True)))
        except OSError:return None

    def verify(self):
        for value in self.images.values():require(image_identity(Path(value['path']))==value,'admitted helper/bundle image changed')

    def snapshot(self):
        return {'selectedSwift':self.selectedSwift,'selectedXCTest':self.selectedXCTest,
                'images':copy.deepcopy(self.images),'unsupportedOrMissingImages':copy.deepcopy(self.errors),'bundle':copy.deepcopy(self.bundle)}


def read_report(path,sha):
    fd=os.open(path,os.O_RDONLY|os.O_NOFOLLOW|os.O_NONBLOCK)
    with os.fdopen(fd,'rb') as stream:
        before=os.fstat(stream.fileno());require(stat.S_ISREG(before.st_mode) and 0<before.st_size<=parse_report.MAX_REPORT,'report file bounds')
        data=stream.read(parse_report.MAX_REPORT+1);after=os.fstat(stream.fileno())
    require(fingerprint(before)==fingerprint(after) and len(data)==before.st_size and hashlib.sha256(data).hexdigest()==sha,'retained report changed')
    return data


def birth_precision(raw,seconds,microseconds):
    """Match the displayed precision, never expand a fractional birth to a second."""
    require(isinstance(raw,str) and len(raw)<=128,'bounded process launch time missing')
    match=re.fullmatch(r'(\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}:\d{2})(?:\.(\d{1,9}))?(?: ?([+-]\d{2}:?\d{2}|Z))',raw)
    require(match is not None,'unsupported launch timestamp representation')
    base=datetime.datetime.fromisoformat(match[1]+match[3])
    require(base.tzinfo is not None,'launch offset missing')
    fraction=match[2] or ''
    reported=Decimal(int(base.timestamp()))+(Decimal('0.'+fraction) if fraction else Decimal(0))
    require(type(seconds) is int and seconds>0 and type(microseconds) is int and 0<=microseconds<1000000,'invalid observed birth')
    observed=Decimal(seconds)+Decimal(microseconds)/Decimal(1000000)
    quantum=Decimal(10)**(-len(fraction))
    # One report unit covers truncation or rounding; one microsecond covers
    # the kernel's stored resolution. Decimal avoids epoch-float rounding.
    allowance=quantum+Decimal('0.000001');delta=abs(reported-observed)
    require(delta<=allowance,'report launch differs beyond serialized birth precision')
    return {'fractionalDigits':len(fraction),'reportQuantumSeconds':str(quantum),
            'allowedDeltaSeconds':str(allowance),'actualDeltaSeconds':str(delta)}


class Identities:
    def __init__(self):self.rows=[]
    def add_control(self,executable,pid,begin,end,binary):
        self.rows.append({'id':'control','role':'control','arm':'control','executable':str(executable),'pid':pid,
                          'procName':'CrashControl','begin':begin,'end':end,'binary':copy.deepcopy(binary)})
    def add_arm(self,arm,observations,begin,end,images):
        require(0<begin<=end and end-begin<=1810,'arm time bounds')
        rows=observations.get('members',[]);require(len(rows)<=64,'observed member bound')
        by_pid={}
        for row in rows:by_pid.setdefault(row['pid'],set()).add((row['birthSeconds'],row['birthMicroseconds'],row['executable']))
        for row in rows:
            if row['procName'] not in NAMES[1:]:continue
            require(len(self.rows)<MAX_DESCRIPTORS,'descriptor bound')
            birth=row['birthSeconds']+row['birthMicroseconds']/1e6
            if not math.floor(begin)<=birth<=row['firstObservedEpoch']<=row['lastObservedEpoch']<=end:continue
            self.rows.append({**copy.deepcopy(row),'id':arm+':'+str(row['pid'])+':'+str(row['birthSeconds'])+':'+str(row['birthMicroseconds']),
                'role':'sdk','arm':arm,'begin':begin,'end':end,'birthEpoch':birth,'ambiguousPID':len(by_pid[row['pid']])!=1,
                'binary':copy.deepcopy(images.lookup(row['executable']))})
    def get(self,identity):
        matches=[r for r in self.rows if r['id']==identity];require(len(matches)==1,'descriptor identity ambiguous');return matches[0]
    def candidate(self,data,scan_end):
        body=parse_report.decode_body(data)
        matches=[r for r in self.rows if type(body.get('pid')) is int and r['pid']==body['pid'] and body.get('procName')==r['procName']]
        passed=[]
        for row in matches:
            try:
                if row['role']=='control':
                    value=parse_report.retention_candidate(data,executable=row['executable'],pid=row['pid'],launch_begin=row['begin'],exit_end=row['end'],scan_end=min(scan_end,row['begin']+240))
                else:
                    require(not row['ambiguousPID'],'ambiguous observed PID birth/image')
                    launched=parse_report.epoch(body.get('procLaunch'));captured=parse_report.epoch(body.get('captureTime'))
                    # Retain only identities actually sampled while the leader owned the group.
                    precision=birth_precision(body.get('procLaunch'),row['birthSeconds'],row['birthMicroseconds'])
                    require(math.floor(row['begin'])<=launched<=math.ceil(row['firstObservedEpoch']),'report launch outside observed arm')
                    require(math.floor(row['firstObservedEpoch'])<=captured<=math.ceil(min(row['end'],scan_end)) and launched<=captured,'report capture outside observed arm life')
                    value={'retentionOnly':True,'fullAdmission':False,'pid':row['pid'],'procName':row['procName'],
                           'launchEpoch':launched,'captureEpoch':captured,'observedBirthEpoch':row['birthEpoch'],'birthPrecision':precision}
                path=body.get('procPath');value.update(descriptorId=row['id'],role=row['role'],arm=row['arm'],
                    decodedPath=path[:1024] if isinstance(path,str) else None,decodedPathExact=path==row['executable'])
                passed.append(value)
            except (ValueError,UnicodeError,RecursionError):pass
        require(len(passed)==1,'no unique supervisor-observed PID/name/birth/time identity')
        return passed[0]


def expected_path(reported,observed,proof,*,bundle=False):
    if reported in (observed,proof['path']):return 'exact-observed-image-path'
    # Literal * is an observed OS placeholder, never expanded as a wildcard.
    if bundle and Path(proof['path']).name=='LatticePackageTests' and reported=='/Users/USER/*/LatticePackageTests':
        return 'literal-user-redaction-plus-anchored-UUID'
    raise ValueError('unknown image path representation')


def sdk_stack(data,row,bundle):
    require(row['role']=='sdk' and row['binary'] is not None and bundle is not None,'observed helper has no admitted image binding')
    body=parse_report.decode_body(data);process=row['binary']
    require(type(body.get('pid')) is int and body['pid']==row['pid'] and body.get('procName')==row['procName'],'SDK report PID/name differs')
    mode=expected_path(body.get('procPath'),row['executable'],process,bundle=process==bundle)
    exception=body.get('exception');require(isinstance(exception,dict) and exception.get('signal')=='SIGSEGV' and exception.get('type') in ('EXC_BAD_ACCESS','EXC_CRASH'),'not signal11 report')
    threads,images,fault=body.get('threads'),body.get('usedImages'),body.get('faultingThread')
    require(isinstance(threads,list) and 0<len(threads)<=512 and all(isinstance(t,dict) for t in threads),'thread bounds')
    require(isinstance(images,list) and 0<len(images)<=4096,'image bounds')
    require(type(fault) is int and 0<=fault<len(threads) and [i for i,t in enumerate(threads) if t.get('triggered') is True]==[fault],'ambiguous triggered thread')
    helper_matches=[]
    for i,image in enumerate(images):
        if not isinstance(image,dict) or not isinstance(image.get('uuid'),str) or image['uuid'].lower()!=process['uuid']:continue
        expected_path(image.get('path'),row['executable'],process,bundle=process==bundle);helper_matches.append(i)
    require(len(helper_matches)==1,'process image UUID not uniquely bound to owned helper')
    frames=threads[fault].get('frames');require(isinstance(frames,list) and 0<len(frames)<=512,'triggered frame bounds')
    matches=[]
    for index,frame in enumerate(frames):
        require(isinstance(frame,dict),'malformed frame');ii=frame.get('imageIndex')
        require(type(ii) is int and 0<=ii<len(images) and isinstance(images[ii],dict),'invalid triggered frame image')
        image=images[ii];symbol=frame.get('symbol')
        if isinstance(image.get('uuid'),str) and image['uuid'].lower()==bundle['uuid'] and isinstance(symbol,str) and 0<len(symbol)<=1024:
            image_mode=expected_path(image.get('path'),bundle['path'],bundle,bundle=True)
            matches.append({'frameIndex':index,'symbol':symbol,'imageIndex':ii,'imageUUID':bundle['uuid'],'pathMode':image_mode})
    require(matches,'no symbolized triggered frame bound to compiled SDK bundle')
    return {'descriptorId':row['id'],'arm':row['arm'],'pid':row['pid'],'observedBirthEpoch':row['birthEpoch'],
            'signal':'SIGSEGV','faultingThread':fault,'processPath':body['procPath'],'processPathMode':mode,
            'processImageUUID':process['uuid'],'processImageSHA256':process['sha256'],
            'bundleImageUUID':bundle['uuid'],'bundleImageSHA256':bundle['sha256'],'sdkFrames':matches,
            'rootCauseEstablished':False,'symbolicationPerformed':False}


def analyze_sdk_reports(collector,identities,bundle):
    accepted=[];rejected=[]
    for entry in collector.snapshot()['files']:
        if entry['status']!='complete' or entry['candidateIdentity']['role']!='sdk':continue
        try:
            raw=read_report(collector.destination/entry['name'],entry['sha256'])
            row=identities.get(entry['candidateIdentity']['descriptorId'])
            require(identities.candidate(raw,row['end'])['descriptorId']==row['id'],'report identity changed')
            accepted.append({'reportName':entry['name'],'reportSHA256':entry['sha256'],'proof':sdk_stack(raw,row,bundle)})
        except (ValueError,UnicodeError,RecursionError) as error:rejected.append({'reportName':entry['name'],'reason':str(error)[:1024]})
    return {'sdkStackCaptured':bool(accepted),'attributed':accepted,'unattributed':rejected,
            'absenceMeaning':'no accepted stack is not evidence that no crash occurred; helper may be unobserved',
            'releaseQualified':False,'crashCauseEstablished':False}
