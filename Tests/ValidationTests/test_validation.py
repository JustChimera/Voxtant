import json
from pathlib import Path
import sys
import tempfile
import types
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'scripts'))
import validation
from validation_metrics import aggregate, disagreement, edits, measures, tokens, review_flags


class MetricsTests(unittest.TestCase):
    def test_mixed_units_preserve_language_switches_and_repeats(self):
        self.assertEqual(tokens('Say 你好你好, don’t say 米饭!'), ['say', '你', '好', '你', '好', "don't", 'say', '米', '饭'])
        self.assertEqual(tokens('rice米饭'), ['rice', '米', '饭'])

    def test_punctuation_case_and_fullwidth_normalization(self):
        self.assertEqual(tokens('ＨＥＬＬＯ，世界!'), tokens('hello 世界'))
        self.assertNotEqual(tokens('500'), tokens('五百'))

    def test_edit_counts_and_rates_can_exceed_one(self):
        result = edits(['a', 'b'], ['a', 'c', 'd'])
        self.assertEqual(result['errors'], 2)
        self.assertEqual(result['substitutions'] + result['insertions'] + result['deletions'], 2)
        self.assertEqual(edits(['a'], ['b', 'c', 'd'])['rate'], 3)
        self.assertEqual(edits(['a', 'b'], [])['deletions'], 2)

    def test_unspaced_chinese_is_character_scored(self):
        self.assertEqual(measures('我喜欢米饭', '我喜欢面饭')['han_projection_cer']['rate'], 1 / 5)
        self.assertEqual(measures('Say 你好', 'Say 你')['mer']['rate'], 1 / 3)

    def test_corpus_aggregation_uses_micro_denominator(self):
        rows = [measures('a', 'b'), measures(' '.join(['a'] * 9), ' '.join(['a'] * 9))]
        self.assertEqual(aggregate(rows)['mer']['rate'], .1)

    def test_verified_silence_adds_insertions_without_fake_zero_score(self):
        empty = measures('', 'hello')
        self.assertIsNone(empty['mer']['rate'])
        self.assertEqual(empty['mer']['insertions'], 1)
        self.assertEqual(aggregate([empty, measures('hello', 'hello')])['mer']['rate'], 1)
        self.assertIsNone(aggregate([])['mer']['rate'])

    def test_disagreement_is_symmetric_and_not_accuracy(self):
        self.assertEqual(disagreement('a b', 'a'), disagreement('a', 'a b'))
        self.assertEqual(disagreement('', ''), 0)

    def test_runaway_repetition_is_flagged_but_legitimate_repeats_are_preserved(self):
        self.assertIn('long-character-repetition', review_flags('你' * 100, 2.8))
        self.assertNotIn('long-character-repetition', review_flags('你好你好你好', 2.8))
        self.assertEqual(tokens('你好你好'), ['你', '好', '你', '好'])

    def test_other_language_flag_does_not_exclude_it_from_mixed_score(self):
        self.assertIn('possible-other-source-language', review_flags('Привет мир', 2))
        self.assertEqual(measures('Привет мир', 'Привет')['mer']['deletions'], 1)


class CorpusTests(unittest.TestCase):
    def test_date_split_is_stable_and_excludes_previous_pilot_dates(self):
        days = ['2026-09-14', '2026-09-16', '2026-09-18', '2026-10-19']
        holdout = validation.holdout_days(days, ['2026-10-19'])
        self.assertEqual(holdout, validation.holdout_days(reversed(days), ['2026-10-19']))
        self.assertNotIn('2026-10-19', holdout)
        self.assertEqual(len(holdout), 2)
        for day in days:
            self.assertEqual(validation.choose_split(day, holdout), validation.choose_split(day, holdout))

    def test_model_candidate_never_counts_as_reviewed_reference(self):
        case = {'audioSHA256': 'abc'}
        ref = {'audioSHA256': 'abc', 'transcript': '模型猜测', 'reviewed': False}
        self.assertFalse(validation.reference_valid(ref, case))
        ref.update(reviewed=True)
        self.assertFalse(validation.reference_valid(ref, case))
        ref.update(reviewer='human')
        self.assertTrue(validation.reference_valid(ref, case))
        ref['audioSHA256'] = 'changed'
        self.assertFalse(validation.reference_valid(ref, case))

    def test_empty_reference_requires_explicit_silence(self):
        case = {'audioSHA256': 'abc'}
        ref = {'audioSHA256': 'abc', 'transcript': '', 'reviewed': True, 'reviewer': 'human'}
        self.assertFalse(validation.reference_valid(ref, case))
        ref['confirmedSilence'] = True
        self.assertTrue(validation.reference_valid(ref, case))

    def test_pending_references_do_not_produce_accuracy(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp); (root / 'references.json').write_text('{}')
            run = root / 'run'; run.mkdir()
            config = {'datasetID': 'x', 'caseIDs': ['a'], 'asrModel': 'fake', 'translationModel': 'fake'}
            validation.write(run / 'config.json', config)
            manifest = {'datasetID': 'x', 'cases': [{'id': 'a', 'audioSHA256': 'h'}]}
            ref = {'cases': {'a': {'audioSHA256': 'h', 'transcript': 'candidate', 'reviewed': False}}}
            result = validation.summarize_run(root, run, manifest, ref)
            self.assertIsNone(result['accuracy'])
            self.assertEqual(result['completedCases'], 0)

    def test_missing_prediction_is_scored_as_deletion_after_human_review(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp); (root / 'references.json').write_text('{}')
            run = root / 'run'; run.mkdir()
            validation.write(run / 'config.json', {'datasetID': 'x', 'caseIDs': ['a']})
            manifest = {'datasetID': 'x', 'cases': [{'id': 'a', 'audioSHA256': 'h'}]}
            ref = {'cases': {'a': {'audioSHA256': 'h', 'transcript': 'hello 世界', 'reviewed': True, 'reviewer': 'human'}}}
            result = validation.summarize_run(root, run, manifest, ref)
            self.assertEqual(result['accuracy']['mer']['deletions'], 3)
            self.assertEqual(result['accuracy']['mer']['rate'], 1)

    def test_sealed_holdout_rejects_before_keychain_or_network(self):
        from unittest.mock import patch
        args = types.SimpleNamespace(dataset=Path('/tmp/unused'), split='holdout', unseal_holdout=False)
        with patch.object(validation, 'validate_dataset', return_value={}):
            with self.assertRaisesRegex(ValueError, 'sealed'):
                validation.run(args)

    def test_changed_audio_is_rejected(self):
        import hashlib
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp); audio = root / 'a.m4a'; audio.write_bytes(b'original')
            identity = {'schemaVersion': 1, 'seed': 'test', 'selection': 'fixed', 'holdoutDays': [], 'excludedPilotSources': [],
                        'cases': [{'id': 'a', 'audio': 'a.m4a', 'audioSHA256': validation.sha(audio)}]}
            manifest = dict(identity, datasetID=hashlib.sha256(validation.encoded(identity)).hexdigest())
            validation.write(root / 'manifest.json', manifest)
            self.assertEqual(validation.validate_dataset(root)['datasetID'], manifest['datasetID'])
            audio.write_bytes(b'changed')
            with self.assertRaisesRegex(ValueError, 'Audio'):
                validation.validate_dataset(root)


if __name__ == '__main__': unittest.main()
