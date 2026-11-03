"""Paired 3s/6s ASR experiment for the selected quality shortlist; no live latency claims."""
import argparse
import array
import collections
import concurrent.futures
import hashlib
import json
from pathlib import Path
import re
import subprocess
import sys
import time
import wave

import candidate_validation as cv
from auto_validation import verify_reference
from validation import REPO, encoded, load, now, sha, validate_dataset, write

POLICY = dict(cv.POLICY, maximumAttemptsPerRequest=1, maximumAttemptsPerInvocation=240)
RATE = 16000


def windows(frames, seconds, rate=RATE):
    if frames <= 0 or seconds <= 0 or rate <= 0: raise ValueError('Invalid audio window dimensions')
    step = round(seconds * rate)
    result = []
    start = 0
    while start < frames:
        end = min(frames, start + step)
        # Merge a sub-250ms tail instead of sending near-empty standalone requests.
        if frames - end < round(.25 * rate): end = frames
        result.append((start, end))
        start = end
    return result


def pcm_wav(samples, path):
    peak = max((abs(x) for x in samples), default=0)
    gain = min(8, .8 / peak) if peak else 1
    pcm = array.array('h', (int(max(-1, min(1, x * gain)) * 32767) for x in samples))
    if sys.byteorder != 'little': pcm.byteswap()
    with wave.open(str(path), 'wb') as audio:
        audio.setnchannels(1); audio.setsampwidth(2); audio.setframerate(RATE); audio.writeframes(pcm.tobytes())


def prepare(root, cases, out):
    result = []
    for case in cases:
        raw = subprocess.run(['ffmpeg','-nostdin','-hide_banner','-loglevel','error','-i',str(root/case['audio']),
                              '-ac','1','-ar',str(RATE),'-f','f32le','pipe:1'],stdout=subprocess.PIPE,stderr=subprocess.PIPE,check=True).stdout
        samples = array.array('f'); samples.frombytes(raw)
        if sys.byteorder != 'little': samples.byteswap()
        for condition, seconds in [('short3',3),('final6',6)]:
            folder = out/'inputs'/condition/case['id']; folder.mkdir(parents=True,exist_ok=True,mode=0o700)
            for index,(start,end) in enumerate(windows(len(samples),seconds)):
                path = folder/(str(index)+'.wav')
                pcm_wav(samples[start:end],path)
                result.append({'condition':condition,'caseID':case['id'],'unitID':str(index),'start':start/RATE,'end':end/RATE,
                               'duration':(end-start)/RATE,'audio':str(path.relative_to(root)),'audioSHA256':sha(path)})
    return result


def verify_inputs(root, config):
    for unit in config['units']:
        path = (root/unit['audio']).resolve()
        if not path.is_relative_to(root) or sha(path) != unit['audioSHA256']: raise ValueError('Frozen context audio mismatch')


def assembled(rows, condition, model, case_id):
    selected = sorted((r for r in rows if r['condition']==condition and r['model']==model and r['caseID']==case_id),key=lambda r:int(r['unitID']))
    # Final blocks partition the audio. Never trim repetitions by matching text.
    return ' '.join(r['text'] for r in selected if r['status']=='ok')


def draft_final_events(rows, model, case_id):
    events=[]
    drafts=[r for r in rows if r['model']==model and r['caseID']==case_id and r['condition']=='short3']
    finals=sorted((r for r in rows if r['model']==model and r['caseID']==case_id and r['condition']=='final6'),key=lambda r:int(r['unitID']))
    for final in finals:
        draft=next((r for r in drafts if r['start']==final['start'] and r['end']<final['end']),None)
        if draft:
            events.append({'blockID':final['unitID'],'kind':'draft','inputAvailableAt':draft['end'],
                           'status':draft['status'],'text':draft['text'],'httpSeconds':draft['seconds']})
        events.append({'blockID':final['unitID'],'kind':'final','inputAvailableAt':final['end'],
                       'status':final['status'],'text':final['text'],'httpSeconds':final['seconds']})
    return events


