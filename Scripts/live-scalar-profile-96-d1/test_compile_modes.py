"""Parser-only regressions for object production and dependency generation."""
import contextlib
import shlex
import unittest
import build_proof
import profile_proof as profile
import test_profile_proof as fixture

@contextlib.contextmanager
def sample():
    t=fixture.ProfileProofTests();t.setUp()
    try:yield t
    finally:t.doCleanups()

def custom_base(t,commands):
    t.log.write_text('\n'.join(shlex.join(a) for a in commands)+'\n')
    return build_proof.make(t.log,t.sdk,t.core,t.scratch,profile.SDK_PATHS[1])

class CompileModes(unittest.TestCase):
    def reject(self,t,base=None,pattern='compile|frontend|dependency'):
        with self.assertRaisesRegex((ValueError,AssertionError),pattern):t.make(base)
    def test_control(self):
        with sample() as t:self.assertEqual(len(t.make()['actions']),5)
    def test_emit_module_driver_without_frontends(self):
        with sample() as t:
            for a in t.drivers.values():a[a.index('-c')]='-emit-module'
            self.reject(t,custom_base(t,[t.native_argv,*t.drivers.values(),t.link_argv]))
    def test_compile_drivers_without_frontends(self):
        with sample() as t:self.reject(t,custom_base(t,[t.native_argv,*t.drivers.values(),t.link_argv]))
    def test_only_one_selected_frontend_absent(self):
        with sample() as t:self.reject(t,custom_base(t,[t.native_argv,t.drivers['Lattice'],t.frontends['Lattice'],t.drivers['LatticeTests'],t.link_argv]))
    def test_typecheck_frontends(self):
        with sample() as t:
            for a in t.frontends.values():a[a.index('-c')]='-typecheck'
            self.reject(t)
    def test_contradictory_swift_driver_mode(self):
        with sample() as t:
            t.drivers['LatticeTests'].append('-typecheck');self.reject(t)
    def test_contradictory_swift_frontend_mode(self):
        with sample() as t:
            t.frontends['LatticeTests'].append('-typecheck');self.reject(t)
    def test_module_only_frontend_cannot_replace_compile(self):
        with sample() as t:
            t.frontends['LatticeTests'][2]='-emit-module';self.reject(t)
    def test_two_compile_frontends_refused(self):
        with sample() as t:
            commands=[t.native_argv,t.drivers['Lattice'],t.frontends['Lattice'],t.frontends['Lattice'],t.drivers['LatticeTests'],t.frontends['LatticeTests'],t.link_argv]
            self.reject(t,custom_base(t,commands))
    def test_frontend_before_driver_refused(self):
        with sample() as t:self.reject(t,custom_base(t,[t.native_argv,*t.frontends.values(),*t.drivers.values(),t.link_argv]))
    def test_frontend_duplicate_source_refused(self):
        with sample() as t:
            t.frontends['LatticeTests'].append(str(t.harness));self.reject(t)
    def test_frontend_duplicate_object_refused(self):
        with sample() as t:
            t.frontends['LatticeTests'].extend(['-o',str(t.objects[2])]);self.reject(t)
    def test_native_missing_dependency_generation(self):
        with sample() as t:
            t.native_argv.remove('-MD');self.reject(t)
    def test_native_syntax_only_contradiction(self):
        with sample() as t:
            t.native_argv.append('-fsyntax-only');self.reject(t)
    def test_native_dependency_only_contradiction(self):
        with sample() as t:
            t.native_argv.append('-M');self.reject(t)
    def test_native_preprocess_only_contradiction(self):
        with sample() as t:
            t.native_argv.append('-E');self.reject(t)
    def test_native_assembly_only_contradiction(self):
        with sample() as t:
            t.native_argv.append('-S');self.reject(t)
    def test_native_user_headers_only_mode_refused(self):
        with sample() as t:
            t.native_argv[t.native_argv.index('-MD')]='-MMD';self.reject(t)
    def test_native_conflicting_dependency_mode_refused(self):
        with sample() as t:
            t.native_argv.append('-MMD');self.reject(t)
    def test_native_repeated_dependency_generation_refused(self):
        with sample() as t:
            t.native_argv.append('-MD');self.reject(t)
    def test_object_generation_hidden_response_mode_refused(self):
        with sample() as t:
            rsp=t.write(t.scratch/'bad-mode.rsp','-fsyntax-only\n');t.native_argv.append('@'+str(rsp));self.reject(t)
if __name__=='__main__':unittest.main()
