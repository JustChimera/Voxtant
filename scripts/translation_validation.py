"""Authored-text comparison of native translation quality constraints and latency."""
import argparse
import collections
import hashlib
import json
from pathlib import Path
import re
import subprocess
import sys

import validation as v
from validation_metrics import is_han, quantile, tokens

MODELS = ['google/gemini-2.5-flash-lite','qwen/qwen3-30b-a3b-instruct-2507',
          'qwen/qwen3-next-80b-a3b-instruct','mistralai/mistral-small-3.2-24b-instruct',
          'anthropic/claude-haiku-4.5','openai/gpt-4.1-mini']
SPEC = v.REPO/'Tests/Fixtures/translation-v1.json'


def checks(case, row):
    text=row.get('text','');result=[]
    for rule in case['checks']:
        count=len(re.findall(rule['pattern'],text,re.I))
        passed=count==0 if rule.get('forbidden') else count>=rule.get('minimumCount',1)
        result.append({'id':rule['id'],'passed':passed})
    han=''.join(c for c in text if is_han(c))
    if 'preservedHan' in case:result.append({'id':'han-exact-order-and-repetitions','passed':han==case['preservedHan']})
    if case.get('forbidHan'):result.append({'id':'no-unrequested-han','passed':not han})
    if case.get('maximumWords'):result.append({'id':'fragment-not-expanded','passed':len(tokens(text))<=case['maximumWords']})
    if not case.get('localExpected') and case.get('target','ru')=='ru':result.append({'id':'target-russian','passed':bool(re.search('[А-Яа-яЁё]',text))})
    result.append({'id':'no-placeholder-leak','passed':'__ZH_' not in text})
    result.append({'id':'no-label-or-commentary','passed':not bool(re.search(r'^\s*(?:перевод|translation)\s*:',text,re.I))})
    return result


def report(args):
    out=args.output.resolve();config=v.load(out/'config.json');fixture=v.load(out/'cases.json')
    if v.sha(out/'cases.json')!=config['fixtureSHA256']:raise ValueError('Frozen translation fixture changed')
    summaries=[];details=[]
    for model in config['models']:
        rows=[]
        for case in fixture['cases']:
            for rep in range(config['repetitions']):
                path=out/'responses'/model.replace('/','--')/case['id']/(str(rep)+'.json')
                row=v.load(path) if path.exists() else {'status':'skipped','text':'','seconds':0,'attempts':[],'model':model,'caseID':case['id'],'repetition':rep}
                validation=checks(case,row);row['checks']=validation
                row['passed']=row['status']=='ok' and all(r['passed'] for r in validation)
                row['local']=case.get('localExpected',False)
                rows.append(row);details.append(row)
        remote=[r for r in rows if not r['local']];ok=[r for r in remote if r['status']=='ok']
        attempts=[a for r in remote for a in r.get('attempts',[])]
        first=[r['firstTextSeconds'] for r in ok if r.get('firstTextSeconds') is not None]
        summaries.append({'model':model,'remotePlanned':len(remote),'remoteSucceeded':len(ok),'remotePassed':sum(r['passed'] for r in remote),
            'remoteFailed':sum(r['status']=='failed' for r in remote),'remoteSkipped':sum(r['status']=='skipped' for r in remote),
            'latencySeconds':{'p50':quantile([r['seconds'] for r in ok],.5),'p95':quantile([r['seconds'] for r in ok],.95)},
            'firstVisibleTextSeconds':{'p50':quantile(first,.5),'p95':quantile(first,.95)},
            'failedChecks':dict(collections.Counter(check['id'] for r in ok for check in r['checks'] if not check['passed'])),
            'reportedCost':sum(a.get('cost') or 0 for a in attempts),'unknownAttemptCosts':sum(a.get('cost') is None for a in attempts)})
    result={'config':config,'models':summaries,'cases':details,'scorerSHA256':v.sha(Path(__file__)),
        'notes':['Controlled lexical/format constraints, not a calibrated general semantic-accuracy score.',
                 'Only independent authored text is sent; no private recording, teacher reference or ASR error is involved.',
                 'Local Chinese bypass is excluded from remote timing/pass counts. Failure and skipped counts are separate.',
                 'Sequential requests use native URLSession, rotating model order. Streaming first text is provisional.',
                 'Final correctness still requires all guard checks; first text is not a live microphone-to-translation metric.']}
    v.write(out/'metrics.json',result)
    fmt=lambda n:f'{n:.3f}' if n is not None else '—'
    lines=['# Сравнение переводчиков','',
        '| Модель | Проверки пройдены | Ошибки / пропуски | Полный ответ P50 / P95, с | Первый текст P50, с |',
        '|---|---:|---:|---:|---:|']
    for m in summaries:lines.append(f"| {m['model']} | {m['remotePassed']}/{m['remotePlanned']} | {m['remoteFailed']} / {m['remoteSkipped']} | {fmt(m['latencySeconds']['p50'])} / {fmt(m['latencySeconds']['p95'])} | {fmt(m['firstVisibleTextSeconds']['p50'])} |")
    lines+=['',*('- '+x for x in result['notes']),'','## Ответы','']
    for case in fixture['cases']:
        lines+=['### '+case['id'],'','Источник: '+case['text'],'']
        for r in details:
            if r['caseID']==case['id']:
                lines += [f"{r['model']} / {r['repetition']+1} / {r['status']}: {r['text']}",
                          'Нарушения: '+', '.join(c['id'] for c in r['checks'] if not c['passed']), '']
    (out/'report.md').write_text('\n'.join(lines)+'\n')
    print('\n'.join(lines[:4+len(summaries)]),flush=True)
    return result


