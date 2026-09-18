"""Bounded owned thin arm64 executable identity; no native tool or code execution."""
import hashlib
import os
import stat
import struct
import uuid

MAX_BINARY = 8 * 2**20
MAX_COMMAND_BYTES = 64 * 2**10
MAX_COMMANDS = 256


def require(value, message):
    if not value:
        raise ValueError(message)


def parse(data):
    require(isinstance(data, bytes) and 32 <= len(data) <= MAX_BINARY, 'Mach-O byte bounds')
    magic, cpu, subtype, kind, count, command_bytes, flags, reserved = struct.unpack_from('<8I', data)
    require(magic == 0xfeedfacf, 'expected thin little-endian 64-bit Mach-O')
    require(cpu == 0x0100000c and kind == 2, 'expected arm64 MH_EXECUTE')
    require(0 < count <= MAX_COMMANDS and 8*count <= command_bytes <= MAX_COMMAND_BYTES, 'load command bounds')
    end = 32 + command_bytes
    require(end <= len(data), 'truncated load commands')
    cursor, identity = 32, None
    for _ in range(count):
        require(cursor+8 <= end, 'truncated command header')
        command, size = struct.unpack_from('<2I', data, cursor)
        require(size >= 8 and size % 8 == 0 and cursor+size <= end, 'invalid load command size')
        if command == 0x1b:
            require(size == 24 and identity is None, 'invalid or duplicate LC_UUID')
            raw = data[cursor+8:cursor+24]
            require(any(raw), 'nil LC_UUID')
            identity = str(uuid.UUID(bytes=raw))
        cursor += size
    require(cursor == end and identity is not None, 'load command extent or missing LC_UUID')
    return {'format':'thin little-endian Mach-O 64', 'architecture':'arm64',
            'fileType':'MH_EXECUTE', 'uuid':identity, 'loadCommands':count,
            'loadCommandBytes':command_bytes, 'bytes':len(data),
            'sha256':hashlib.sha256(data).hexdigest()}


def inspect(path):
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    with os.fdopen(fd, 'rb') as stream:
        before = os.fstat(stream.fileno())
        require(stat.S_ISREG(before.st_mode) and 32 <= before.st_size <= MAX_BINARY, 'owned executable size/type')
        data = stream.read(MAX_BINARY+1)
        after = os.fstat(stream.fileno())
    def identity(value):
        return (value.st_dev,value.st_ino,value.st_size,value.st_mtime_ns,value.st_ctime_ns)
    require(identity(before) == identity(after) and len(data) == before.st_size, 'executable changed during read')
    require(identity(after) == identity(os.stat(path, follow_symlinks=False)), 'executable path replaced during read')
    return parse(data)
