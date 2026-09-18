import ast
from pathlib import Path
import unittest
import qualify
import development_supervisor as guard

P = Path(__file__).resolve().parent

class FakeRunner:
    def __init__(self, env, failure=None):
        self.env = env
        self.failure = failure
        self.calls = []
    def run(self, label, argv, **kwargs):
        self.calls.append((label, argv, kwargs, self.env.copy()))
        if self.failure is not None: raise self.failure
        return 'original return value'

class EnvironmentScope(unittest.TestCase):
    def test_inherited_backtrace_removed_without_touching_other_values(self):
        original = {'SWIFT_BACKTRACE':'untrusted inherited setting','TMPDIR':'/owned/tmp','PATH':'/usr/bin','LATTICE_ACK_PATH_DIAGNOSTICS':'1'}
        clean = qualify.command_environment(original)
        self.assertNotIn('SWIFT_BACKTRACE', clean)
        self.assertEqual(clean, {k:v for k,v in original.items() if k != 'SWIFT_BACKTRACE'})
        self.assertIn('SWIFT_BACKTRACE', original)
    def test_absent_setting_is_also_an_independent_copy(self):
        original = {'TMP':'/owned/tmp'}
        clean = qualify.command_environment(original)
        self.assertEqual(clean, original); self.assertIsNot(clean, original)
    def test_only_three_crash_labels_receive_setting_and_original_argv(self):
        for label in ('control-signal','focused-test','full-test'):
            base={'TMPDIR':'/owned/tmp','PATH':'/usr/bin','LATTICE_ACK_PATH_DIAGNOSTICS':'1'}
            runner=FakeRunner(base); argv=['exact','argv']; marker=object()
            value=qualify.run_crash_command(runner,label,argv,backtrace='enable=yes,interactive=no,output-to=stderr',cwd='/owned',timeout=10,process_observer=marker)
            self.assertEqual(value,'original return value'); self.assertIs(runner.env,base)
            observed=runner.calls[0]
            self.assertIs(observed[1],argv);self.assertIs(observed[2]['process_observer'],marker)
            self.assertEqual(observed[3],{**base,'SWIFT_BACKTRACE':'enable=yes,interactive=no,output-to=stderr'})
            self.assertNotIn('SWIFT_BACKTRACE',base)
    def test_failure_and_interruption_restore_identical_base(self):
        for error in (ValueError('failed command'), KeyboardInterrupt()):
            base={'TMPDIR':'/owned/tmp'};runner=FakeRunner(base,error)
            with self.assertRaises(type(error)):
                qualify.run_crash_command(runner,'control-signal',['control'],backtrace='selected',timeout=10)
            self.assertIs(runner.env,base);self.assertNotIn('SWIFT_BACKTRACE',runner.env)
    def test_metadata_label_cannot_opt_into_crash_environment(self):
        runner=FakeRunner({})
        with self.assertRaisesRegex(AssertionError,'unexpected crash command'):
            qualify.run_crash_command(runner,'sdk-initial-identity',['git'],backtrace='selected')
        self.assertFalse(runner.calls)
    def test_contaminated_shared_environment_refuses_crash_launch(self):
        base={'SWIFT_BACKTRACE':'unexpected'};runner=FakeRunner(base)
        with self.assertRaisesRegex(AssertionError,'shared command environment'):
            qualify.run_crash_command(runner,'control-signal',['control'],backtrace='selected')
        self.assertIs(runner.env,base);self.assertFalse(runner.calls)
    def test_real_retained_noisy_git_identity_still_rejected(self):
        class RetainedRunner:
            def run(self,*args,**kwargs):return P/'identity-fixtures/sdk-initial-identity.log'
        with self.assertRaisesRegex(ValueError,'checkout does not match exact expected commit'):
            guard.authenticate_repository(RetainedRunner(),'sdk-initial',P,'46b5ac4760f329b25640419a07fca212770d14f5')
    def test_real_call_sites_scope_control_and_two_sdk_arms_only(self):
        tree=ast.parse((P/'qualify.py').read_text())
        calls=[n for n in ast.walk(tree) if isinstance(n,ast.Call) and isinstance(n.func,ast.Name) and n.func.id=='run_crash_command']
        self.assertEqual(len(calls),2)
        control=next(n for n in calls if isinstance(n.args[1],ast.Constant))
        self.assertEqual(control.args[1].value,'control-signal')
        self.assertEqual(next(k.value.value for k in control.keywords if k.arg=='timeout'),10)
        arm=next(n for n in calls if isinstance(n.args[1],ast.BinOp))
        self.assertEqual(ast.unparse(arm.args[1]),"arm + '-test'")
        self.assertEqual(next(k.value.value for k in arm.keywords if k.arg=='timeout'),1800)
        for call in calls:self.assertTrue(next(k.value.value for k in call.keywords if k.arg=='require_full_timeout'))
        source=(P/'qualify.py').read_text()
        self.assertIn('env = command_environment(os.environ)',source)
        self.assertNotIn("SWIFT_BACKTRACE=config['swiftBacktrace']",source)
