"""Independent authored-script regression of the native ASR pipeline, not human speech accuracy."""
import argparse
import array
import collections
import hashlib
import json
import math
from pathlib import Path
import random
import re
import subprocess
import sys
import wave

from candidate_validation import PRIMARY_MODELS
import validation as v
from validation_metrics import NORMALIZATION, aggregate, measures, quantile, tokens

SPEC = v.REPO/'Tests/Fixtures/asr-regression-v1.json'
RATE = 16000
REFERENCE_KIND = 'synthetic_authored_source_script'
METRIC = 'synthetic-script-agreement-and-lexical-constraints-v1'


def signature():
    return hashlib.sha256(v.encoded({'script':v.sha(Path(__file__)),'metrics':v.sha(v.REPO/'scripts/validation_metrics.py')})).hexdigest()


def save_audio(path, samples):
    pcm = array.array('h',(int(max(-1,min(1,x))*32767) for x in samples))
    if sys.byteorder!='little':pcm.byteswap()
    with wave.open(str(path),'wb') as f:
        f.setnchannels(1);f.setsampwidth(2);f.setframerate(RATE);f.writeframes(pcm.tobytes())


def source_audio(source, folder, spec):
    samples=array.array('f')
    for index,(language,text) in enumerate(source['parts']):
        path=folder/f'part-{index}.aiff'
        subprocess.run(['/usr/bin/say','-v',spec['voices'][language],'-r',str(spec['wordsPerMinute']),'-o',str(path),text],check=True,stdout=subprocess.PIPE,stderr=subprocess.PIPE,timeout=45)
        raw=subprocess.run(['ffmpeg','-nostdin','-hide_banner','-loglevel','error','-i',str(path),'-ac','1','-ar',str(RATE),'-f','f32le','pipe:1'],stdout=subprocess.PIPE,stderr=subprocess.PIPE,check=True).stdout
        part=array.array('f');part.frombytes(raw)
        if sys.byteorder!='little':part.byteswap()
        if index:samples.extend([0.0]*round(spec['joinSilenceSeconds']*RATE))
        samples.extend(part)
    peak=max((abs(x) for x in samples),default=0)
    if not peak:raise ValueError('Local TTS produced silence: '+source['id'])
    return array.array('f',(x*.6/peak for x in samples))


def transformed(samples, spec):
    if spec['transform']=='quiet':return array.array('f',(x*spec['gain'] for x in samples))
    if spec['transform']!='noise':raise ValueError('Unknown fixture transformation')
    rng=random.Random(spec['seed']);rms=math.sqrt(sum(x*x for x in samples)/len(samples));noise=rms/10**(spec['snrDB']/20)
    return array.array('f',(x+rng.gauss(0,noise) for x in samples))


def validate(root):
    corpus=v.validate_dataset(root)
    if corpus.get('referenceKind')!=REFERENCE_KIND:raise ValueError('This command only accepts independent synthetic fixtures')
    if any(c['split']!='dev' or c.get('referenceKind')!=REFERENCE_KIND or c.get('humanReviewed') is not False for c in corpus['cases']):
        raise ValueError('Unexpected fixture provenance or split')
    return corpus


