"""Explicit OpenRouter ASR comparison; private outputs, sealed holdout, no human-gold claims."""
import argparse
import base64
import collections
import concurrent.futures
import hashlib
import json
from pathlib import Path
import re
import subprocess
import threading
import time
import urllib.error
import urllib.request

from auto_validation import family, prepare_audio, verify_reference
from validation import REPO, encoded, load, now, sha, validate_dataset, write
from validation_metrics import aggregate, is_han, measures, quantile, review_flags

MODELS = {
    'deepgram/nova-3': {'language': 'multi'},
    'elevenlabs/scribe-v2': {},
    'openai/gpt-transcribe': {},
    'openai/gpt-4o-transcribe': {},
    'microsoft/mai-transcribe-2': {},
    'openai/whisper-large-v3-turbo': {},
}
PRIMARY_MODELS = ('elevenlabs/scribe-v2', 'openai/gpt-transcribe')
PENDING_STREAMING = [
    'Speechmatics Realtime cmn_en', 'Deepgram Nova-3 Multilingual WebSocket',
    'OpenAI gpt-live-transcribe', 'ElevenLabs scribe_v2_realtime',
]
POLICY = {'attemptTimeoutSeconds': 15, 'maximumAttemptsPerRequest': 2,
          'maximumAttemptsPerInvocation': 1100, 'workers': 2, 'maximumRetryAfterSeconds': 5}


def selections(corpus, panel):
    dev = [c for c in corpus['cases'] if c['eligible'] and c['split'] == 'dev']
    if not panel or len(panel) != len(set(panel)) or not set(panel) <= {c['id'] for c in dev}:
        raise ValueError('Comparison panel must contain unique eligible dev cases; holdout remains sealed')
    return dev, [c for c in dev if c['id'] in panel]


def request_body(model, audio):
    if model not in MODELS: raise ValueError('Model outside candidate allowlist')
    return dict(model=model, input_audio={'data': base64.b64encode(audio).decode(), 'format': 'wav'},
                response_format='json', **MODELS[model])


def units(root, dev, panel):
    prepared = load(root / 'prepared.json')
    if prepared['datasetID'] != load(root / 'manifest.json')['datasetID']: raise ValueError('Prepared corpus mismatch')
    by_id = {c['id']: c for c in prepared['cases']}
    result = []
    for condition, cases in [('whole', dev), ('chunks', panel)]:
        for case in cases:
            chunks = by_id[case['id']]['chunks'] if condition == 'chunks' else [None]
            for chunk in chunks:
                audio = root / chunk['file'] if chunk else prepare_audio(root, case)
                if not audio.resolve().is_relative_to(root): raise ValueError('Audio outside dataset')
                audio_hash = sha(audio)
                if chunk and audio_hash != chunk['sha256']: raise ValueError('Prepared chunk hash mismatch')
                result.append({'condition': condition, 'caseID': case['id'], 'unitID': str(chunk['id']) if chunk else 'whole',
                               'duration': chunk['end'] - chunk['start'] if chunk else case['duration'],
                               'audio': str(audio.relative_to(root)), 'audioSHA256': audio_hash})
    return result


