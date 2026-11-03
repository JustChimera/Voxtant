from pathlib import Path
import hashlib
import io
import json
import sys
import tempfile
import unittest
import urllib.error
from unittest.mock import patch
sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'scripts'))
import candidate_validation as cv


class CandidateTests(unittest.TestCase):
    def test_sealed_holdout_cannot_enter_panel(self):
        corpus={'cases':[{'id':'dev','eligible':True,'split':'dev'}, {'id':'held','eligible':True,'split':'holdout'}]}
        with self.assertRaises(ValueError): cv.selections(corpus,['held'])
        with self.assertRaises(ValueError): cv.selections(corpus,['dev','dev'])
        dev,panel=cv.selections(corpus,['dev'])
        self.assertEqual([c['id'] for c in dev],['dev'])
        self.assertEqual(dev,panel)

    def test_allowlist_checked_before_audio_access(self):
        remote=object.__new__(cv.Remote)
        with self.assertRaisesRegex(ValueError,'allowlist'):
            remote.request(Path('/missing'),Path('/missing'),{},'unknown/model')
        self.assertFalse(any('gemini' in m for m in cv.MODELS))

    def test_removed_qwen_is_rejected_before_audio_or_network_access(self):
        remote=object.__new__(cv.Remote)
        self.assertNotIn('qwen/qwen3-asr-1.7b',cv.MODELS)
        with self.assertRaisesRegex(ValueError,'allowlist'):
            remote.request(Path('/missing'),Path('/missing'),{},'qwen/qwen3-asr-1.7b')

    def test_deepgram_uses_multilingual_not_default_english(self):
        self.assertEqual(cv.request_body('deepgram/nova-3',b'audio')['language'],'multi')
        self.assertNotIn('language',cv.request_body('openai/gpt-transcribe',b'audio'))

    def test_failed_and_skipped_outputs_are_not_zero_latency_or_dropped(self):
        rows=[{'model':'qwen/qwen3-asr-1.7b','condition':'whole','caseID':'x','unitID':'whole',
               'status':'failed','text':'','attempts':[{'status':None,'cost':None}], 'seconds':30,'duration':2}]
        refs={'x':{'status':'accepted_machine','text':'hello 世界','dependencyFamilies':['whisper','scribe']}}
        score=cv.score_rows(rows,['x'],refs,'qwen/qwen3-asr-1.7b','whole')
        self.assertEqual(score['completeCases'],0)
        self.assertIsNone(score['requestSeconds']['p50'])
        self.assertEqual(score['silverReferenceDistance']['mer']['rate'],1)
        self.assertEqual(score['unknownAttemptCosts'],1)
        self.assertIsNone(score['humanVerifiedAccuracy'])

    def test_empty_success_is_separate_from_http_failure(self):
        rows=[{'model':'deepgram/nova-3','condition':'whole','caseID':'x','unitID':'whole',
               'status':'ok','text':'  ','attempts':[{'status':200,'cost':0.01}], 'seconds':2,'duration':3}]
        score=cv.score_rows(rows,['x'],{},'deepgram/nova-3','whole')
        self.assertEqual(score['successfulRequests'],1)
        self.assertEqual(score['emptyRequests'],1)
        self.assertEqual(score['nonemptyRequests'],0)
        self.assertEqual(score['failedRequests'],0)
        self.assertIsNone(score['humanVerifiedAccuracy'])

    def test_teacher_lineage_excludes_self_evaluation(self):
        refs={'x':{'status':'accepted_machine','text':'hello','dependencyFamilies':['openai-gpt','scribe','whisper']}}
        for model in ['openai/gpt-transcribe','openai/gpt-4o-transcribe','elevenlabs/scribe-v2','openai/whisper-large-v3-turbo']:
            score=cv.score_rows([],['x'],refs,model,'whole')
            self.assertEqual(score['selfReferenceExcludedCaseIDs'],['x'])
            self.assertIsNone(score['silverReferenceDistance'])

    def test_unattempted_case_remains_in_report_denominator(self):
        with tempfile.TemporaryDirectory() as folder:
            root=Path(folder); out=root/'candidate-runs'/'test'
            out.mkdir(parents=True)
            config={'datasetID':'test', 'models':{'qwen/qwen3-asr-1.7b':{}},
                    'cases':{'whole':['x']}, 'referenceID':None,
                    'units':[{'condition':'whole','caseID':'x','unitID':'whole','duration':2,'audio':'unused','audioSHA256':'x'}]}
            (out/'config.json').write_text(json.dumps(config))
            import argparse
            with patch.object(cv,'validate_dataset',return_value={'datasetID':'test'}), patch('builtins.print'):
                report=cv.report(argparse.Namespace(dataset=root,run_id='test'))
            row=report['models'][0]
            self.assertEqual(row['plannedRequests'],1)
            self.assertEqual(row['skippedRequests'],1)
            self.assertEqual(row['emptyRequests'],0)
            self.assertEqual(row['completeCases'],0)
            self.assertTrue((out/'report.md').exists())

    def test_terminal_http_failure_is_cached_redacted_and_disables_model(self):
        with tempfile.TemporaryDirectory() as folder:
            root=Path(folder); (root/'audio.wav').write_bytes(b'fake wav')
            unit={'condition':'whole','caseID':'x','unitID':'whole','duration':2,'audio':'audio.wav',
                  'audioSHA256':hashlib.sha256(b'fake wav').hexdigest()}
            error=urllib.error.HTTPError('https://example.invalid',400,'Bad request',{},
                io.BytesIO(json.dumps({'error':{'code':400,'message':'Invalid secret-test-key'}}).encode()))
            remote=cv.Remote('secret-test-key')
            with patch.object(cv.urllib.request,'urlopen',side_effect=error) as request:
                row=remote.request(root,root/'out',unit,'deepgram/nova-3')
                self.assertEqual(row['status'],'failed')
                self.assertEqual(remote.count,1)
                self.assertIn('deepgram/nova-3',remote.disabled)
                self.assertNotIn('secret-test-key',json.dumps(row))
                cached=remote.request(root,root/'out',unit,'deepgram/nova-3')
                self.assertEqual(cached,row)
                self.assertEqual(request.call_count,1)
            (root/'audio.wav').write_bytes(b'tampered')
            with self.assertRaisesRegex(ValueError,'hash changed'):
                remote.request(root,root/'out',unit,'deepgram/nova-3')


if __name__=='__main__': unittest.main()