def build(args):
    root=args.dataset.resolve()
    if root.is_relative_to(v.REPO):raise ValueError('Generated audio must be outside Git')
    if (root/'manifest.json').exists():
        validate(root)
        if not (root/'prepared.json').exists():subprocess.run([str(v.REPO/'.build/debug/VoxtantEval'),'prepare',str(root)],check=True)
        print('Frozen regression corpus already exists; audio reused.');return
    if root.exists() and any(root.iterdir()):raise ValueError('Choose a new empty corpus directory')
    root.mkdir(parents=True,exist_ok=True,mode=0o700)
    spec=v.load(SPEC);cases=[];audio_by_id={};source_by_id={}
    def store(source,samples,tags,recipe):
        key=source['id'];folder=root/'cases'/key;folder.mkdir(parents=True,exist_ok=True,mode=0o700)
        path=folder/'sample.wav';save_audio(path,samples)
        if not samples:raise ValueError('Empty synthetic audio')
        rms=math.sqrt(sum(x*x for x in samples)/len(samples))
        cases.append({'id':key,'sourceID':'synthetic-'+key,'date':'synthetic-v1','split':'dev','eligible':True,
            'duration':len(samples)/RATE,'audio':str(path.relative_to(root)),'audioSHA256':v.sha(path),'tags':tags,
            'expectedText':source.get('expectedText',' '.join(part[1] for part in source.get('parts',[]))),
            'assertions':source['assertions'],'referenceKind':REFERENCE_KIND,'humanReviewed':False,
            'recipe':recipe,'audioRMS':rms})
    for source in spec['cases']:
        folder=root/'cases'/source['id'];folder.mkdir(parents=True,exist_ok=True,mode=0o700)
        samples=source_audio(source,folder,spec)
        audio_by_id[source['id']]=samples;source_by_id[source['id']]=source
        store(source,samples,source['tags']+['clean'],{'voices':spec['voices'],'parts':source['parts'],'rate':spec['wordsPerMinute']})
    for variant in spec['variants']:
        base=source_by_id[variant['base']];source=dict(base,id=variant['id'])
        store(source,transformed(audio_by_id[variant['base']],variant),base['tags']+variant['tags'],variant)
    for control in spec['controls']:
        rng=random.Random(control['seed']);samples=array.array('f',(rng.gauss(0,control['noiseRMS']) for _ in range(round(control['seconds']*RATE))))
        source={'id':control['id'],'expectedText':'','assertions':[{'id':'no-invented-speech','kind':'empty','any':[]}]}
        store(source,samples,control['tags'],control)
    if len({c['id'] for c in cases})!=len(cases):raise ValueError('Duplicate fixture identifiers')
    identity={'schemaVersion':1,'seed':'synthetic-authored-v1','selection':'fixed-independent-authored-scripts-and-local-tts-v1',
              'holdoutDays':[],'excludedPilotSources':[],'cases':cases}
    corpus=dict(identity,datasetID=hashlib.sha256(v.encoded(identity)).hexdigest(),createdAt=v.now(),referenceKind=REFERENCE_KIND,
                generator={'sourceSHA256':v.sha(Path(__file__)),'specSHA256':v.sha(SPEC),'macOS':subprocess.run(['sw_vers','-productVersion'],capture_output=True,text=True).stdout.strip(),
                           'ffmpeg':subprocess.run(['ffmpeg','-version'],capture_output=True,text=True).stdout.splitlines()[0]})
    v.write(root/'manifest.json',corpus);(root/'fixture-spec.json').write_bytes(SPEC.read_bytes())
    v.write(root/'references.json',{'schemaVersion':1,'datasetID':corpus['datasetID'],'normalization':NORMALIZATION,
        'cases':{c['id']:{'audioSHA256':c['audioSHA256'],'reviewed':False,'reviewer':'','transcript':'','confirmedSilence':False,'tags':[],'notes':'Authored synthetic script is not human gold.'} for c in cases}})
    subprocess.run([str(v.REPO/'.build/debug/VoxtantEval'),'prepare',str(root)],check=True)
    print(json.dumps({'datasetID':corpus['datasetID'],'cases':len(cases),'seconds':round(sum(c['duration'] for c in cases),2),'referenceKind':REFERENCE_KIND}),flush=True)


def occurrences(sequence, pattern):
    if not pattern:return 0
    return sum(sequence[i:i+len(pattern)]==pattern for i in range(len(sequence)-len(pattern)+1))


def assertions(source, hypothesis):
    sequence=tokens(hypothesis);result=[]
    for rule in source['assertions']:
        counts=[occurrences(sequence,tokens(text)) for text in rule.get('any',[])]
        kind=rule['kind']
        if kind=='contains':passed=any(count>0 for count in counts)
        elif kind=='absent':passed=all(count==0 for count in counts)
        elif kind=='count':passed=any(count==rule['count'] for count in counts)
        elif kind=='empty':passed=not sequence
        else:raise ValueError('Unknown lexical assertion')
        result.append({'id':rule['id'],'passed':passed,'observedCounts':counts})
    return result


def run_config(root, run_id):
    return v.load(root/'regression-runs'/run_id/'config.json')


