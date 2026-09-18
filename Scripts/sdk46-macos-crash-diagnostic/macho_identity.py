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


# SDK/helper images have an independently retained streaming whole-file hash.
# Keep the qualified tiny-control parse/inspect functions above unchanged.
MAX_FAT_ARCHES = 8
MAX_IMAGE_HEADER_READ = 32 + MAX_FAT_ARCHES * 32 + MAX_FAT_ARCHES * 32 + MAX_COMMAND_BYTES
ARM64 = 0x0100000c
X86_64 = 0x01000007


def image_header(stream, file_bytes, allowed_types, evidence):
    """Select one unambiguous plain arm64 slice; never infer loaded UUID from IPS."""
    evidence.update(fileBytes=file_bytes, format='unclassified', headerBytesRead=0)

    def read_at(offset, count):
        require(0 <= offset <= file_bytes and 0 <= count <= file_bytes-offset, 'image read extent')
        require(evidence['headerBytesRead'] + count <= MAX_IMAGE_HEADER_READ, 'image header read budget')
        stream.seek(offset)
        data = stream.read(count)
        evidence['headerBytesRead'] += len(data)
        require(len(data) == count, 'truncated image header region')
        return data

    prefix = read_at(0, min(32, file_bytes))
    evidence['prefixHex'] = prefix.hex()
    require(len(prefix) >= 8, 'truncated image magic/header')
    magic_be, count_be = struct.unpack_from('>2I', prefix)
    evidence['magicBigEndian'] = '0x%08x' % magic_be

    def decode_header(data):
        require(len(data) == 32, 'truncated Mach-O slice header')
        values = struct.unpack('<8I', data)
        return dict(zip(('magic', 'cpuType', 'cpuSubtype', 'fileType',
                         'loadCommands', 'loadCommandBytes', 'flags', 'reserved'), values))

    slices = []
    if prefix[:4] == b'\xcf\xfa\xed\xfe':
        evidence['format'] = 'thin little-endian Mach-O 64'
        header = decode_header(prefix)
        evidence['thinHeader'] = header
        require(header['cpuType'] == ARM64 and header['cpuSubtype'] == 0,
                'unsupported thin architecture/subtype; plain arm64 required')
        selected = {'index': 0, 'offset': 0, 'bytes': file_bytes,
                    'cpuType': ARM64, 'cpuSubtype': 0, 'header': header}
    elif magic_be in (0xcafebabe, 0xcafebabf):
        wide = magic_be == 0xcafebabf
        entry_bytes = 32 if wide else 20
        evidence.update(format='universal big-endian FAT64' if wide else 'universal big-endian FAT32',
                        fatArchitectureCount=count_be, fatEntryBytes=entry_bytes)
        require(0 < count_be <= MAX_FAT_ARCHES, 'fat architecture count bound')
        table_end = 8 + count_be * entry_bytes
        require(table_end <= file_bytes, 'truncated fat architecture table')
        table = read_at(8, count_be * entry_bytes)
        evidence['fatTableHex'] = table.hex()
        for index in range(count_be):
            fields = struct.unpack_from('>IIQQII' if wide else '>IIIII', table, index * entry_bytes)
            cpu, subtype, offset, size, align = fields[:5]
            slices.append({'index': index, 'cpuType': cpu, 'cpuSubtype': subtype,
                           'offset': offset, 'bytes': size, 'alignmentExponent': align,
                           'reserved': fields[5] if wide else 0})
        evidence['fatSlices'] = slices
        seen = set()
        for item in slices:
            cpu, subtype = item['cpuType'], item['cpuSubtype']
            # ARM64E/V8/X1 and unknown feature bits are outside this diagnostic.
            # A universal file may additionally contain one known x86_64 slice;
            # the existing launcher requires a native arm64 host.
            require((cpu == ARM64 and subtype == 0) or
                    (cpu == X86_64 and subtype in (3, 8, 0x80000003, 0x80000008)),
                    'unsupported fat architecture/subtype')
            require(cpu not in seen, 'ambiguous duplicate fat architecture')
            seen.add(cpu)
            offset, size, align = item['offset'], item['bytes'], item['alignmentExponent']
            require(item['reserved'] == 0 and 0 <= align <= 31, 'fat reserved/alignment field')
            require(table_end <= offset <= file_bytes and 32 <= size <= file_bytes-offset,
                    'fat slice outside file/table extent')
            require(offset % (1 << align) == 0, 'fat slice offset alignment')
        ordered = sorted(slices, key=lambda item: item['offset'])
        require(all(left['offset'] + left['bytes'] <= right['offset']
                    for left, right in zip(ordered, ordered[1:])), 'overlapping fat slices')
        choices = [item for item in slices if item['cpuType'] == ARM64]
        require(len(choices) == 1, 'exactly one plain arm64 slice required')
        for item in slices:
            header = decode_header(read_at(item['offset'], 32))
            item['header'] = header
            require(header['magic'] == 0xfeedfacf and
                    (header['cpuType'], header['cpuSubtype']) == (item['cpuType'], item['cpuSubtype']),
                    'fat table/slice architecture disagreement')
            require(header['fileType'] in allowed_types and header['reserved'] == 0,
                    'unsupported fat slice file type/reserved field')
        selected = choices[0]
        header = selected['header']
    else:
        raise ValueError('unsupported image magic; little-endian thin64 or big-endian FAT32/FAT64 required')

    evidence['selectedSliceIndex'] = selected['index']
    require(header['fileType'] in allowed_types and header['reserved'] == 0,
            'unsupported selected image file type/reserved field')
    count, size = header['loadCommands'], header['loadCommandBytes']
    require(0 < count <= MAX_COMMANDS and 8*count <= size <= MAX_COMMAND_BYTES and
            32 + size <= selected['bytes'], 'selected image load command bounds')
    commands = read_at(selected['offset'] + 32, size)
    cursor, identity = 0, None
    for _ in range(count):
        require(cursor + 8 <= size, 'truncated selected image command header')
        command, length = struct.unpack_from('<2I', commands, cursor)
        require(length >= 8 and length % 8 == 0 and cursor + length <= size,
                'invalid selected image command extent')
        if command == 0x1b:
            require(length == 24 and identity is None, 'invalid/duplicate selected image LC_UUID')
            raw = commands[cursor+8:cursor+24]
            require(any(raw), 'nil selected image LC_UUID')
            identity = str(uuid.UUID(bytes=raw))
        cursor += length
    require(cursor == size and identity is not None, 'selected command span/missing LC_UUID')
    return {'format': evidence['format'], 'architecture': 'arm64', 'cpuSubtype': 0,
            'fileType': header['fileType'], 'uuid': identity, 'loadCommands': count,
            'loadCommandBytes': size, 'selectedSlice': {
                key: selected[key] for key in ('index', 'offset', 'bytes', 'cpuType', 'cpuSubtype')},
            'containerArchitectures': [{key: item[key] for key in (
                'index', 'cpuType', 'cpuSubtype', 'offset', 'bytes')} for item in slices]}
