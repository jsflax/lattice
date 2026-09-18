import copy
import unittest
import mechanism

def fixture():
    data = {'complete': True, 'manifest': {'variants': ['local','attached'], 'measuredSamples':100, 'warmupSamples':5},'samples':[]}
    sidecars={}
    for variant in ('local','attached'):
        for iteration in range(105):
            sample={'variant':variant,'iteration':iteration,'warmup':iteration<5,'readRows':100,'readChecksum':'same-values','phases':{p:{'sqlStatements':600} for p in mechanism.PHASES}}
            phases=[]
            for phase in mechanism.PHASES:
                before={k:0 for k in mechanism.NUMBERS};before.update({k:False for k in mechanism.FLAGS});before.update(read_ok=True,pool_present=True,retained_bytes=1024)
                after=copy.deepcopy(before);prepares=0 if phase==mechanism.PHASES[1] else (6 if variant=='local' else 12)
                after.update(thread_statements=600,prepares=prepares,hits=600-prepares,idle=6 if variant=='local' else 12)
                phases.append({'phase':phase,'sqlStatements':600,'actualRows':100,'actualFieldsPerRow':6,'before':before,'after':after})
            data['samples'].append(sample);sidecars[(variant,iteration)]={'schema':'lattice.swift-managed-cell-mechanism/1','variant':variant,'iteration':iteration,'warmup':iteration<5,'readChecksum':'same-values','phases':phases}
    return data,sidecars

class MechanismTests(unittest.TestCase):
    def test_accepts_exact_inventory(self):
        d,s=fixture();r=mechanism.validate(d,s);self.assertTrue(r['observedMechanismAccepted']);self.assertTrue(r['cleanExpectedSignatures']);self.assertEqual(r['scalarExecutions'],252000)
    def test_retirement_retains_nonclean_observation(self):
        d,s=fixture();s[('local',0)]['phases'][0]['after'].update(prepares=7,hits=593,retired=1)
        self.assertFalse(mechanism.validate(d,s)['cleanExpectedSignatures'])
    def test_rejects_endpoint_and_join_corruption(self):
        mutations=[('hits',593),('thread_statements',599),('active',1),('suspensions',1),('idle',17),('retained_bytes',262145),('reset_failures',1),('raw_escaped',True),('disabled',True),('pool_present',False),('read_ok',False),('closed',True),('prepares',-1),('hits',True)]
        for key,value in mutations:
            with self.subTest(key=key):
                d,s=fixture();s[('local',0)]['phases'][0]['after'][key]=value
                with self.assertRaises(ValueError):mechanism.validate(d,s)
    def test_rejects_values_fields_sql_and_inventory(self):
        for mutation in range(7):
            with self.subTest(mutation=mutation):
                d,s=fixture();row=s[('local',0)]
                if mutation==0:row['readChecksum']='wrong'
                elif mutation==1:row['phases'][0]['actualFieldsPerRow']=5
                elif mutation==2:row['phases'][0]['sqlStatements']=599
                elif mutation==3:row['phases'].reverse()
                elif mutation==4:del s[('attached',104)]
                elif mutation==5:d['complete']=False
                else:d['samples'][1]=d['samples'][0]
                with self.assertRaises(ValueError):mechanism.validate(d,s)
    def test_zero_hits_is_not_reuse(self):
        d,s=fixture();s[('local',0)]['phases'][0]['after'].update(hits=0,prepares=600)
        with self.assertRaises(ValueError):mechanism.validate(d,s)

if __name__=='__main__':unittest.main()