def report(args):
    root=args.dataset.resolve(); corpus=validate_dataset(root); out=root/'context-runs'/args.run_id
    config=load(out/'config.json')
    if config['datasetID']!=corpus['datasetID']: raise ValueError('Context corpus mismatch')
    verify_inputs(root,config)
    refs=load(out/'reference-snapshot.json'); verify_reference(refs,corpus)
    if refs['referenceID']!=config['referenceID']: raise ValueError('Context reference fingerprint mismatch')
    rows=[load(p) for p in sorted((out/'responses').glob('*/*/*/*.json'))]
    expected={(u['condition'],m,u['caseID'],u['unitID']):u for u in config['units'] for m in config['models']}
    seen=set()
    for row in rows:
        key=(row['condition'],row['model'],row['caseID'],row['unitID'])
        if key not in expected or row['audioSHA256']!=expected[key]['audioSHA256']: raise ValueError('Unexpected context response')
        seen.add(key)
    for key,unit in expected.items():
        if key not in seen: rows.append(dict(unit,model=key[1],status='skipped',text='',seconds=0,attempts=[]))
    summaries=[cv.score_rows(rows,config['caseIDs'],refs['cases'],m,c) for c in ['short3','final6'] for m in config['models']]
    outputs={m:{key:{'short3':assembled(rows,'short3',m,key),'final6':assembled(rows,'final6',m,key),
                         'draftFinalEvents':draft_final_events(rows,m,key)} for key in config['caseIDs']} for m in config['models']}
    result={'config':config,'models':summaries,'outputs':outputs,'humanVerifiedAccuracy':None,
            'reportSourceSHA256':sha(Path(__file__)),'notes':[
                'Same dev cases and decoder; independently peak-normalized windows, max gain 8x.',
                'short3 and final6 each partition the full audio. Genuine repetitions are never deduplicated.',
                'Draft/final events reuse the first 3s request of each 6s block; final replaces that block only.',
                'Events describe audio availability, not measured real-time playback or end-to-end latency. No translator invoked.',
                'Paired 3s control differs from production energy VAD. Historical production chunks are a separate condition.',
                'One attempt and 15s timeout; failure rate is not directly comparable with the older two-attempt run.',
                'Machine-reference scores are selective; teacher-dependent models are excluded. No true accuracy ranking.']}
    write(out/'metrics.json',result)
    lines=['# Контекст ASR: 3 секунды против 6 секунд','',
           'Qwen, Scribe v2, GPT Transcribe; фиксированная dev-панель. Одинаковое декодирование и нормализация. Holdout закрыт.', '',
           '| Окно | Модель | Ответов с текстом | Пустых | Ошибок | Всего | HTTP P50, с |',
           '|---|---|---:|---:|---:|---:|---:|']
    for s in summaries:
        median=s['requestSeconds']['p50']; fmt=f'{median:.2f}' if median is not None else '—'
        lines.append(f"| {s['condition']} | {s['model']} | {s['nonemptyRequests']} | {s['emptyRequests']} | {s['failedRequests']} | {s['plannedRequests']} | {fmt} |")
    lines+=['', '## Ограничения', '', *('- '+note for note in result['notes']), '', '## Расшифровки для сравнения', '']
    for key in config['caseIDs']:
        lines+=['### '+key,'']
        for model in config['models']:
            lines += ['**'+model+'**','', '3 с: '+outputs[model][key]['short3'],'', '6 с: '+outputs[model][key]['final6'],'']
    (out/'report.md').write_text('\n'.join(lines)+'\n')
    print('\n'.join(lines[:6+len(summaries)]),flush=True)
    return result


def run(args):
    root=args.dataset.resolve(); corpus=validate_dataset(root)
    _,cases=cv.selections(corpus,load(root/'comparison-plan.json')['fixedComparisonPanel'])
    out=root/'context-runs'/args.run_id; out.mkdir(parents=True,exist_ok=True,mode=0o700)
    identity={'datasetID':corpus['datasetID'],'caseIDs':[c['id'] for c in cases],'models':list(cv.PRIMARY_MODELS),
              'policy':POLICY,'sourceSHA256':sha(Path(__file__)),'remoteSourceSHA256':sha(Path(cv.__file__)),
              'metricSHA256':sha(REPO/'scripts/validation_metrics.py'),'protocol':'paired-short3-final6-v1'}
    if (out/'config.json').exists():
        config=load(out/'config.json')
        if any(config[k]!=v for k,v in identity.items()): raise ValueError('Frozen context config differs; use a new run ID')
        verify_inputs(root,config)
    else:
        version=load(root/'auto-references/latest.json')['version']; refs=load(root/'auto-references'/version/'reference.json')
        verify_reference(refs,corpus)
        config=dict(identity,units=prepare(root,cases,out),referenceID=refs['referenceID'],createdAt=now())
        write(out/'config.json',config); write(out/'reference-snapshot.json',refs)
        (out/'source-snapshot.py').write_bytes(Path(__file__).read_bytes())
        (out/'remote-snapshot.py').write_bytes(Path(cv.__file__).read_bytes())
        (out/'normalizer-snapshot.py').write_bytes((REPO/'scripts/validation_metrics.py').read_bytes())
    credential=subprocess.run(['/usr/bin/security','find-generic-password','-s','local.lecturetranslate.demo.openrouter','-a','api-key','-w'],stdout=subprocess.PIPE,stderr=subprocess.PIPE)
    if credential.returncode or not credential.stdout.strip(): raise ValueError('Keychain unavailable; no audio sent')
    remote=cv.Remote(credential.stdout.decode().strip(),policy=POLICY)
    # Interleave paired lengths and candidates, instead of running one model/condition first.
    units=sorted(config['units'],key=lambda u:(config['caseIDs'].index(u['caseID']),u['end'],u['start']))
    jobs=[(u,m) for u in units for m in config['models']]
    if len(jobs)>POLICY['maximumAttemptsPerInvocation']: raise ValueError('Context experiment exceeds bounded request budget')
    print(f"Context experiment {args.run_id}: {len(jobs)} requests, {len(cases)} fixed dev cases, one attempt per request.",flush=True)
    start=time.monotonic(); counts=collections.Counter()
    with concurrent.futures.ThreadPoolExecutor(max_workers=POLICY['workers']) as executor:
        futures=[executor.submit(remote.request,root,out,u,m) for u,m in jobs]
        for index,future in enumerate(concurrent.futures.as_completed(futures),1):
            row=future.result(); counts[row['status']]+=1
            if index%12==0 or index==len(jobs): print(f'{index}/{len(jobs)}: {dict(counts)}',flush=True)
    write(out/'state.json',{'finishedAt':now(),'seconds':round(time.monotonic()-start,3),'requests':dict(counts),'httpAttempts':remote.count})
    report(args)


def main():
    parser=argparse.ArgumentParser(description=__doc__); parser.add_argument('command',choices=['run','report'])
    parser.add_argument('--dataset',required=True,type=Path); parser.add_argument('--run-id',default='draft-final-6s-v1')
    args=parser.parse_args()
    if not re.fullmatch(r'[A-Za-z0-9_-]+',args.run_id): parser.error('Invalid run ID')
    try: run(args) if args.command=='run' else report(args)
    except (ValueError,OSError,subprocess.CalledProcessError) as error: parser.exit(1,'Context evaluation: '+str(error)+'\n')


if __name__=='__main__': main()