class Remote:
    def __init__(self, key, policy=None):
        self.key = key
        self.policy = dict(POLICY if policy is None else policy)
        self.lock = threading.Lock()
        self.disabled = set()
        self.stopped = False
        self.count = 0

    def request(self, root, out, unit, model):
        if model not in MODELS: raise ValueError('Model outside candidate allowlist')
        audio = root / unit['audio']
        if sha(audio) != unit['audioSHA256']: raise ValueError('Audio hash changed')
        body = request_body(model, audio.read_bytes())
        request_hash = hashlib.sha256(encoded(body)).hexdigest()
        path = out / 'responses' / unit['condition'] / model.replace('/', '--') / unit['caseID'] / (unit['unitID'] + '.json')
        if path.exists():
            row = load(path)
            if row['requestSHA256'] != request_hash: raise ValueError('Frozen request mismatch')
            return row
        row = dict(unit, model=model, status='skipped', text='', requestSHA256=request_hash, attempts=[], createdAt=now())
        start = time.monotonic()
        for number in range(1, self.policy['maximumAttemptsPerRequest'] + 1):
            with self.lock:
                if self.stopped or model in self.disabled or self.count >= self.policy['maximumAttemptsPerInvocation']:
                    row['error'] = 'Credential/model disabled or invocation request budget reached'
                    break
                self.count += 1
            request = urllib.request.Request('https://openrouter.ai/api/v1/audio/transcriptions', data=encoded(body),
                headers={'Authorization': 'Bearer ' + self.key, 'Content-Type': 'application/json', 'X-Title': 'Voxtant ASR Candidate Comparison'})
            tick = time.monotonic(); code = None; headers = {}; response = {}
            try:
                with urllib.request.urlopen(request, timeout=self.policy['attemptTimeoutSeconds']) as result:
                    code = result.status; headers = dict(result.headers)
                    response = json.loads(result.read().decode().replace(self.key, '[redacted]'))
            except urllib.error.HTTPError as error:
                code = error.code; headers = dict(error.headers)
                try: response = json.loads(error.read().decode().replace(self.key, '[redacted]'))
                except ValueError: response = {'error': {'message': 'Non-JSON HTTP error'}}
            except Exception as error:
                response = {'error': {'message': str(error).replace(self.key, '[redacted]')}}
            if not isinstance(response, dict): response = {'error': {'message': 'Non-object JSON response'}}
            error = response.get('error') or {}
            if not isinstance(error, dict): error = {'message': str(error)}
            try: code = int(error.get('code', code))
            except (ValueError, TypeError): pass
            row['attempts'].append({'number': number, 'status': code, 'seconds': round(time.monotonic()-tick, 3),
                'error': error, 'cost': response.get('usage', {}).get('cost'),
                'provider': response.get('provider') or error.get('metadata', {}).get('provider_name'),
                'requestID': response.get('id') or headers.get('X-Generation-Id')})
            row['status'] = 'failed'
            if code and 200 <= code < 300 and not error and isinstance(response.get('text'), str):
                row.update(status='ok', text=response['text'].strip(), response=response)
                break
            if code in [401, 402, 403, 404, 400]:
                with self.lock:
                    if code in [401, 402]: self.stopped = True
                    else: self.disabled.add(model)
                break
            try: delay = float(headers.get('Retry-After') or headers.get('retry-after') or 1)
            except (TypeError, ValueError): delay = 60
            if number == self.policy['maximumAttemptsPerRequest'] or code not in [None, 408, 429, 500, 502, 503, 504] or delay > self.policy['maximumRetryAfterSeconds']: break
            time.sleep(max(0, delay))
        row['seconds'] = round(time.monotonic() - start, 3)
        path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        write(path, row)
        return row


def score_rows(rows, case_ids, refs, model, condition):
    selected = [r for r in rows if r['model'] == model and r['condition'] == condition]
    scored = []; excluded = []; eligible = []; cases = []
    for case_id in case_ids:
        current = sorted((r for r in selected if r['caseID'] == case_id), key=lambda r: int(r['unitID']) if r['unitID'].isdigit() else -1)
        text = ' '.join(r['text'] for r in current if r['status'] == 'ok')
        ref = refs.get(case_id, {})
        if ref.get('status') == 'accepted_machine':
            if family(model) in ref['dependencyFamilies']: excluded.append(case_id)
            else:
                eligible.append(case_id); scored.append(measures(ref['text'], text))
        cases.append({'caseID': case_id, 'complete': bool(current) and all(r['status'] == 'ok' for r in current),
                      'hanCharacters': sum(is_han(c) for c in text),
                      'flags': sorted({f for r in current if r['status'] == 'ok' for f in review_flags(r['text'], r['duration'])})})
    attempts = [a for r in selected for a in r['attempts']]
    times = [r['seconds'] for r in selected if r['status'] == 'ok']
    return {'model': model, 'condition': condition, 'plannedCases': len(case_ids), 'completeCases': sum(c['complete'] for c in cases),
            'plannedRequests': len(selected), 'successfulRequests': sum(r['status'] == 'ok' for r in selected),
            'emptyRequests': sum(r['status'] == 'ok' and not r['text'].strip() for r in selected),
            'nonemptyRequests': sum(r['status'] == 'ok' and bool(r['text'].strip()) for r in selected),
            'failedRequests': sum(r['status'] == 'failed' for r in selected), 'skippedRequests': sum(r['status'] == 'skipped' for r in selected),
            'requestSeconds': {'p50': quantile(times, .5), 'p95': quantile(times, .95)},
            'attemptFailures': dict(collections.Counter(str(a['status']) for a in attempts if a['status'] != 200)),
            'reportedCost': sum(a['cost'] or 0 for a in attempts), 'unknownAttemptCosts': sum(a['cost'] is None for a in attempts),
            'silverReferenceDistance': aggregate(scored) if scored else None, 'scoredCaseIDs': eligible, 'selfReferenceExcludedCaseIDs': excluded,
            'humanVerifiedAccuracy': None, 'cases': cases}