def run(args):
    out=args.output.resolve()
    if out.is_relative_to(v.REPO):raise ValueError('Runtime outputs must stay outside Git')
    models=args.models.split(',') if args.models else MODELS
    if not set(models)<=set(MODELS) or len(set(models))!=len(models):raise ValueError('Unknown/duplicate translation candidate')
    spec = SPEC if args.suite == 'general' else v.REPO/'Tests/Fixtures/translation-terminology-v1.json'
    fixture=v.load(spec)
    if not all(re.fullmatch(r'[A-Za-z0-9_-]+',c['id']) for c in fixture['cases']):raise ValueError('Invalid fixture ID')
    for case in fixture['cases']:
        for rule in case['checks']:re.compile(rule['pattern'])
    out.mkdir(parents=True,exist_ok=True,mode=0o700)
    cfg={'fixtureSHA256':v.sha(spec),'models':models,'repetitions':args.repetitions,
         'streaming':args.streaming,'latencyRouting':args.latency_routing}
    provenance={'sourceHash':v.fingerprint(),'scriptSHA256':v.sha(Path(__file__)), 'runnerSHA256':v.sha(v.REPO/'.build/debug/VoxtantEval')}
    if (out/'config.json').exists():
        if v.load(out/'config.json')!=cfg or v.load(out/'provenance.json')!=provenance:raise ValueError('Frozen translator run changed; choose a new output directory')
    else:
        v.write(out/'config.json',cfg);v.write(out/'provenance.json',provenance)
        (out/'cases.json').write_bytes(spec.read_bytes());(out/'scorer-snapshot.py').write_bytes(Path(__file__).read_bytes())
    credential=subprocess.run(['/usr/bin/security','find-generic-password','-s','local.lecturetranslate.demo.openrouter','-a','api-key','-w'],stdout=subprocess.PIPE,stderr=subprocess.PIPE)
    if credential.returncode or not credential.stdout.strip():raise ValueError('Keychain unavailable; no requests sent')
    result=subprocess.run([str(v.REPO/'.build/debug/VoxtantEval'),'translation',str(out),str(out)],input=credential.stdout)
    if result.returncode:raise ValueError('Native translation runner exited '+str(result.returncode))
    return report(args)


def main():
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('command',choices=['run','report']);parser.add_argument('--output',type=Path,required=True)
    parser.add_argument('--suite',choices=['general','terminology'],default='general')
    parser.add_argument('--models');parser.add_argument('--repetitions',type=int,choices=[1,2,3],default=2)
    parser.add_argument('--streaming',action='store_true');parser.add_argument('--latency-routing',action='store_true')
    args=parser.parse_args()
    try: run(args) if args.command=='run' else report(args)
    except (OSError,ValueError) as error:parser.exit(1,'Translation evaluation: '+str(error)+'\n')


if __name__=='__main__':main()
