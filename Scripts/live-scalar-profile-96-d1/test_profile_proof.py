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
        self.shim.write_bytes(profile.SHIM_BYTES)
        self.postimages['sdk'][profile.SDK_PATHS[0]] = guard.digest(self.shim)
        self.import_map = self.write(self.sdk / profile.MODULE_MAP_RELATIVE, profile.MODULE_MAP_BYTES.decode())
        self.module_cache = self.scratch / 'arm64-apple-macosx/release/ModuleCache'
        self.module_cache.mkdir(parents=True)
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
            module_outputs = [module_path, self.write(module_path.with_suffix('.swiftdoc'), 'synthetic doc'),
                              self.write(module_path.with_suffix('.swiftsourceinfo'), 'synthetic source info')]
            dep = self.write(self.scratch / (module + '.d'), '\n'.join(str(output) + ': ' +
                ' '.join(str(x) for x in ([source, self.import_map] if module == 'LatticeTests' else [source]))
                for output in [obj, *module_outputs]) + '\n')
            mapping = {'': {'dependencies': str(dep)}, str(source): {'object': str(obj)}}
            map_path = self.write(self.scratch / (module + '-output-file-map.json'), json.dumps(mapping))
            self.module_maps[module] = map_path
            sources = self.write(self.scratch / (module + '-sources'), shlex.quote(str(source)) + '\n')
            flags = ['-module-name', module, '-target', profile.TARGET, '-sdk', str(self.platform), '-O', '-enable-testing',
                '-D' + profile.PROFILE, '-D' + profile.BATCH, '-Xcc', '-D' + profile.PROFILE + '=1']
            if module == 'LatticeTests':
                flags.extend(['-Xcc', '-fmodule-map-file=' + str(self.import_map),
                              '-Xcc', '-I' + str(self.core / 'Sources/LatticeCore/include'),
                              '-module-cache-path', str(self.module_cache)])
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
        argv = self.drivers['LatticeTests']
        argv[argv.index('-D' + profile.PROFILE + '=1')] = '-D' + profile.PROFILE + '=0'
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

    def test_missing_swift_module_map_dependency(self):
        self.swift_dep.write_text(self.swift_dep.read_text().replace(' ' + str(self.import_map), ''))
        self.rejected('Swift dependency missing')

    def test_changed_shim_include_chain_rejected(self):
        self.shim.write_text('#include <wrong.h>\n')
        self.postimages['sdk'][profile.SDK_PATHS[0]] = guard.digest(self.shim)
        self.rejected('unexpected profile shim include chain')

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

    def test_missing_module_doc_target_rejected(self):
        self.swift_dep.write_text('\n'.join(x for x in self.swift_dep.read_text().splitlines() if '.swiftdoc:' not in x) + '\n')
        self.rejected('missing dependency target')

    def test_duplicate_swift_target_rejected(self):
        self.swift_dep.write_text(self.swift_dep.read_text() + self.swift_dep.read_text().splitlines()[0] + '\n')
        self.rejected('duplicate dependency target')

    def test_harness_input_required_in_every_target_rule(self):
        lines = self.swift_dep.read_text().splitlines()
        lines[0] = lines[0].replace(' ' + str(self.harness), '')
        self.swift_dep.write_text('\n'.join(lines) + '\n')
        self.rejected('Swift dependency missing required per-rule')

    def test_module_map_input_required_in_every_target_rule(self):
        lines = self.swift_dep.read_text().splitlines()
        lines[-1] = lines[-1].replace(' ' + str(self.import_map), '')
        self.swift_dep.write_text('\n'.join(lines) + '\n')
        self.rejected('Swift dependency missing required per-rule')

    def test_changed_derived_module_target_custody(self):
        supplement = self.make()
        (self.scratch / 'LatticeTests.swiftdoc').write_text('changed module doc')
        with self.assertRaisesRegex(ValueError, 'dependency target custody changed'):
            profile.verify(supplement)

    def test_missing_derived_module_output_rejected(self):
        (self.scratch / 'LatticeTests.swiftsourceinfo').unlink()
        self.rejected('dependency target file absent')

    def test_inferred_header_chain_has_no_direct_or_pcm_claim(self):
        supplement = self.make()
        chain = supplement['importerHeaderChain']
        self.assertTrue(chain['directSwiftModuleMapDependency'])
        self.assertFalse(chain['directSwiftTransitiveHeaderProofClaimed'])
        self.assertFalse(chain['pcmCustody'])
        self.assertTrue(chain['requiresRuntimeCounterValidation'])
        self.assertFalse(chain['runtimeCounterValidationPerformed'])
        self.assertNotIn(str(self.shim), supplement['dependencies']['swift']['files'])
        self.assertNotIn(str(self.header), supplement['dependencies']['swift']['files'])

    def test_wrong_module_map_declaration_rejected(self):
        self.import_map.write_text('module CLatticeTestSQLite { header "other.h" }\n')
        self.rejected('unexpected profile module-map declaration')

    def test_driver_module_map_selection_must_match(self):
        argv = self.drivers['LatticeTests']
        i = argv.index('-fmodule-map-file=' + str(self.import_map))
        argv[i] = '-fmodule-map-file=' + str(self.import_map.parent / 'other.modulemap')
        self.rejected('profile importer module-map selection differs')

    def test_frontend_core_include_binding_required(self):
        argv = self.frontends['LatticeTests']
        i = argv.index('-I' + str(self.core / 'Sources/LatticeCore/include'))
        argv[i] = '-I' + str(self.root / 'wrong-include')
        self.rejected('profile importer Core include root absent')

    def test_frontend_cache_must_match_owned_fresh_scratch(self):
        argv = self.frontends['LatticeTests']
        argv[argv.index('-module-cache-path') + 1] = str(self.root / 'old-cache')
        self.rejected('profile importer cache differs')

    def test_prebuilt_custom_module_override_rejected(self):
        self.frontends['LatticeTests'].extend(['-Xcc', '-fmodule-file=CLatticeTestSQLite=fake.pcm'])
        self.rejected('profile importer module-map selection differs|importer VFS/prebuilt/header/cache override')

    def test_earlier_include_header_shadow_rejected(self):
        shadow = self.write(self.sdk / 'shadow/lattice/perf_live_profile.h', 'other header')
        argv = self.frontends['LatticeTests']
        index = argv.index('-I' + str(self.core / 'Sources/LatticeCore/include')) - 1
        argv[index:index] = ['-Xcc', '-I' + str(shadow.parents[1])]
        self.rejected('profile importer header shadowed')

    def test_importer_vfs_override_rejected(self):
        self.frontends['LatticeTests'].extend(['-Xcc', '-ivfsoverlay', '-Xcc', str(self.root/'overlay.json')])
        self.rejected('importer VFS/prebuilt/header/cache override')

    def test_swift_vfs_override_rejected(self):
        self.drivers['LatticeTests'].extend(['-vfsoverlay', str(self.root/'overlay.json')])
        self.rejected('Swift VFS/prebuilt/cache override')

    def test_importer_cache_override_rejected(self):
        self.frontends['LatticeTests'].extend(['-Xcc', '-fmodules-cache-path=' + str(self.root/'old-cache')])
        self.rejected('importer VFS/prebuilt/header/cache override')

    def test_header_map_include_root_rejected(self):
        header_map = self.write(self.sdk/'alternate.hmap', 'synthetic header map')
        argv = self.frontends['LatticeTests']
        index = argv.index('-I' + str(self.core/'Sources/LatticeCore/include')) - 1
        argv[index:index] = ['-Xcc', '-I' + str(header_map)]
        self.rejected('non-directory or relative importer include root')

    def test_alternate_prefix_header_lookup_rejected(self):
        self.frontends['LatticeTests'].extend(['-Xcc', '-iwithprefixbefore', '-Xcc', str(self.sdk/'prefix')])
        self.rejected('importer VFS/prebuilt/header/cache override')

    def test_split_ordinary_swift_header_map_rejected(self):
        header_map = self.write(self.sdk/'ordinary.hmap', 'synthetic header map')
        self.frontends['LatticeTests'].extend(['-I', str(header_map)])
        self.rejected('non-directory or relative importer include root')

    def test_joined_ordinary_swift_header_map_rejected(self):
        header_map = self.write(self.sdk/'ordinary.hmap', 'synthetic header map')
        self.drivers['LatticeTests'].append('-I' + str(header_map))
        self.rejected('non-directory or relative importer include root')

    def test_ordinary_swift_physical_header_shadow_rejected(self):
        shadow = self.write(self.sdk/'ordinary/lattice/perf_live_profile.h', 'other header')
        self.frontends['LatticeTests'].extend(['-I', str(shadow.parents[1])])
        self.rejected('profile importer header shadowed')


if __name__ == '__main__':
    unittest.main()
