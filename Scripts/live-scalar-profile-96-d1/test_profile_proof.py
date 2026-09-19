"""Synthetic text/files only. No compiler, preprocessor, database or subprocess."""
from pathlib import Path
import json
import shlex
import tempfile
import unittest

import build_proof
import guarded_runner as guard
import profile_proof as profile

HERE = Path(__file__).resolve().parent


class ProfileProofTests(unittest.TestCase):
    def setUp(self):
        test_root = HERE / 'pure-test-work'
        test_root.mkdir(exist_ok=True)
        self.temp = tempfile.TemporaryDirectory(prefix='profile-proof-', dir=test_root)
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.sdk, self.core, self.scratch = (self.root / x for x in ('sdk', 'core', 'scratch'))
        for path in (self.sdk, self.core, self.scratch):
            path.mkdir()
        self.toolchain = self.root / 'Xcode.xctoolchain'
        self.platform = self.root / 'platform/Developer/SDKs/MacOSX.sdk'
        self.platform.mkdir(parents=True)
        self.tools = {name: self.write(self.toolchain / 'usr/bin' / name, 'synthetic ' + name)
                      for name in ('clang', 'swiftc', 'swift-frontend')}
        self.postimages = {'sdk': {}, 'core': {}}
        for label, root, names in (('sdk', self.sdk, profile.SDK_PATHS), ('core', self.core, profile.CORE_PATHS)):
            for relative in names:
                path = self.write(root / relative, 'synthetic source: ' + relative)
                self.postimages[label][relative] = guard.digest(path)
        self.library_source = self.write(self.sdk / 'Sources/Lattice/Lattice.swift', 'synthetic Swift library')
        self.db = self.core / profile.CORE_PATHS[0]
        self.header = self.core / profile.CORE_PATHS[2]
        self.shim = self.sdk / profile.SDK_PATHS[0]
        self.harness = self.sdk / profile.SDK_PATHS[1]
        self.db_object = self.write(self.scratch / 'db.cpp.o', 'synthetic native object')
        self.native_dep = self.write(self.scratch / 'db.cpp.d',
            'dependencies: ' + (' ' + chr(92) + '\n ').join(str(self.core / name) for name in profile.CORE_PATHS) + '\n')
        self.native_argv = [str(self.tools['clang']), '-target', profile.TARGET, '-O2', '-isysroot', str(self.platform),
            '-D' + profile.PROFILE + '=1', '-MD', '-MT', 'dependencies', '-MF', str(self.native_dep),
            '-c', str(self.db), '-o', str(self.db_object)]
        self.module_maps, self.drivers, self.frontends, self.objects = {}, {}, {}, [self.db_object]
        for module, source in (('Lattice', self.library_source), ('LatticeTests', self.harness)):
            obj = self.write(self.scratch / (module + '.swift.o'), 'synthetic ' + module + ' object')
            self.objects.append(obj)
            module_path = self.write(self.scratch / (module + '.swiftmodule'), 'synthetic module')
            dep = self.write(self.scratch / (module + '.d'), str(module_path) + ': ' +
                ' '.join(str(x) for x in ([source, self.shim, self.header] if module == 'LatticeTests' else [source])) + '\n')
            mapping = {'': {'dependencies': str(dep)}, str(source): {'object': str(obj)}}
            map_path = self.write(self.scratch / (module + '-output-file-map.json'), json.dumps(mapping))
            self.module_maps[module] = map_path
            sources = self.write(self.scratch / (module + '-sources'), shlex.quote(str(source)) + '\n')
            flags = ['-module-name', module, '-target', profile.TARGET, '-sdk', str(self.platform), '-O', '-enable-testing',
                '-D' + profile.PROFILE, '-D' + profile.BATCH, '-Xcc', '-D' + profile.PROFILE + '=1']
            self.drivers[module] = [str(self.tools['swiftc']), '-c', '@' + str(sources),
                '-emit-dependencies', '-emit-module-path', str(module_path),
                '-output-file-map', str(map_path), *flags]
            self.frontends[module] = [str(self.tools['swift-frontend']), '-frontend', '-c', str(source),
                *flags, '-o', str(obj)]
        self.swift_dep = self.scratch / 'LatticeTests.d'
        self.binary = self.write(self.scratch / 'LatticePackageTests.xctest/Contents/MacOS/LatticePackageTests', 'synthetic linked binary')
        self.link_list = self.write(self.scratch / 'LinkFileList', '\n'.join(map(str, self.objects)) + '\n')
        self.link_argv = [str(self.tools['swiftc']), '-filelist', str(self.link_list), '-o', str(self.binary)]
        self.log = self.root / 'build.log'

    def write(self, path, value):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(value)
        return path

    def base(self):
        commands = [self.native_argv]
        for module in self.drivers:
            commands.extend((self.drivers[module], self.frontends[module]))
        commands.append(self.link_argv)
        self.log.write_text('\n'.join(shlex.join(argv) for argv in commands) + '\n')
        return build_proof.make(self.log, self.sdk, self.core, self.scratch, profile.SDK_PATHS[1])

    def make(self, base=None):
        return profile.make(self.base() if base is None else base, self.log, self.sdk, self.core,
                            self.scratch, self.postimages, self.root / 'retained')

    def rejected(self, pattern):
        with self.assertRaisesRegex((ValueError, AssertionError), pattern):
            self.make()

    def test_valid_actual_source_object_and_dependency_joins(self):
        supplement = self.make()
        profile.verify(supplement)
        self.assertEqual(set(supplement['sources']), {str(self.core / p) for p in profile.CORE_PATHS}
                         | {str(self.sdk / p) for p in profile.SDK_PATHS})
        self.assertEqual(len(supplement['actions']), 5)
        self.assertFalse(supplement['performanceGoalCredit'])

    def test_missing_native_profile_flag(self):
        self.native_argv.remove('-D' + profile.PROFILE + '=1')
        self.rejected('missing explicit')

    def test_conflicting_native_profile_definition(self):
        self.native_argv.extend(['-D' + profile.PROFILE + '=0'])
        self.rejected('conflicting')

    def test_native_undefinition(self):
        self.native_argv.extend(['-U', profile.PROFILE])
        self.rejected('undefinition')

    def test_old_prototype_is_forbidden(self):
        self.native_argv.append('-D' + profile.FORBIDDEN[0] + '=0')
        self.rejected('old prototype')

    def test_missing_swift_profile_define(self):
        self.drivers['Lattice'].remove('-D' + profile.PROFILE)
        self.rejected('missing explicit')

    def test_missing_selected_batch_define(self):
        self.drivers['LatticeTests'].remove('-D' + profile.BATCH)
        self.rejected('missing explicit')

    def test_importer_mismatch(self):
        self.drivers['LatticeTests'][-1] = '-D' + profile.PROFILE + '=0'
        self.rejected('conflicting')

    def test_frontend_importer_mismatch(self):
        argv = self.frontends['LatticeTests']
        argv[argv.index('-Xcc') + 1] = '-D' + profile.PROFILE + '=0'
        self.rejected('conflicting')

    def test_frontend_hidden_undefinition(self):
        self.frontends['LatticeTests'].extend(['-Xfrontend', '-U' + profile.PROFILE])
        self.rejected('undefinition')

    def test_frontend_actual_source_mismatch(self):
        self.frontends['LatticeTests'][3] = str(self.library_source)
        self.rejected('frontend source/object set differs')

    def test_native_target_mismatch(self):
        self.native_argv[self.native_argv.index('-target') + 1] = 'x86_64-apple-macosx14.0'
        self.rejected('actual compile target differs')

    def test_swift_driver_target_mismatch(self):
        argv = self.drivers['LatticeTests']
        argv[argv.index('-target') + 1] = 'arm64-apple-macosx15.0'
        self.rejected('actual compile target differs')

    def test_frontend_target_missing(self):
        argv = self.frontends['LatticeTests']
        index = argv.index('-target')
        del argv[index:index + 2]
        self.rejected('missing or repeated -target')

    def test_alternate_target_override(self):
        self.native_argv.append('--target=x86_64-apple-macosx14.0')
        self.rejected('alternate target spelling')

    def test_frontend_release_optimization_missing(self):
        self.frontends['LatticeTests'].remove('-O')
        self.rejected('consistent Release/testability flags')

    def test_frontend_release_optimization_conflict(self):
        self.frontends['LatticeTests'].append('-Onone')
        self.rejected('consistent Release/testability flags')

    def test_frontend_testability_missing(self):
        self.frontends['LatticeTests'].remove('-enable-testing')
        self.rejected('consistent Release/testability flags')

    def test_forced_macro_header_rejected(self):
        self.native_argv.extend(['-include', str(self.header)])
        self.rejected('forced macro input unsupported')

    def test_swift_importer_sdk_mismatch(self):
        other = self.root / 'other/Developer/SDKs/MacOSX.sdk'
        other.mkdir(parents=True)
        self.drivers['LatticeTests'].extend(['-Xcc', '-isysroot', '-Xcc', str(other)])
        self.rejected('Swift importer SDK differs')

    def test_missing_native_header_dependency(self):
        self.native_dep.write_text('dependencies: ' + str(self.db) + '\n')
        self.rejected('native dependency missing')

    def test_missing_swift_shim_dependency(self):
        self.swift_dep.write_text(self.swift_dep.read_text().replace(' ' + str(self.shim), ''))
        self.rejected('Swift dependency missing')

    def test_missing_swift_header_dependency(self):
        self.swift_dep.write_text(self.swift_dep.read_text().replace(' ' + str(self.header), ''))
        self.rejected('Swift dependency missing')

    def test_wrong_postimage_source_hash(self):
        self.postimages['core'][profile.CORE_PATHS[0]] = '0' * 64
        self.rejected('postimage source hash mismatch')

    def test_driver_does_not_actually_consume_harness(self):
        self.drivers['LatticeTests'][2] = str(self.library_source)
        self.rejected('actual Swift driver source set')

    def test_harness_object_not_reachable(self):
        base = self.base()
        del base['linkGraph'][str(self.binary)]['inputs'][str(self.objects[2])]
        with self.assertRaisesRegex(ValueError, 'not reachable'):
            self.make(base)

    def test_changed_tool_custody(self):
        supplement = self.make()
        self.tools['clang'].write_text('changed tool')
        with self.assertRaisesRegex(ValueError, 'tool custody changed'):
            profile.verify(supplement)

    def test_changed_dependency_custody(self):
        supplement = self.make()
        self.swift_dep.write_text(self.swift_dep.read_text() + '\n')
        with self.assertRaisesRegex(ValueError, 'dependency custody changed'):
            profile.verify(supplement)

    def test_changed_dependency_input_custody(self):
        extra = self.write(self.platform / 'usr/include/other.h', 'original header')
        self.native_dep.write_text(self.native_dep.read_text().rstrip() + ' ' + str(extra) + '\n')
        supplement = self.make()
        extra.write_text('changed header')
        with self.assertRaisesRegex(ValueError, 'dependency input custody changed'):
            profile.verify(supplement)

    def test_changed_retained_dependency_custody(self):
        supplement = self.make()
        Path(supplement['dependencies']['swift']['retainedPath']).write_text('altered')
        with self.assertRaisesRegex(ValueError, 'dependency custody changed'):
            profile.verify(supplement)

    def test_dependency_outside_authenticated_roots(self):
        outsider = self.write(self.root / 'outside.h', 'outside')
        self.native_dep.write_text(self.native_dep.read_text().rstrip() + ' ' + str(outsider) + '\n')
        self.rejected('outside authenticated roots')

    def test_unknown_multiple_dependency_rules(self):
        self.native_dep.write_text(self.native_dep.read_text() + 'extra: fake\n')
        self.rejected('unknown dependency rule')

    def test_dependency_target_not_from_driver(self):
        self.swift_dep.write_text('fake.o: ' + str(self.harness) + '\n')
        self.rejected('unexpected dependency target')


if __name__ == '__main__':
    unittest.main()
