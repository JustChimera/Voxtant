from pathlib import Path
import array
import sys
import tempfile
import unittest
import wave
sys.path.insert(0,str(Path(__file__).resolve().parents[2]/'scripts'))
import candidate_validation as cv
import context_validation as context


class ContextTests(unittest.TestCase):
    def test_primary_pool_is_the_confirmed_quality_shortlist(self):
        self.assertEqual(set(cv.PRIMARY_MODELS), {'elevenlabs/scribe-v2','openai/gpt-transcribe'})
        self.assertTrue(set(cv.PRIMARY_MODELS)<=set(cv.MODELS))

    def test_windows_partition_all_samples_and_merge_tiny_tail(self):
        for seconds in [3,6]:
            frames=18*context.RATE+160
            windows=context.windows(frames,seconds)
            self.assertEqual(windows[0][0],0)
            self.assertEqual(windows[-1][1],frames)
            self.assertEqual(sum(b-a for a,b in windows),frames)
            self.assertTrue(all(b==c for (a,b),(c,d) in zip(windows,windows[1:])))
            self.assertTrue(all(b-a>=.25*context.RATE for a,b in windows))

    def test_short_audio_and_invalid_dimensions(self):
        self.assertEqual(context.windows(10,6),[(0,10)])
        for args in [(0,3),(-1,3),(10,0)]:
            with self.assertRaises(ValueError):context.windows(*args)

    def test_six_second_final_replaces_only_its_own_draft(self):
        def row(condition,unit,start,end,text):
            return dict(model='m',caseID='x',condition=condition,unitID=str(unit),start=start,end=end,status='ok',seconds=2,text=text)
        rows=[row('short3',0,0,3,'我 我'),row('short3',1,3,6,'我'),row('final6',0,0,6,'我 我 我'),
              row('short3',2,6,9,'hello'),row('final6',1,6,12,'hello again')]
        events=context.draft_final_events(rows,'m','x')
        self.assertEqual([(e['blockID'],e['kind']) for e in events],[('0','draft'),('0','final'),('1','draft'),('1','final')])
        self.assertEqual(context.assembled(rows,'final6','m','x'),'我 我 我 hello again')
        self.assertEqual(context.assembled(rows,'short3','m','x'),'我 我 我 hello')

    def test_window_normalization_caps_gain_and_keeps_original_samples(self):
        with tempfile.TemporaryDirectory() as directory:
            samples=array.array('f',[.001,-.001]*10); original=samples.tobytes(); path=Path(directory)/'test.wav'
            context.pcm_wav(samples,path)
            self.assertEqual(samples.tobytes(),original)
            with wave.open(str(path),'rb') as wav:
                self.assertEqual(wav.getframerate(),16000)
                pcm=array.array('h');pcm.frombytes(wav.readframes(wav.getnframes()))
            self.assertLessEqual(max(abs(x) for x in pcm),263)

    def test_context_policy_does_not_mutate_standard_candidate_retries(self):
        standard=cv.Remote('synthetic')
        bounded=cv.Remote('synthetic',policy=context.POLICY)
        self.assertEqual(standard.policy['maximumAttemptsPerRequest'],2)
        self.assertEqual(bounded.policy['maximumAttemptsPerRequest'],1)
        bounded.policy['maximumAttemptsPerRequest']=9
        self.assertEqual(context.POLICY['maximumAttemptsPerRequest'],1)
        self.assertEqual(standard.policy['maximumAttemptsPerRequest'],2)


if __name__=='__main__':unittest.main()