def report(args):
    root=args.dataset.resolve();corpus=validate(root);cfg=run_config(root,args.run_id);out=root/'regression-runs'/args.run_id
    if cfg['datasetID']!=corpus['datasetID']:raise ValueError('Regression dataset mismatch')
    models=[];all_predictions={}
    for model,native_id in cfg['nativeRuns'].items():
        run=root/'runs'/native_id;rows=[];scores=[];slices=collections.defaultdict(list);attempts=[];times=[];failed_assertions=[]
        native=v.load(run/'config.json')
        if not native.get('asrOnly') or native['asrModel']!=model or native['datasetID']!=corpus['datasetID'] or native['caseIDs']!=cfg['caseIDs'] or native['preparedHash']!=cfg['preparedHash']:
            raise ValueError('Native replay configuration mismatch')
        for case in corpus['cases']:
            text,_,segments,complete=v.case_hypothesis(run,case['id'])
            score=measures(case['expectedText'],text);scores.append(score)
            for tag in case['tags']:slices[tag].append(score)
            checks=assertions(case,text)
            failed_assertions.extend(case['id']+':'+rule['id'] for rule in checks if not rule['passed'])
            if not complete:failed_assertions.append(case['id']+':pipeline-completion')
            current=[a for s in segments for a in s.get('attempts',[])];attempts.extend(current)
            if any(a['stage']!='asr' for a in current):raise ValueError('ASR regression unexpectedly invoked a translator')
            times.extend(s.get('asrSeconds') for s in segments if s.get('asrSeconds') is not None)
            path=run/'cases'/case['id']/'session.json';all_predictions[model+':'+case['id']]=v.sha(path) if path.exists() else None
            rows.append({'id':case['id'],'complete':complete,'expectedText':case['expectedText'],'transcript':text,'score':score,'assertions':checks,
                'emptySpeechOutput':bool(case['expectedText']) and not bool(tokens(text)),
                'unexpectedNoSpeechText':not case['expectedText'] and bool(tokens(text)),
                'eventAnnotationCandidate':not case['expectedText'] and bool(re.fullmatch(r'\s*\[[^\]]+\]\s*',text)),
                'lexicalConstraintsPassed':complete and all(r['passed'] for r in checks)})
        models.append({'model':model,'nativeRun':native_id,'plannedCases':len(rows),'completeCases':sum(r['complete'] for r in rows),
            'scriptAgreement':aggregate(scores),'lexicalPassingCases':sum(r['lexicalConstraintsPassed'] for r in rows),
            'failedAssertions':sorted(failed_assertions),'emptySpeechCases':sum(r['emptySpeechOutput'] for r in rows),
            'unexpectedNoSpeechTextCases':sum(r['unexpectedNoSpeechText'] for r in rows),'attemptFailures':dict(collections.Counter(str(a.get('status')) for a in attempts if a.get('status')!=200)),
            'asrSeconds':{'p50':quantile(times,.5),'p95':quantile(times,.95)},'reportedCost':sum(a.get('cost') or 0 for a in attempts),
            'unknownAttemptCosts':sum(a.get('cost') is None for a in attempts),'slices':{tag:aggregate(values) for tag,values in slices.items()},'cases':rows})
    common=set(cfg['caseIDs'])
    for model in models:common&={row['id'] for row in model['cases'] if row['complete']}
    for model in models:
        model['commonCompletedCaseIDs']=sorted(common)
        model['commonCompletedAgreement']=aggregate([row['score'] for row in model['cases'] if row['id'] in common]) if common else None
    result={'datasetID':corpus['datasetID'],'preparedHash':cfg['preparedHash'],'caseIDs':cfg['caseIDs'],'metric':METRIC,'scorerSHA256':signature(),
        'runID':args.run_id,'sourceHash':cfg['sourceHash'],'predictionsSHA256':hashlib.sha256(v.encoded(all_predictions)).hexdigest(),
        'referenceKind':REFERENCE_KIND,'humanVerifiedAccuracy':None,'productReadiness':'not_evaluated','models':models,
        'limitations':['Authored text is independent of evaluated models, but TTS pronunciation has not been human-verified.',
            'Spliced local English/Mandarin voices differ from a single live speaker and classroom acoustics.',
            'MER measures script agreement; number spelling and simplified/traditional differences remain surface errors.',
            'Lexical constraints check predeclared markers, not general semantic correctness.',
            'Nonempty output on noise includes event annotations; a bracketed event label is not automatically hallucinated speech. No output is filtered from scoring.',
            'Failure-inclusive rates include missing speech; no samples are removed because they are difficult.',
            'Common-completed-case scores are a conditional diagnostic, with identical IDs across models; API failures can bias this subset.',
            'No production acceptance threshold or verified live-lecture accuracy is asserted.']}
    result['reportID']=hashlib.sha256(v.encoded(result)).hexdigest()
    snapshots=out/'reports';snapshots.mkdir(exist_ok=True)
    snapshot=snapshots/(result['reportID']+'.json')
    if not snapshot.exists():v.write(snapshot,result)
    v.write(out/'metrics.json',result)
    lines=['# Независимый регрессионный набор ASR','',
        'Сравнение с заранее заданным текстом синтетической речи. Не точность на живых лекциях. Ошибки сети и пропуски включены.', '',
        '| Модель | MER по сценарию ↓ | CER иероглифов ↓ | Лексические проверки | Полностью обработано | Пустых речевых случаев |',
        '|---|---:|---:|---:|---:|---:|']
    fmt=lambda x:f'{x:.1%}' if x is not None else '—'
    for m in models:lines.append(f"| {m['model']} | {fmt(m['scriptAgreement']['mer']['rate'])} | {fmt(m['scriptAgreement']['han_projection_cer']['rate'])} | {m['lexicalPassingCases']}/{m['plannedCases']} | {m['completeCases']}/{m['plannedCases']} | {m['emptySpeechCases']} |")
    lines+=['','## Ограничения','',*('- '+s for s in result['limitations']),'','## Расшифровки и проверки','']
    for case in corpus['cases']:
        lines+=['### '+case['id'],'','Ожидаемый текст: '+case['expectedText'],'']
        for m in models:
            row=next(r for r in m['cases'] if r['id']==case['id'])
            lines += [m['model']+': '+row['transcript'], 'Нарушенные проверки: '+', '.join(r['id'] for r in row['assertions'] if not r['passed']), '']
    (out/'report.md').write_text('\n'.join(lines)+'\n')
    print('\n'.join(lines[:6+len(models)]),flush=True)
    return result