def report(args):
    root = args.dataset.resolve(); corpus = validate_dataset(root)
    out = root / 'candidate-runs' / args.run_id; config = load(out / 'config.json')
    if config['datasetID'] != corpus['datasetID']: raise ValueError('Run/corpus mismatch')
    rows = [load(p) for p in sorted((out / 'responses').glob('*/*/*/*.json'))]
    expected = {(u['condition'], m, u['caseID'], u['unitID']) for u in config['units'] for m in config['models']}
    if {(r['condition'], r['model'], r['caseID'], r['unitID']) for r in rows} - expected: raise ValueError('Unexpected response')
    observed = {(r['condition'], r['model'], r['caseID'], r['unitID']) for r in rows}
    for u in config['units']:
        for m in config['models']:
            if (u['condition'], m, u['caseID'], u['unitID']) not in observed:
                rows.append(dict(u, model=m, status='skipped', text='', attempts=[], seconds=0))
    refs = {}
    if config.get('referenceID'):
        reference = load(out / 'reference-snapshot.json'); verify_reference(reference, corpus)
        if reference['referenceID'] != config['referenceID']: raise ValueError('Reference snapshot mismatch')
        refs = reference['cases']
    summaries = [score_rows(rows, ids, refs, model, condition) for condition, ids in config['cases'].items() for model in config['models']]
    result = {'config': config, 'models': summaries, 'humanVerifiedAccuracy': None,
              'reportSourceSHA256': sha(Path(__file__)), 'reportMetricSHA256': sha(REPO/'scripts/validation_metrics.py'),
              'limitations': ['File HTTP requests, not native streaming or microphone end-to-end latency. Python urllib transport, not production URLSession; connection reuse is not configured.',
                 'Whole clips include future context. Chunk condition uses frozen production boundaries without previous text prompts.',
                 'Machine silver is selective and not verified accuracy; model-lineage-dependent references excluded.',
                 'Scores use model-specific eligible references. Compare only identical scoredCaseIDs; no automatic winner ranking.',
                 'Han output volume is a diagnostic, not evidence of correct Chinese. Failed outputs remain penalized.',
                 'Native streaming candidates require separate credentials and are not tested by OpenRouter file requests.'],
              'pendingStreamingCandidates': PENDING_STREAMING}
    write(out / 'metrics.json', result)
    lines = ['# ASR candidate comparison', '', 'File replay only. Human-verified accuracy: unknown. Gemini excluded.', '',
             '| Condition | Model | Complete cases | Requests OK / failed / skipped | Empty OK | HTTP P50 / P95, s | Silver MER distance (cases) |',
             '|---|---|---:|---:|---:|---:|---:|']
    for s in summaries:
        timing=s['requestSeconds']; score=s['silverReferenceDistance']
        rate = f"{score['mer']['rate']:.1%} ({len(s['scoredCaseIDs'])})" if score and score['mer']['rate'] is not None else 'unknown (0)'
        fmt = lambda n: f'{n:.2f}' if n is not None else '—'
        lines.append(f"| {s['condition']} | {s['model']} | {s['completeCases']}/{s['plannedCases']} | {s['successfulRequests']} / {s['failedRequests']} / {s['skippedRequests']} | {s['emptyRequests']} | {fmt(timing['p50'])} / {fmt(timing['p95'])} | {rate} |")
    lines += ['', *('- '+note for note in result['limitations']), '', '## Pending native streaming tests', '', *('- '+m for m in PENDING_STREAMING)]
    (out / 'report.md').write_text('\n'.join(lines)+'\n')
    print('\n'.join(lines[:4] + lines[6:6+len(summaries)]), flush=True)
    return result


