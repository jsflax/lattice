"""Synthetic rejection checks only; no SQLite, compiler, process or network."""
import copy, json, unittest
from summary import REQUIRED, parse, summarize
def fixture(arm='on'):
    result=[{'sqliteVersion':'fixture-version','sqliteSourceId':'fixture-source'}]
    for label,sql in [('cold',8),('warm',3)]:
        row={'sample':label,'cppScopeOnly':True,'rows':100,'sql':sql,'totalNs':1000,'instrumented':arm=='on'}
        if arm=='on':
            tags=REQUIRED.copy()
            if label=='cold':tags[3:3]=[6,7,8,9]
            row['records']=[{'tag':tag,'offsetNs':i*10,'fact':(1 if tag in [16,21]or(tag==3 and label=='warm')else 0)}for i,tag in enumerate(tags)]
        result.append(row)
    return result
def encode(value):return '\n'.join(map(json.dumps,value))+'\n'
class SummaryTests(unittest.TestCase):
    def test_valid(self):
        samples=[{'arm':arm,'data':parse(encode(fixture(arm)),arm)}for arm in ['off','on']*3]
        value=summarize(samples);self.assertEqual(value['sampleProcesses'],6)
        self.assertEqual(value['branches']['cold']['pairedOnOverOff'],[1,1,1])
        self.assertEqual(value['branches']['cold']['phaseRecords'][0]['intervalNs']['constructor'],10)
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
        bad=copy.deepcopy(good);bad[1]['data']['samples'][0]['sql']=7
        with self.assertRaises(AssertionError):summarize(bad)
if __name__=='__main__':unittest.main()