def run(args):
    root=args.dataset.resolve();corpus=validate(root);prepared=v.load(root/'prepared.json')
    if sum(len(c['chunks']) for c in prepared['cases'])*len(PRIMARY_MODELS)*3>600:raise ValueError('Synthetic replay exceeds 600-attempt worst-case budget')
    native_runs={m:args.run_id+'-'+{'elevenlabs/scribe-v2':'scribe','openai/gpt-transcribe':'gpt'}[m] for m in PRIMARY_MODELS}
    out=root/'regression-runs'/args.run_id;out.mkdir(parents=True,exist_ok=True,mode=0o700)
    cfg={'datasetID':corpus['datasetID'],'preparedHash':v.sha(root/'prepared.json'),'caseIDs':[c['id'] for c in corpus['cases']],
         'nativeRuns':native_runs,'sourceHash':v.fingerprint(),'scriptSHA256':v.sha(Path(__file__)),'metricSHA256':signature()}
    if (out/'config.json').exists() and v.load(out/'config.json')!=cfg:raise ValueError('Frozen regression run changed; use a new run ID')
    v.write(out/'config.json',cfg)
    (out/'source-snapshot.py').write_bytes(Path(__file__).read_bytes())
    (out/'metric-snapshot.py').write_bytes((v.REPO/'scripts/validation_metrics.py').read_bytes())
    for model,native_id in native_runs.items():
        print('Native ASR regression:',model,flush=True)
        native_args=argparse.Namespace(dataset=root,split='dev',unseal_holdout=False,case_ids=None,limit=None,
            asr_model=model,translation_model='unused/asr-only',run_id=native_id,asr_only=True)
        code=v.run(native_args)
        if code not in [0,2]:raise ValueError('Native runner failed to start; remaining models not sent')
    return report(args)


