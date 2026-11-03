from pathlib import Path
import hashlib
import sys
import unittest
sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'scripts'))
import auto_validation as av
from validation import encoded


def candidate(model, text, **extra):
    return dict(model=model, status='ok', text=text, **extra)


class AutoReferenceTests(unittest.TestCase):
    def test_agreement_is_machine_not_human_gold(self):
        rows=[candidate(m, 'Say 你好.') for m in av.TEACHERS]
        result=av.decide(rows, 3)
        self.assertEqual(result['status'], 'accepted_machine')
        self.assertIs(result['humanReviewed'], False)
        self.assertEqual(set(result['dependencyFamilies']), {'whisper','scribe','openai-gpt'})

    def test_same_model_lineage_cannot_form_a_quorum(self):
        rows=[candidate('openai/whisper-large-v3','你好'),candidate('openai/whisper-1','你好')]
        self.assertEqual(av.decide(rows,3)['status'],'quarantined')

    def test_disagreement_needs_audio_and_external_support(self):
        rows=[candidate(av.TEACHERS[0],'hello'),candidate(av.TEACHERS[1],'世界'),candidate(av.TEACHERS[2],'good morning')]
        audit={'verdict':'supported','selectedModel':av.AUDITOR,'unresolved':False}
        self.assertEqual(av.decide(rows,3,audit)['status'],'quarantined')

    def test_unclear_audio_cannot_be_forced_into_a_reference(self):
        rows=[candidate(av.TEACHERS[0],'a b c d e f g h i'),candidate(av.TEACHERS[1],'a b c d e f g h z'),candidate(av.TEACHERS[2],'completely different')]
        audit={'verdict':'unclear','selectedModel':av.TEACHERS[0],'unresolved':True}
        self.assertEqual(av.decide(rows,3,audit)['status'],'quarantined')

    def test_auditor_cannot_invent_a_fourth_candidate(self):
        with self.assertRaises(ValueError):
            av.parse_audit('{"verdict":"supported","selected":"invented","unresolved":false}',[candidate(av.TEACHERS[0],'hello')])

    def test_runaway_and_truncated_outputs_are_not_evidence(self):
        self.assertIn('long-character-repetition',av.candidate_flags(candidate(av.AUDITOR,'你'*100),2.8))
        self.assertIn('truncated',av.candidate_flags(candidate(av.AUDITOR,'hello',finishReason='length'),2))
        self.assertIn('unclear-audio-marker',av.candidate_flags(candidate(av.TEACHERS[1],'[crowd speaking in foreign language]'),3))

    def test_ordinary_repetitions_are_kept(self):
        result=av.decide([candidate(m,'你好你好你好') for m in av.TEACHERS],3)
        self.assertEqual(result['text'],'你好你好你好')

    def test_new_unauthorized_model_rejected_before_audio_or_key_access(self):
        remote=object.__new__(av.Remote)
        with self.assertRaisesRegex(ValueError,'allowlist'):
            remote.request({},Path('/does-not-exist'),'unauthorized/model','transcribe')

    def test_frozen_reference_tampering_rejected(self):
        corpus={'datasetID':'d','cases':[{'id':'x','split':'dev','eligible':True,'audioSHA256':'a'}]}
        refs={'datasetID':'d','kind':'machine_silver','humanReviewed':False,'cases':{'x':{'audioSHA256':'a','text':'hello'}}}
        refs['referenceID']=hashlib.sha256(encoded(refs)).hexdigest()
        av.verify_reference(refs,corpus)
        refs['cases']['x']['text']='rewritten'
        with self.assertRaisesRegex(ValueError,'fingerprint'):av.verify_reference(refs,corpus)

    def test_script_variants_and_numbers_are_not_silently_repaired(self):
        self.assertEqual(av.clean_text('500 五百 [music] 你好你好'),'500 五百  你好你好')
        self.assertNotEqual(av.clean_text('現在'),av.clean_text('现在'))

    def test_reporting_change_does_not_force_new_paid_reference_run(self):
        original=Path(av.__file__).read_text()
        reporting_only=original.replace('Voxtant — автоматическая проверка','Different report title')
        self.assertEqual(av.protocol_signature(original),av.protocol_signature(reporting_only))
        changed_rule=original.replace('distance <= .08','distance <= .20')
        self.assertNotEqual(av.protocol_signature(original),av.protocol_signature(changed_rule))

    def test_audio_adjudication_requires_and_records_other_lineage(self):
        rows=[candidate(av.TEACHERS[0],'a b c d e f g h i j'),candidate(av.TEACHERS[1],'a b c d e f g h i z'),candidate(av.TEACHERS[2],'different text')]
        audit={'verdict':'supported','selectedModel':av.TEACHERS[0],'unresolved':False}
        result=av.decide(rows,3,audit)
        self.assertEqual(result['grade'],'audio_adjudicated')
        self.assertIn('scribe',result['dependencyFamilies'])
        self.assertIn('openai-gpt',result['dependencyFamilies'])
        self.assertIs(result['humanReviewed'],False)


if __name__=='__main__':unittest.main()
