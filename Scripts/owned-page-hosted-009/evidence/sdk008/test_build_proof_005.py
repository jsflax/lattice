"""Synthetic pure parser/refusal checks; never runs a compiler or database."""
import copy
import json
from pathlib import Path
import shlex
import tempfile
import unittest

import build_proof as proof

P = Path(__file__).resolve().parent


class PluginStateTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(dir=P / 'pure-tmp')
        self.root = Path(self.tmp.name)
        self.scratch = self.root / 'scratch'
        self.cache = self.scratch / 'plugins/cache'
        self.cache.mkdir(parents=True)
        self.compiler = self.write(self.root / 'toolchain/usr/bin/swiftc')
        self.sdk = self.root / 'platform/Developer/SDKs/Test.sdk'
        self.sdk.mkdir(parents=True)
        checkout = self.scratch / 'checkouts/swift-docc-plugin'
        plugin = checkout / 'Plugins/Swift-DocC Convert'
        main = self.write(plugin / 'Main.swift')
        shared = self.write(checkout / 'Plugins/SharedPackagePluginExtensions/Shared.swift')
        utilities = self.write(checkout / 'Sources/SwiftDocCPluginUtilities/Utility.swift')
        links = plugin / 'Symbolic Links'; links.mkdir()
        (links / 'SharedPackagePluginExtensions').symlink_to(shared.parent)
        (links / 'SwiftDocCPluginUtilities').symlink_to(utilities.parent)
        sources = [str(main), str(links / 'SharedPackagePluginExtensions/Shared.swift'),
                   str(links / 'SwiftDocCPluginUtilities/Utility.swift')]
        api = self.compiler.parent.parent / 'lib/swift/pm/PluginAPI'
        platform = self.sdk.parent.parent
        self.binary = self.write(self.cache / 'Swift_DocC')
        self.diagnostics = self.write(self.cache / 'Swift_DocC.dia')
        self.state_path = self.cache / 'Swift_DocC-state.json'
        self.log = self.root / 'build.log'
        self.state = {'commandLine': [str(self.compiler), '-L', str(api), '-lPackagePlugin',
            '-Xlinker', '-rpath', '-Xlinker', str(api), '-target', 'arm64-apple-macosx14.0',
            '-plugin-path', str(self.compiler.parent.parent / 'lib/swift/host/plugins/testing'),
            '-sdk', str(self.sdk), '-F', str(platform / 'Library/Frameworks'),
            '-I', str(platform / 'usr/lib'), '-L', str(platform / 'usr/lib'), '-g',
            '-swift-version', '5', '-package-description-version', '5.7.0', '-I', str(api),
            '-sdk', str(self.sdk), '-module-cache-path', str(self.root / 'module-cache'),
            '-parse-as-library', '-j2', '-Xfrontend', '-serialize-diagnostics-path', '-Xfrontend',
            str(self.diagnostics), *sources, '-o', str(self.binary), '-v'],
            'environment': {'SYNTHETIC': '1'}, 'inputHash': 'a' * 64,
            'output': 'synthetic compiler output\n', 'result': {'exit': {'code': 0}}}
        self.save()

    def tearDown(self):
        self.tmp.cleanup()

    def write(self, path, data='synthetic bytes'):
        path.parent.mkdir(parents=True, exist_ok=True); path.write_text(data); return path

    def save(self):
        self.state_path.write_text(json.dumps(self.state))
        self.log.write_text(' '.join(self.state['commandLine']) + '\n' + self.state['output'])

    def records(self):
        return proof.package_plugin_drivers(self.log, self.scratch)

    def refused(self):
        with self.assertRaises((AssertionError, FileNotFoundError, TypeError, KeyError)):
            self.records()

    def test_typed_spaces_sources_results_products_and_jobs(self):
        self.assertNotEqual(shlex.split(' '.join(self.state['commandLine'])), self.state['commandLine'])
        record = next(iter(self.records().values()))
        self.assertEqual(record['argv'], self.state['commandLine'])
        self.assertEqual(len(record['sources']), 3)
        self.assertEqual(record['jobs']['jobValues'], ['2'])
        self.assertFalse(record['inputHashIndependentlyRecomputed'])
        proof.verify_package_plugin(record)

    def test_repeated_output_bound_to_exact_immediate_block(self):
        self.log.write_text(self.state['output'] + self.log.read_text())
        record = next(iter(self.records().values()))
        self.assertEqual(record['outputTextOccurrencesInLog'], 2)
        self.assertEqual(record['outputLogStartLine'], record['lineNumber'] + 1)

    def test_missing_larger_or_opposing_jobs_refused(self):
        original = copy.deepcopy(self.state)
        for replacement in [[], ['-j16'], ['-j2', '-j', '16']]:
            self.state = copy.deepcopy(original)
            index = self.state['commandLine'].index('-j2')
            self.state['commandLine'][index:index + 1] = replacement
            self.save(); self.refused()

    def test_failed_untyped_or_unknown_results_refused(self):
        for result in [{'exit': {'code': 1}}, {'exit': {'code': False}}, {'signal': 0}, {'exit': {'code': 0}, 'other': 1}]:
            self.state['result'] = result; self.save(); self.refused()

    def test_missing_duplicate_or_requoted_command_refused(self):
        self.log.write_text(self.state['output']); self.refused()
        self.save(); self.log.write_text(self.log.read_text() * 2); self.refused()
        self.log.write_text(shlex.join(self.state['commandLine']) + '\n' + self.state['output']); self.refused()

    def test_missing_or_displaced_output_refused(self):
        self.log.write_text(' '.join(self.state['commandLine']) + '\n'); self.refused()
        self.log.write_text(' '.join(self.state['commandLine']) + '\ninterleaved\n' + self.state['output']); self.refused()

    def test_omitted_or_duplicate_source_refused(self):
        original = copy.deepcopy(self.state)
        arg = next(a for a in self.state['commandLine'] if a.endswith('.swift'))
        self.state['commandLine'].remove(arg); self.save(); self.refused()
        self.state = original; self.state['commandLine'].append(arg); self.save(); self.refused()

    def test_source_symlink_escape_refused(self):
        arg = next(a for a in self.state['commandLine'] if 'SharedPackagePluginExtensions/Shared.swift' in a)
        target = Path(arg).parent; target.unlink()
        outside = self.root / 'foreign'; self.write(outside / 'Shared.swift')
        target.symlink_to(outside); self.refused()

    def test_unknown_state_or_driver_shape_refused(self):
        self.write(self.cache / 'Unknown-state.json', self.state_path.read_text()); self.refused()
        (self.cache / 'Unknown-state.json').unlink()
        self.state['commandLine'].extend(['-module-name', 'Unexpected']); self.save(); self.refused()

    def test_foreign_library_or_import_input_refused(self):
        original = copy.deepcopy(self.state)
        for flag in ['-L', '-I', '-F']:
            self.state = copy.deepcopy(original)
            self.state['commandLine'][self.state['commandLine'].index(flag) + 1] = str(self.root / 'foreign')
            self.save(); self.refused()

    def test_state_source_compiler_and_binary_custody(self):
        record = next(iter(self.records().values()))
        for path in [self.state_path, self.compiler, self.binary, self.diagnostics,
                     Path(next(iter(record['sources'])))]:
            raw = path.read_bytes(); path.write_bytes(raw + b'changed')
            with self.subTest(path=path), self.assertRaises(AssertionError):
                proof.verify_package_plugin(record)
            path.write_bytes(raw)

    def test_missing_binary_or_symlink_product_refused(self):
        self.binary.unlink(); self.refused()
        other = self.write(self.root / 'other-binary'); self.binary.symlink_to(other); self.refused()


class LinkerResponseTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(dir=P / 'pure-tmp')
        self.root = Path(self.tmp.name); self.scratch = self.root / 'scratch'; self.scratch.mkdir()

    def tearDown(self):
        self.tmp.cleanup()

    def test_only_consumed_exact_loader_path_is_literal(self):
        response = self.scratch / 'Objects.LinkFileList'; response.write_text('"/owned/object with spaces.o"')
        argv = ['swiftc', '-Xlinker', '-rpath', '-Xlinker', '@loader_path', '@' + str(response)]
        expanded, files = proof.native_arguments(argv, self.scratch)
        self.assertEqual(expanded, argv[:-1] + ['/owned/object with spaces.o'])
        self.assertEqual(files, {str(response): proof.guard.digest(response)})

    def test_loader_spelling_without_exact_consumer_remains_response(self):
        for argv in [['swiftc', '@loader_path'], ['swiftc', '-Xlinker', '@loader_path'],
                     ['swiftc', '-Xlinker', '-rpath', '@loader_path'],
                     ['swiftc', '-Xlinker', '-rpath', '-Xlinker', '@loader_path/extra'],
                     ['swiftc', '-Xlinker', '-rpath', '-Xlinker', '@other']]:
            with self.subTest(argv=argv), self.assertRaises(AssertionError):
                proof.native_arguments(argv, self.scratch)

    def test_nested_response_keeps_jobs_and_owned_bounds(self):
        response = self.scratch / 'args.rsp'
        response.write_text('-j2 -Xlinker -rpath -Xlinker @loader_path')
        self.assertEqual(proof.swift_driver_jobs(['swiftc', '@' + str(response)], self.scratch)['jobValues'], ['2'])
        response.write_text('-j16 -Xlinker -rpath -Xlinker @loader_path')
        with self.assertRaises(AssertionError): proof.swift_driver_jobs(['swiftc', '@' + str(response)], self.scratch)
        foreign = self.root / 'outside.rsp'; foreign.write_text('-j2')
        response.write_text('@' + str(foreign))
        with self.assertRaises(AssertionError): proof.native_arguments(['swiftc', '@' + str(response)], self.scratch)


if __name__ == '__main__':
    unittest.main()