def run(args):
    root=args.dataset.resolve(); corpus=validate_dataset(root)
    dev, panel=selections(corpus, load(root/'comparison-plan.json')['fixedComparisonPanel'])
    selected = args.models.split(',') if args.models else (list(MODELS) if args.expanded else list(PRIMARY_MODELS))
    if not selected or len(selected) != len(set(selected)) or not set(selected) <= set(MODELS): raise ValueError('Unknown/duplicate candidate')
    out=root/'candidate-runs'/args.run_id; out.mkdir(parents=True, exist_ok=True, mode=0o700)
    reference = None
    if (root/'auto-references/latest.json').exists():
        version=load(root/'auto-references/latest.json')['version']
        reference=load(root/'auto-references'/version/'reference.json'); verify_reference(reference, corpus)
    config = {'datasetID': corpus['datasetID'], 'preparedHash': sha(root/'prepared.json'), 'models': {m: MODELS[m] for m in selected},
              'cases': {'whole': [c['id'] for c in dev], 'chunks': [c['id'] for c in panel]}, 'units': units(root, dev, panel),
              'policy': POLICY, 'sourceSHA256': sha(Path(__file__)), 'metricSHA256': sha(REPO/'scripts/validation_metrics.py'),
              'referenceID': reference['referenceID'] if reference else None, 'translation': None, 'scope': 'dev-only; file replay'}
    if (out/'config.json').exists():
        if load(out/'config.json') != config: raise ValueError('Frozen run mismatch; use a new run ID')
    else:
        write(out/'config.json', config)
        if reference: write(out/'reference-snapshot.json', reference)
        (out/'source-snapshot.py').write_bytes(Path(__file__).read_bytes())
        (out/'normalizer-snapshot.py').write_bytes((REPO/'scripts/validation_metrics.py').read_bytes())
    # Public metadata only; no audio is sent until credential access below.
    if not (out/'catalog.json').exists():
        with urllib.request.urlopen('https://openrouter.ai/api/v1/models?output_modalities=transcription',timeout=20) as response:
            catalog=json.load(response)
        write(out/'catalog.json', {'fetchedAt': now(), 'models': [m for m in catalog['data'] if m['id'] in selected]})
    available={m['id'] for m in load(out/'catalog.json')['models']}
    if not set(selected) <= available: raise ValueError('Candidate absent from current OpenRouter catalog')
    credential=subprocess.run(['/usr/bin/security','find-generic-password','-s','local.lecturetranslate.demo.openrouter','-a','api-key','-w'],stdout=subprocess.PIPE,stderr=subprocess.PIPE)
    if credential.returncode or not credential.stdout.strip(): raise ValueError('Keychain unavailable; no audio sent')
    remote=Remote(credential.stdout.decode().strip())
    jobs=[(u,m) for u in config['units'] for m in selected]
    print(f"ASR pool {args.run_id}: {len(jobs)} planned requests, {len(dev)} whole clips, {len(panel)} chunked clips, no holdout.",flush=True)
    started=time.monotonic(); counts=collections.Counter()
    with concurrent.futures.ThreadPoolExecutor(max_workers=POLICY['workers']) as executor:
        futures=[executor.submit(remote.request, root, out, u, m) for u,m in jobs]
        for index, future in enumerate(concurrent.futures.as_completed(futures),1):
            row=future.result(); counts[row['status']]+=1
            if index % 14 == 0 or index == len(jobs): print(f"{index}/{len(jobs)}: {dict(counts)}; HTTP attempts this invocation: {remote.count}",flush=True)
    write(out/'state.json',{'finishedAt':now(),'seconds':round(time.monotonic()-started,3),'requests':dict(counts),'httpAttempts':remote.count})
    report(args)


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('command',choices=['run','report']); parser.add_argument('--dataset',required=True,type=Path)
    parser.add_argument('--run-id',default='expanded-asr-v1'); parser.add_argument('--models',help='Comma-separated allowlisted models; new run ID required')
    parser.add_argument('--expanded',action='store_true',help='Use the historical seven-model pool instead of the quality shortlist')
    args=parser.parse_args()
    if args.models and args.expanded: parser.error('Choose --models or --expanded, not both')
    if not re.fullmatch(r'[A-Za-z0-9_-]+',args.run_id): parser.error('Invalid run ID')
    try: run(args) if args.command == 'run' else report(args)
    except (ValueError, OSError, subprocess.CalledProcessError) as error: parser.exit(1,'Candidate evaluation: '+str(error)+'\n')


if __name__ == '__main__': main()