def verify_report(data):
    expected=hashlib.sha256(v.encoded({k:x for k,x in data.items() if k!='reportID'})).hexdigest()
    if data.get('reportID')!=expected or data.get('referenceKind')!=REFERENCE_KIND:raise ValueError('Report fingerprint/provenance mismatch')


def compare_reports(baseline,current):
    verify_report(baseline);verify_report(current)
    for key in ['datasetID','preparedHash','caseIDs','metric','scorerSHA256']:
        if baseline[key]!=current[key]:raise ValueError('Comparison is not paired: '+key)
    old={r['model']:r for r in baseline['models']};new={r['model']:r for r in current['models']}
    if set(old)!=set(new):raise ValueError('Model pool differs')
    rows=[]
    for model,a in old.items():
        b=new[model];delta=b['scriptAgreement']['mer']['rate']-a['scriptAgreement']['mer']['rate']
        added=sorted(set(b['failedAssertions'])-set(a['failedAssertions']))
        fixed=sorted(set(a['failedAssertions'])-set(b['failedAssertions']))
        worse=delta>1e-12 or bool(added) or b['completeCases']<a['completeCases']
        better=delta< -1e-12 or bool(fixed) or b['completeCases']>a['completeCases']
        rows.append({'model':model,'MERDelta':delta,'newLexicalFailures':added,'fixedLexicalFailures':fixed,
                     'signal':'regression_signal' if worse else 'improvement_signal' if better else 'unchanged'})
    return {'baselineReportID':baseline['reportID'],'currentReportID':current['reportID'],'models':rows,
        'productReadiness':'not_evaluated','note':'A paired regression signal, not a calibrated significance test or production readiness verdict. Repeat a changed API run before treating small deltas as stable.'}


def baseline_path(args):return args.dataset.resolve()/'quality-baselines'/(args.baseline+'.json')


def freeze(args):
    current=report(args);path=baseline_path(args);path.parent.mkdir(exist_ok=True)
    if path.exists():
        if v.load(path)['reportID']!=current['reportID']:raise ValueError('Baseline is immutable; choose a new baseline ID')
    else:v.write(path,current)
    print('Frozen quality baseline:',args.baseline,current['reportID'])


def compare(args):
    current=report(args);result=compare_reports(v.load(baseline_path(args)),current)
    out=args.dataset.resolve()/'quality-comparisons';out.mkdir(exist_ok=True)
    v.write(out/(args.baseline+'--'+current['reportID']+'.json'),result)
    print(json.dumps(result,ensure_ascii=False,indent=2))


def status(args):
    baseline=v.load(baseline_path(args));verify_report(baseline)
    corpus=validate(args.dataset.resolve())
    if corpus['datasetID']!=baseline['datasetID']:raise ValueError('Baseline corpus differs')
    current=v.fingerprint()
    print(json.dumps({'baseline':args.baseline,'reportID':baseline['reportID'],'datasetID':baseline['datasetID'],
        'codeStatus':'same_source_as_baseline' if current==baseline['sourceHash'] else 'new_source_requires_explicit_replay',
        'metricStatus':'same_metric' if signature()==baseline['scorerSHA256'] else 'metric_changed_requires_new_baseline',
        'humanVerifiedAccuracy':None,'productReadiness':'not_evaluated'},ensure_ascii=False,indent=2))


def main():
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('command',choices=['build','run','report','freeze','compare','status'])
    parser.add_argument('--dataset',required=True,type=Path);parser.add_argument('--run-id',default='baseline-v1');parser.add_argument('--baseline',default='v1')
    args=parser.parse_args()
    for value in [args.run_id,args.baseline]:
        if not re.fullmatch(r'[A-Za-z0-9_-]+',value):parser.error('Invalid version identifier')
    try: {'build':build,'run':run,'report':report,'freeze':freeze,'compare':compare,'status':status}[args.command](args)
    except (ValueError,OSError,subprocess.CalledProcessError,subprocess.TimeoutExpired) as error:parser.exit(1,'Quality regression: '+str(error)+'\n')


if __name__=='__main__':main()
