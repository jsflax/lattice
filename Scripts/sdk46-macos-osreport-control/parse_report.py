"""Strict modern .ips control identity. Unknown/unsymbolized formats reject."""
import datetime
import json
import math
from pathlib import Path
import re

MAX_REPORT = 8 * 2**20
CONTROL = re.compile(r'^(?:SDK46CrashControl\.)?latticeSDK46DiagnosticCrashControl\(\)(?: -> \(\))?$')


def require(value, message):
    if not value:
        raise ValueError(message)


def epoch(value):
    require(isinstance(value, str) and len(value) <= 128, 'missing bounded report time')
    # Accept an explicit numeric-zone report representation. This changes only
    # syntax, not the launch/capture bounds or timezone requirement.
    spaced = re.fullmatch(r'(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}(?:\.\d{1,9})?) ([+-]\d{4})', value)
    if spaced:
        value = spaced[1] + spaced[2]
    parsed = datetime.datetime.fromisoformat(value)
    require(parsed.tzinfo is not None, 'report time lacks offset')
    return parsed.timestamp()


def decode_body(data):
    require(isinstance(data, bytes) and 0 < len(data) <= MAX_REPORT, 'report byte bounds')
    text = data.decode('utf-8')
    require('\0' not in text, 'NUL in report')
    def unique_object(pairs):
        value = {}
        for key, item in pairs:
            require(key not in value, 'duplicate JSON key')
            value[key] = item
        return value
    decoder, values, cursor = json.JSONDecoder(object_pairs_hook=unique_object), [], 0
    while cursor < len(text):
        while cursor < len(text) and text[cursor].isspace():
            cursor += 1
        if cursor == len(text):
            break
        require(len(values) < 2, 'unexpected extra JSON document')
        value, cursor = decoder.raw_decode(text, cursor)
        require(isinstance(value, dict), 'report document must be an object')
        values.append(value)
    require(values, 'missing report body')
    # Current Apple .ips may have one metadata JSON line before its body.
    body = values[-1]
    if len(values) == 2:
        require('procPath' not in values[0] and 'threads' not in values[0], 'ambiguous report body')
    return body


def retention_candidate(data, *, executable, pid, launch_begin, exit_end, scan_end):
    """Own-report custody only. Path/exception/symbol rejection must retain evidence."""
    require(type(pid) is int and pid > 0, 'invalid owned PID')
    require(0 < launch_begin <= exit_end <= scan_end and scan_end-launch_begin <= 240, 'invalid control time window')
    body = decode_body(data)
    require(type(body.get('pid')) is int and body['pid'] == pid, 'candidate PID differs')
    require(body.get('procName') == Path(executable).name, 'candidate process name differs')
    captured, launched = epoch(body.get('captureTime')), epoch(body.get('procLaunch'))
    require(math.floor(launch_begin) <= launched <= math.ceil(exit_end), 'candidate launch outside control window')
    require(math.floor(launch_begin) <= captured <= math.ceil(scan_end) and launched <= captured, 'candidate capture outside control window')
    path = body.get('procPath')
    return {'retentionOnly':True, 'fullAdmission':False, 'pid':pid, 'procName':body['procName'],
            'launchEpoch':launched, 'captureEpoch':captured,
            'decodedPathExact':path == executable,
            'decodedPath':path[:1024] if isinstance(path,str) else None,
            'decodedPathTruncated':isinstance(path,str) and len(path)>1024}


def parse(data, *, executable, pid, launch_begin, exit_end, scan_end):
    require(type(pid) is int and pid > 0, 'invalid owned PID')
    require(0 < launch_begin <= exit_end <= scan_end and scan_end-launch_begin <= 240, 'invalid control time window')
    body = decode_body(data)
    require(body.get('procPath') == executable, 'exact owned executable path differs')
    require(type(body.get('pid')) is int and body['pid'] == pid, 'owned PID differs')
    captured = epoch(body.get('captureTime'))
    # Reports may serialize timestamps at whole-second precision. Floor/ceil
    # bound only that representation, not a broad age window or stale-PID retry.
    require(math.floor(launch_begin) <= captured <= math.ceil(scan_end), 'capture outside launch/scan window')
    if 'procLaunch' in body:
        launched = epoch(body['procLaunch'])
        require(math.floor(launch_begin) <= launched <= math.ceil(exit_end), 'process launch outside control window')
        require(launched <= captured, 'report capture predates process launch')
    exception = body.get('exception')
    require(isinstance(exception, dict) and exception.get('signal') == 'SIGSEGV' and
            exception.get('type') in ('EXC_BAD_ACCESS', 'EXC_CRASH'), 'report is not the signal-11 crash')
    threads, images, fault = body.get('threads'), body.get('usedImages'), body.get('faultingThread')
    require(isinstance(threads, list) and 0 < len(threads) <= 512, 'thread bounds')
    require(isinstance(images, list) and 0 < len(images) <= 4096, 'image bounds')
    require(type(fault) is int and 0 <= fault < len(threads), 'missing crashed-thread index')
    require(all(isinstance(t, dict) for t in threads), 'malformed thread')
    require([i for i,t in enumerate(threads) if t.get('triggered') is True] == [fault], 'ambiguous triggered thread')
    frames = threads[fault].get('frames')
    require(isinstance(frames, list) and 0 < len(frames) <= 512, 'crashed-frame bounds')
    matches = []
    for index, frame in enumerate(frames):
        require(isinstance(frame, dict), 'malformed crashed frame')
        symbol = frame.get('symbol')
        if not isinstance(symbol, str) or len(symbol) > 1024 or not CONTROL.fullmatch(symbol):
            continue
        image_index = frame.get('imageIndex')
        require(type(image_index) is int and 0 <= image_index < len(images), 'control frame lacks valid image')
        image = images[image_index]
        require(isinstance(image, dict) and image.get('path') == executable, 'control frame is from another image')
        uuid = image.get('uuid')
        require(isinstance(uuid, str) and re.fullmatch(r'[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}', uuid), 'missing control image UUID')
        matches.append({'frameIndex':index, 'symbol':symbol, 'imageIndex':image_index, 'imageUUID':uuid})
    require(matches, 'no symbolized named control frame on crashed thread')
    return {'format':'Apple ips JSON', 'procPath':executable, 'pid':pid, 'captureEpoch':captured,
            'faultingThread':fault, 'signal':'SIGSEGV', 'controlFrames':matches,
            'symbolicationPerformed':False}
