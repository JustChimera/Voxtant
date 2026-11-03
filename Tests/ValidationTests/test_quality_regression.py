from pathlib import Path
import copy
import hashlib
import json
import sys
import tempfile
import unittest
sys.path.insert(0,str(Path(__file__).resolve().parents[2]/'scripts'))
import quality_regression as qr
import validation as v
from validation_metrics import measures


def fingerprint(data):
    data.pop('reportID',None)
    data['reportID']=hashlib.sha256(v.encoded(data)).hexdigest()
    return data


def sample_report():
    return fingerprint({'datasetID':'fixed-audio','preparedHash':'fixed-chunks','caseIDs':['case'],
        'metric':qr.METRIC,'scorerSHA256':'frozen-metric','referenceKind':qr.REFERENCE_KIND,
        'sourceHash':'old-code','models':[{'model':'m','scriptAgreement':measures('do not open','do not open'),
        'failedAssertions':[],'completeCases':1}]})


class QualityRegressionTests(unittest.TestCase):
    def test_authored_fixture_constraints_are_satisfiable_by_the_source_script(self):
        spec=json.loads(qr.SPEC.read_text())
        for source in spec['cases']:
            text=' '.join(part[1] for part in source['parts'])
            self.assertTrue(all(r['passed'] for r in qr.assertions(source,text)),source['id'])

    def test_negation_aliases_are_predeclared_and_scope_is_checked(self):
        source={'assertions':[{'id':'polarity','kind':'contains','any':['do not open',"don't open"]}]}
        self.assertTrue(qr.assertions(source,"Don't open the window")[0]['passed'])
        self.assertFalse(qr.assertions(source,'Do open the window')[0]['passed'])
        self.assertFalse(qr.assertions(source,'Do open the window, not the door')[0]['passed'])

    def test_lexical_checks_use_tokens_not_substrings(self):
        source={'assertions':[{'id':'not','kind':'contains','any':['not']}]}
        self.assertFalse(qr.assertions(source,'Nothing happened')[0]['passed'])

    def test_numbers_accept_written_or_digit_form_but_not_wrong_number(self):
        source={'assertions':[{'id':'number','kind':'contains','any':['twenty five','25']}]}
        for text in ['There are twenty-five students','There are 25 students']:
            self.assertTrue(qr.assertions(source,text)[0]['passed'])
        self.assertFalse(qr.assertions(source,'There are 52 students')[0]['passed'])

    def test_repetition_count_does_not_silently_deduplicate_han(self):
        source={'assertions':[{'id':'repeat','kind':'count','any':['你好'],'count':3}]}
        self.assertTrue(qr.assertions(source,'你好，你好，你好。')[0]['passed'])
        for text in ['你好你好','你好你好你好你好']:
            self.assertFalse(qr.assertions(source,text)[0]['passed'])

    def test_silence_rejects_invented_speech(self):
        source={'assertions':[{'id':'silence','kind':'empty','any':[]}]}
        self.assertTrue(qr.assertions(source,'')[0]['passed'])
        self.assertFalse(qr.assertions(source,'Thank you')[0]['passed'])

    def test_new_source_can_be_compared_but_new_audio_cannot(self):
        old=sample_report();new=copy.deepcopy(old);new['sourceHash']='new-code';fingerprint(new)
        self.assertEqual(qr.compare_reports(old,new)['models'][0]['signal'],'unchanged')
        new['datasetID']='new-audio';fingerprint(new)
        with self.assertRaisesRegex(ValueError,'not paired'):qr.compare_reports(old,new)

    def test_one_lost_negation_is_regression_even_if_other_errors_improve(self):
        old=sample_report();old['models'][0]['scriptAgreement']=measures('a b c do not open','x y z do not open');fingerprint(old)
        new=copy.deepcopy(old);new['models'][0]['scriptAgreement']=measures('a b c do not open','a b c do open')
        new['models'][0]['failedAssertions']=['case:negative-polarity'];fingerprint(new)
        result=qr.compare_reports(old,new)
        self.assertLess(result['models'][0]['MERDelta'],0)
        self.assertEqual(result['models'][0]['signal'],'regression_signal')
        self.assertEqual(result['productReadiness'],'not_evaluated')

    def test_tampered_reference_metrics_cannot_be_compared(self):
        old=sample_report();new=copy.deepcopy(old);new['models'][0]['completeCases']=0
        with self.assertRaisesRegex(ValueError,'fingerprint'):qr.compare_reports(old,new)

    def test_human_voice_corpus_is_not_accepted_as_synthetic(self):
        from unittest.mock import patch
        with patch.object(v,'validate_dataset',return_value={'cases':[]}):
            with self.assertRaisesRegex(ValueError,'synthetic'):qr.validate(Path('/irrelevant'))

    def test_silence_insertions_are_included_in_script_error_count(self):
        from validation_metrics import aggregate
        score=aggregate([measures('hello','hello'),measures('','invented words')])
        self.assertEqual(score['mer']['errors'],2)
        self.assertEqual(score['mer']['rate'],2)


if __name__=='__main__':unittest.main()
