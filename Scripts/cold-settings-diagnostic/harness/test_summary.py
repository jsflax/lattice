"""Synthetic rejection checks only; no SQLite, compiler, process or network."""
import copy, json, unittest
from pathlib import Path
from summary import REQUIRED, COLD_CONSTRUCTOR, parse, summarize
def fixture(arm='on'):
    result=[{'sqliteVersion':'fixture-version','sqliteSourceId':'fixture-source'}]
    for label,sql in [('cold',7),('warm',3)]:
        row={'sample':label,'cppScopeOnly':True,'rows':100,'sql':sql,'totalNs':1000,'instrumented':arm=='on'}
        if arm=='on':
            tags=REQUIRED.copy()
            if label=='cold':tags[3:3]=COLD_CONSTRUCTOR
            row['records']=[{'tag':tag,'offsetNs':i*10,'fact':(1 if tag in [16,21]or(tag==3 and label=='warm')else 0)}for i,tag in enumerate(tags)]
        result.append(row)
    return result
def encode(value):return '\n'.join(map(json.dumps,value))+'\n'
class SummaryTests(unittest.TestCase):
    def test_valid(self):
        samples=[{'arm':arm,'data':parse(encode(fixture(arm)),arm)}for arm in ['off','on']*3]
        value=summarize(samples);self.assertEqual(value['sampleProcesses'],6)
        self.assertEqual(value['branches']['cold']['pairedOnOverOff'],[1,1,1])
        cold=value['branches']['cold']['phaseRecords'][0]
        self.assertEqual(cold['intervalNs']['constructor'],110)
        self.assertEqual(cold['constructorComponentsNs'],
            {'sqliteOpen':10,'busyHandling':10,'foreignKeys':10,'cacheSetting':10,'mmapSetting':10,
             'tempSetting':10,'scanstatusTail':10,'vectorRegistration':10,'remainder':30})
        self.assertEqual(cold['intervalNs']['connectionSettings'],70)
        self.assertEqual(cold['constructorShares']['remainder'],30/110)
        self.assertFalse(cold['scanstatusCallCompiled'])
        self.assertEqual(value['expectedRecords'],{'cold':27,'warm':15,'capacity':27})
        self.assertNotIn('constructorComponentsNs',value['branches']['warm']['phaseRecords'][0])
        self.assertEqual(value['branches']['warm']['sql'],3)
    def test_parse_rejections(self):
        def delete_phase(x):x[1]['records'].pop(3)
        def duplicate_phase(x):x[1]['records'][4]['tag']=6
        def reverse_time(x):x[1]['records'][5]['offsetNs']=-1
        mutations=[lambda x:x.pop(),lambda x:x.append(x[1]),lambda x:x[1].update(rows=99),
            lambda x:x[1].update(instrumented=False),lambda x:x[1].update(sql=9),
            lambda x:x[2].update(sql=8),lambda x:x[1].update(totalNs=2),
            lambda x:x[1].update(sample='warm'),delete_phase,duplicate_phase,reverse_time,
            lambda x:x[1]['records'][2].update(fact=1),
            lambda x:x[1]['records'][0].update(tag=True),
            lambda x:x[2]['records'][2].update(fact=0),
            lambda x:x[1]['records'][-1].update(fact=0),
            lambda x:x[0].update(sqliteSourceId=''),lambda x:x[1].update(extra='unknown')]
        for index,mutate in enumerate(mutations):
            with self.subTest(index=index):
                data=fixture();mutate(data)
                with self.assertRaises((AssertionError,ValueError,KeyError)):parse(encode(data),'on')
    def test_summary_rejections(self):
        good=[{'arm':arm,'data':parse(encode(fixture(arm)),arm)}for arm in ['off','on']*3]
        for bad in [good[:-1],list(reversed(good))]:
            with self.assertRaises(AssertionError):summarize(bad)
        bad=copy.deepcopy(good);bad[4]['data']['runtime']['sqliteSourceId']='other'
        with self.assertRaises(AssertionError):summarize(bad)
        bad=copy.deepcopy(good);bad[1]['data']['samples'][0]['sql']=8
        with self.assertRaises(AssertionError):summarize(bad)

    def test_constructor_boundaries_reject_missing_duplicate_reordered_and_failed(self):
        for tag in COLD_CONSTRUCTOR:
            with self.subTest(tag=tag):
                data=fixture();records=data[1]['records']
                records[:]=[record for record in records if record['tag']!=tag]
                with self.assertRaises(AssertionError):parse(encode(data),'on')
        def duplicate(data): data[1]['records'].insert(5,dict(data[1]['records'][4]))
        def reorder(data):
            data[1]['records'][5]['tag'],data[1]['records'][6]['tag']=24,23
        def wrong_branch(data): data[2]['records'].insert(3,{'tag':22,'offsetNs':25,'fact':0})
        def old_clamp(data): data[1]['records'][4]['tag']=8
        def overflow(data): data[1]['records'] += [dict(data[1]['records'][-1])]*4
        def failed_open(data): data[1]['records'][5]['fact']=14
        def failed_vector(data): next(x for x in data[1]['records'] if x['tag']==25)['fact']=1
        for mutate in [duplicate,reorder,wrong_branch,old_clamp,overflow,failed_open,failed_vector]:
            with self.subTest(mutate=mutate.__name__):
                data=fixture();mutate(data)
                with self.assertRaises(AssertionError):parse(encode(data),'on')

    def test_zero_resolution_retained_without_inventing_shares(self):
        data=fixture()
        for record in data[1]['records']:
            if record['tag'] in COLD_CONSTRUCTOR:record['offsetNs']=30
        cold=parse(encode(data),'on')['samples'][0]
        self.assertEqual(set(cold['constructorComponentsNs'].values()),{0})
        self.assertIsNone(cold['constructorShares'])

    def test_scanstatus_compilation_fact_is_explicit_and_bounded(self):
        for compiled in [0,1]:
            data=fixture();next(x for x in data[1]['records'] if x['tag']==24)['fact']=compiled
            cold=parse(encode(data),'on')['samples'][0]
            self.assertIs(cold['scanstatusCallCompiled'],bool(compiled))
            self.assertEqual(sum(cold['constructorComponentsNs'].values()),cold['intervalNs']['constructor'])
        data=fixture();next(x for x in data[1]['records'] if x['tag']==24)['fact']=2
        with self.assertRaises(AssertionError):parse(encode(data),'on')

    def test_actual_coarse_on_rejected_while_unchanged_off_remains_valid(self):
        root=Path(__file__).resolve().parent.parent/'parser-fixtures'
        off=parse((root/'coarse-001-off.log').read_text(),'off')
        self.assertEqual([x['sql'] for x in off['samples']],[7,3])
        self.assertFalse(any('records' in x for x in off['samples']))
        with self.assertRaises(AssertionError):parse((root/'coarse-002-on.log').read_text(),'on')

    def test_original_successful_unsplit_records_are_preserved_but_not_reinterpreted(self):
        root=Path(__file__).resolve().parent.parent/'parser-fixtures'
        for arm,filename in [('off','prior-001-off.log'),('on','prior-002-on.log')]:
            with self.subTest(arm=arm):
                with self.assertRaises(AssertionError):parse((root/filename).read_text(),arm)
if __name__=='__main__':unittest.main()
