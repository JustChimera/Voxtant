"""Private, reproducible Voice Memos validation corpus and local evaluation reports."""
import argparse
import collections
import hashlib
import json
from pathlib import Path
import re
import sqlite3
import subprocess
import sys
from datetime import datetime
from zoneinfo import ZoneInfo
from validation_metrics import NORMALIZATION, aggregate, disagreement, is_han, measures, quantile, review_flags

REPO = Path(__file__).resolve().parents[1]
SEED = 'voxtant-iphone-validation-v1'
SETTINGS = {'mode': 'mixed', 'source': 'en', 'target': 'ru', 'sources': [{'language': 'en', 'translate': True}, {'language': 'zh', 'translate': False}]}


def now():
    return datetime.now(ZoneInfo('Asia/Shanghai')).isoformat(timespec='seconds')


def encoded(value):
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(',', ':')).encode()


def sha(path):
    h = hashlib.sha256()
    with Path(path).open('rb') as f:
        for block in iter(lambda: f.read(1024 * 1024), b''):
            h.update(block)
    return h.hexdigest()


def write(path, data):
    path = Path(path)
    tmp = path.with_suffix(path.suffix + '.tmp')
    tmp.write_text(json.dumps(data, ensure_ascii=False, indent=2) + '\n')
    tmp.replace(path)


def load(path):
    return json.loads(Path(path).read_text())


def choose_split(day, held_out):
    return 'holdout' if day in held_out else 'dev'


def holdout_days(days, previously_seen_days=()):
    eligible = sorted(set(days) - set(previously_seen_days))
    if len(eligible) < 2:
        raise ValueError('Need at least two previously unseen date groups for holdout')
    return sorted(sorted(eligible, key=lambda day: hashlib.sha256((SEED + day).encode()).hexdigest())[:2])


def fingerprint():
    files = sorted((REPO / 'Sources/LectureCore').glob('*.swift')) + sorted((REPO / 'Sources/VoxtantEval').glob('*.swift'))
    return hashlib.sha256(encoded({str(p.relative_to(REPO)): sha(p) for p in files})).hexdigest()


def validate_dataset(root):
    manifest = load(root / 'manifest.json')
    identity = {k: manifest[k] for k in ['schemaVersion', 'seed', 'selection', 'holdoutDays', 'excludedPilotSources', 'cases']}
    if hashlib.sha256(encoded(identity)).hexdigest() != manifest['datasetID']:
        raise ValueError('Manifest fingerprint mismatch; create a new dataset version instead of editing it')
    for case in manifest['cases']:
        audio = (root / case['audio']).resolve()
        if not audio.is_relative_to(root.resolve()) or sha(audio) != case['audioSHA256']:
            raise ValueError('Audio missing/changed or outside dataset: ' + case['id'])
    return manifest


def build(args):
    root = args.dataset
    if root.resolve().is_relative_to(REPO):
        ignored = subprocess.run(['git', 'check-ignore', '-q', str(root.resolve())], cwd=REPO).returncode == 0
        if not ignored: raise ValueError('Private dataset must be outside Git or in an ignored directory')
    if root.exists() and any(root.iterdir()):
        raise ValueError('Dataset directory is not empty; use a new version')
    root.mkdir(parents=True, exist_ok=True, mode=0o700)
    store = Path.home() / 'Library/Group Containers/group.com.apple.VoiceMemos.shared/Recordings'
    db = sqlite3.connect((store / 'CloudRecordings.db').as_uri() + '?mode=ro', uri=True)
    rows = db.execute('select ZUNIQUEID,ZDATE,ZDURATION,ZPATH,ZLOCALDURATION,ZVERSIONEDAUDIOFUTURE from ZCLOUDRECORDING order by ZDATE').fetchall()
    db.close()
    pilot_assets = set()
    if args.pilot_manifest:
        pilot = load(args.pilot_manifest)
        pilot_assets = {Path(item['sourceAsset']).name for item in pilot.get('items', [])}
    sources = []
    for uid, date, duration, path, local, versioned_audio in rows:
        if not path or not (store / path).exists() or abs(duration - (local or 0)) > 0.1:
            continue
        day = datetime.fromtimestamp(date + 978307200, ZoneInfo('Asia/Shanghai')).strftime('%Y-%m-%d')
        sid = hashlib.sha256(uid.encode()).hexdigest()[:16]
        asset = versioned_audio[-36:].decode('ascii', errors='ignore') if versioned_audio else ''
        sources.append({'sourceID': sid, 'date': day, 'duration': duration, 'file': path, 'previousPilot': asset in pilot_assets})
    remaining = [s for s in sources if not s['previousPilot']]
    held_out = holdout_days((s['date'] for s in remaining), (s['date'] for s in sources if s['previousPilot']))
    cases = []
    for source in remaining:
        duration = min(18.0, source['duration'])
        digest = hashlib.sha256((SEED + source['sourceID']).encode()).digest()
        fraction = 0.15 + 0.7 * int.from_bytes(digest[:4], 'big') / (2**32 - 1)
        offset = round(max(0, source['duration'] - duration) * fraction, 3)
        case_id = 'vm-' + source['sourceID'][:10]
        folder = root / 'cases' / case_id
        folder.mkdir(parents=True, mode=0o700)
        audio = folder / 'sample.m4a'
        subprocess.run(['ffmpeg', '-nostdin', '-hide_banner', '-loglevel', 'error', '-ss', str(offset), '-i', str(store / source['file']),
                        '-t', str(duration), '-map', '0:a:0', '-c:a', 'copy', '-map_metadata', '-1', str(audio)], check=True)
        probe = json.loads(subprocess.run(['ffprobe', '-v', 'error', '-show_entries', 'format=duration', '-of', 'json', str(audio)], capture_output=True, text=True, check=True).stdout)
        actual = float(probe['format']['duration'])
        cases.append({'id': case_id, 'sourceID': source['sourceID'], 'date': source['date'], 'split': choose_split(source['date'], held_out),
                      'duration': actual, 'nominalSourceStart': offset, 'sourceDuration': source['duration'],
                      'audio': str(audio.relative_to(root)), 'audioSHA256': sha(audio), 'eligible': source['duration'] >= 1.0,
                      'tags': ['short-recording'] if source['duration'] < 18 else [], 'speakerID': None})
    identity = {'schemaVersion': 1, 'seed': SEED, 'selection': 'one-fixed-hash-selected-18s-window-per-remaining-recording; no-content-selection',
                'holdoutDays': held_out, 'excludedPilotSources': sorted(s['sourceID'] for s in sources if s['previousPilot']), 'cases': cases}
    manifest = dict(identity, datasetID=hashlib.sha256(encoded(identity)).hexdigest(), createdAt=now(),
                    notes=['Split by local recording date, not independent speaker identity.', 'Holdout must remain sealed until configuration and references are fixed.',
                           'AAC packet boundaries may differ from nominal source offsets by a frame.', 'No dataset labels are inferred from model agreement.'])
    write(root / 'manifest.json', manifest)
    write(root / 'private-sources.json', {'sources': sources})
    write(root / 'references.json', {'schemaVersion': 1, 'datasetID': manifest['datasetID'], 'normalization': NORMALIZATION,
        'cases': {c['id']: {'audioSHA256': c['audioSHA256'], 'reviewed': False, 'reviewer': '', 'transcript': '', 'confirmedSilence': False, 'tags': [], 'notes': ''} for c in cases}})
    print(json.dumps({'datasetID': manifest['datasetID'], 'cases': len(cases), 'splits': dict(collections.Counter(c['split'] for c in cases)),
                      'seconds': round(sum(c['duration'] for c in cases), 1), 'holdoutDays': held_out, 'eligible': sum(c['eligible'] for c in cases)}, ensure_ascii=False), flush=True)


def run(args):
    root = args.dataset.resolve()
    manifest = validate_dataset(root)
    if args.split == 'holdout' and not args.unseal_holdout:
        raise ValueError('Holdout sealed. Final evaluation requires --unseal-holdout after configuration is frozen.')
    selected = [c for c in manifest['cases'] if c['eligible'] and c['split'] == args.split]
    if args.case_ids:
        ids = set(args.case_ids.split(','))
        if not ids <= {c['id'] for c in selected}:
            raise ValueError('Case selection contains unknown, ineligible or wrong-split cases')
        selected = [c for c in selected if c['id'] in ids]
    if args.limit:
        # Select a stable date-diverse panel before inspecting outputs.
        groups = collections.defaultdict(list)
        for case in selected:
            groups[case['date']].append(case)
        selected = []
        while groups and len(selected) < args.limit:
            for day in sorted(list(groups)):
                selected.append(groups[day].pop(0))
                if not groups[day]: del groups[day]
                if len(selected) == args.limit: break
    if not selected:
        raise ValueError('No eligible cases selected')
    config = {'datasetID': manifest['datasetID'], 'preparedHash': sha(root / 'prepared.json'), 'sourceHash': fingerprint(),
              'asrModel': args.asr_model, 'translationModel': args.translation_model, 'split': args.split,
              'caseIDs': [c['id'] for c in selected], 'settings': SETTINGS}
    if getattr(args, 'asr_only', False): config['asrOnly'] = True
    if getattr(args, 'asr_language_hint', None): config['asrLanguageHint'] = args.asr_language_hint
    run_id = args.run_id or (datetime.now(ZoneInfo('Asia/Shanghai')).strftime('%Y%m%d-%H%M%S') + '-' + hashlib.sha256(encoded(config)).hexdigest()[:8])
    if not re.fullmatch(r'[A-Za-z0-9_-]+', run_id): raise ValueError('Invalid run ID')
    out = root / 'runs' / run_id
    out.mkdir(parents=True, exist_ok=True, mode=0o700)
    if (out / 'config.json').exists() and load(out / 'config.json') != config:
        raise ValueError('Resume rejected: config, source, selection or dataset differs')
    write(out / 'config.json', config)
    git = subprocess.run(['git', 'rev-parse', 'HEAD'], cwd=REPO, capture_output=True, text=True)
    dirty = subprocess.run(['git', 'status', '--porcelain'], cwd=REPO, capture_output=True, text=True)
    provenance = {'createdAt': now(), 'gitHead': git.stdout.strip(), 'dirty': bool(dirty.stdout.strip()),
        'sourceHash': config['sourceHash'], 'command': [x for x in sys.argv if 'key' not in x.lower()], 'python': sys.version,
        'swift': subprocess.run(['swift', '--version'], capture_output=True, text=True).stdout.strip(), 'runnerSHA256': sha(REPO / '.build/debug/VoxtantEval')}
    if not (out / 'provenance.json').exists(): write(out / 'provenance.json', provenance)
    with (out / 'launches.jsonl').open('a') as f: f.write(json.dumps(provenance, ensure_ascii=False) + '\n')
    credential = subprocess.run(['/usr/bin/security', 'find-generic-password', '-s', 'local.lecturetranslate.demo.openrouter', '-a', 'api-key', '-w'], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if credential.returncode or not credential.stdout.strip():
        raise ValueError('Keychain access unavailable; no API requests sent')
    print(f'Run {run_id}: {len(selected)} {args.split} cases, ASR={args.asr_model}, translation={args.translation_model}', flush=True)
    result = subprocess.run([str(REPO / '.build/debug/VoxtantEval'), 'run', str(root), str(out)], input=credential.stdout)
    write(out / 'exit.json', {'exitCode': result.returncode, 'finishedAt': now()})
    return result.returncode


def reference_valid(ref, case):
    return (ref.get('reviewed') is True and bool(ref.get('reviewer', '').strip()) and isinstance(ref.get('transcript'), str)
            and ref.get('audioSHA256') == case['audioSHA256'] and (bool(ref['transcript'].strip()) or ref.get('confirmedSilence') is True))


def import_references(args):
    root = args.dataset
    manifest = validate_dataset(root)
    incoming = load(args.file)
    if incoming.get('datasetID') != manifest['datasetID'] or incoming.get('normalization') != NORMALIZATION:
        raise ValueError('Reference dataset or normalization mismatch')
    current = load(root / 'references.json')
    case_by_id = {c['id']: c for c in manifest['cases']}
    for key, ref in incoming['cases'].items():
        if key not in case_by_id or ref.get('audioSHA256') != case_by_id[key]['audioSHA256']:
            raise ValueError('Unknown case or reference/audio mismatch: ' + key)
        if ref.get('reviewed') and not reference_valid(ref, case_by_id[key]):
            raise ValueError('Reviewed reference requires reviewer, transcript or explicit silence: ' + key)
    backup = root / ('references-before-' + datetime.now().strftime('%Y%m%d%H%M%S%f') + '.json')
    write(backup, current)
    current['cases'].update(incoming['cases'])
    current['updatedAt'] = now()
    write(root / 'references.json', current)
    print('Imported reviewed references:', sum(reference_valid(current['cases'].get(c['id'], {}), c) for c in manifest['cases']))


def case_hypothesis(run, case_id):
    path = run / 'cases' / case_id / 'session.json'
    if not path.exists(): return '', '', [], False
    segments = load(path)['segments']
    return (' '.join(s['transcript'] for s in segments), ' '.join(s['translation'] for s in segments), segments,
            all(s['status'] == 'complete' for s in segments))


def summarize_run(root, run, manifest, references):
    config = load(run / 'config.json')
    cases = {c['id']: c for c in manifest['cases']}
    if config['datasetID'] != manifest['datasetID']: raise ValueError('Run belongs to a different dataset')
    rows, scored, attempts, segments = [], [], [], []
    slices = collections.defaultdict(list)
    for key in config['caseIDs']:
        hyp, translation, current, complete = case_hypothesis(run, key)
        segments.extend(current); attempts.extend(a for s in current for a in s.get('attempts', []))
        ref = references['cases'].get(key, {})
        gold = reference_valid(ref, cases[key])
        score = measures(ref['transcript'], hyp) if gold else None
        if score:
            scored.append(score)
            for tag in ref.get('tags', []): slices[tag].append(score)
        rows.append({'id': key, 'complete': complete, 'reviewed': gold, 'score': score,
                     'reviewFlags': sorted({flag for s in current for flag in review_flags(s['transcript'], s['end'] - s['start'])}),
                     'emptyHypothesis': not bool(hyp.strip()), 'residualLatinInTranslation': bool(re.search(r'[A-Za-z]{3}', translation))})
    asr = [s.get('asrSeconds') for s in segments]
    translations = [s['translationSeconds'] for s in segments if s.get('translationSeconds', 0) > 0]
    han_segments = [s for s in segments if any(is_han(c) for c in s['transcript'])]
    preserved = sum(s['status'] == 'complete' and [c for c in s['transcript'] if is_han(c)] == [c for c in s['translation'] if is_han(c)] for s in han_segments)
    return {'run': run.name, 'config': config, 'plannedCases': len(rows), 'completedCases': sum(r['complete'] for r in rows),
            'predictionsSHA256': hashlib.sha256(encoded({key: sha(run / 'cases' / key / 'session.json') if (run / 'cases' / key / 'session.json').exists() else None for key in config['caseIDs']})).hexdigest(),
            'chunks': len(segments), 'completedChunks': sum(s['status'] == 'complete' for s in segments),
            'reviewedCases': len(scored), 'referenceSHA256': sha(root / 'references.json'), 'normalization': NORMALIZATION,
            'scorerSHA256': hashlib.sha256(encoded({'cli': sha(Path(__file__)), 'metrics': sha(REPO / 'scripts/validation_metrics.py')})).hexdigest(),
            'accuracy': aggregate(scored) if scored else None, 'slices': {tag: {'cases': len(items), 'accuracy': aggregate(items)} for tag, items in slices.items()}, 'asrSeconds': {'p50': quantile(asr, .5), 'p95': quantile(asr, .95)},
            'translationSeconds': {'p50': quantile(translations, .5), 'p95': quantile(translations, .95)},
            'timingPopulation': 'Successful stage results only; failures and unfinished cases are reported separately, never counted as zero latency.',
            'hanSegments': len(han_segments), 'hanPreserved': preserved,
            'attemptFailures': dict(collections.Counter(f"{a['stage']}:{a.get('status', 'network')}" for a in attempts if a.get('status') != 200)),
            'reportedCost': sum(a.get('cost') or 0 for a in attempts), 'unknownAttemptCosts': sum(a.get('cost') is None for a in attempts),
            'reviewSignalCounts': dict(collections.Counter(flag for row in rows for flag in row['reviewFlags'])),
            'cases': rows, 'note': 'Unreviewed hypotheses are not references. Han preservation is not ASR accuracy. Batch service times are not live latency.'}


def review_html(root, manifest, references, runs, comparisons):
    cases = []
    for case in manifest['cases']:
        if case['split'] != 'dev' or not case['eligible']: continue
        predictions = []
        for run in runs:
            config = load(run / 'config.json')
            if case['id'] not in config['caseIDs']: continue
            hyp, translation, _, complete = case_hypothesis(run, case['id'])
            predictions.append({'run': run.name, 'asrModel': config['asrModel'], 'transcript': hyp, 'translation': translation, 'complete': complete, 'reviewFlags': sorted({flag for s in case_hypothesis(run, case['id'])[2] for flag in review_flags(s['transcript'], s['end']-s['start'])})})
        cases.append(dict(case, reference=references['cases'].get(case['id'], {}), predictions=predictions,
                          disagreement=comparisons.get(case['id'])))
    cases.sort(key=lambda c: (-(c['disagreement'] or 0), c['id']))
    data = json.dumps({'datasetID': manifest['datasetID'], 'normalization': NORMALIZATION, 'cases': cases}, ensure_ascii=False).replace('<', '\\u003c')
    template = (REPO / 'scripts/validation-review.html').read_text()
    (root / 'review.html').write_text(template.replace('/*DATA*/', data))


def report(args):
    root = args.dataset
    manifest = validate_dataset(root)
    references = load(root / 'references.json')
    if references['datasetID'] != manifest['datasetID']: raise ValueError('References belong to another dataset')
    runs = sorted(p.parent for p in (root / 'runs').glob('*/config.json')) if (root / 'runs').exists() else []
    summaries = []
    for run in runs:
        config = load(run / 'config.json')
        if config['split'] == 'holdout' and not args.unseal_holdout: continue
        summary = summarize_run(root, run, manifest, references)
        write(run / 'metrics.json', summary)
        score_dir = run / 'scores'
        score_dir.mkdir(exist_ok=True)
        score_id = summary['predictionsSHA256'][:16] + '-' + summary['referenceSHA256'][:16] + '-' + summary['scorerSHA256'][:16]
        write(score_dir / (score_id + '.json'), summary)
        write(score_dir / (score_id + '-references.json'), {'datasetID': manifest['datasetID'], 'normalization': NORMALIZATION,
              'cases': {key: references['cases'].get(key, {}) for key in config['caseIDs']}})
        summaries.append(summary)
    dev_runs = [r for r in runs if load(r / 'config.json')['split'] == 'dev']
    comparisons = {}
    for case in manifest['cases']:
        if case['split'] != 'dev': continue
        outputs = [(r, case_hypothesis(r, case['id'])) for r in dev_runs if case['id'] in load(r / 'config.json')['caseIDs']]
        if len(outputs) > 1:
            pairs = [(a, b) for i, a in enumerate(outputs) for b in outputs[i + 1:] if load(a[0] / 'config.json')['asrModel'] != load(b[0] / 'config.json')['asrModel'] and a[1][3] and b[1][3]]
            if pairs: comparisons[case['id']] = max(disagreement(a[1][0], b[1][0]) for a, b in pairs)
    coverage_by_model = collections.defaultdict(set)
    for summary in summaries:
        if summary['config']['split'] == 'dev':
            coverage_by_model[summary['config']['asrModel']].update(row['id'] for row in summary['cases'] if row['complete'])
    coverage_union = set().union(*coverage_by_model.values()) if coverage_by_model else set()
    plan = load(root / 'comparison-plan.json') if (root / 'comparison-plan.json').exists() else {}
    fixed_panel = set(plan.get('fixedComparisonPanel', []))
    paired = []
    for i, a in enumerate(summaries):
        for b in summaries[i + 1:]:
            if a['config']['split'] != b['config']['split']: continue
            common_set = set(a['config']['caseIDs']) & set(b['config']['caseIDs'])
            if fixed_panel and a['config']['asrModel'] != b['config']['asrModel']: common_set &= fixed_panel
            common = sorted(common_set)
            cases_by_id = {c['id']: c for c in manifest['cases']}
            reviewed = [key for key in common if reference_valid(references['cases'].get(key, {}), cases_by_id[key])]
            pair_scores = []
            for summary in [a, b]:
                measurements = [measures(references['cases'][key]['transcript'], case_hypothesis(root / 'runs' / summary['run'], key)[0]) for key in reviewed]
                pair_scores.append(aggregate(measurements) if measurements else None)
            paired.append({'a': a['run'], 'b': b['run'], 'commonCases': len(common), 'reviewedCases': len(reviewed), 'scores': pair_scores,
                           'selection': 'fixed comparison panel for cross-model scores' if fixed_panel and a['config']['asrModel'] != b['config']['asrModel'] else 'common cases',
                           'note': 'Only identical reviewed case IDs are compared; adaptive failure-recovery cases are not a random accuracy sample.'})
    review_html(root, manifest, references, dev_runs, comparisons)
    leaderboard = {'datasetID': manifest['datasetID'], 'generatedAt': now(), 'normalization': NORMALIZATION,
                   'humanReviewed': sum(reference_valid(references['cases'].get(c['id'], {}), c) for c in manifest['cases']),
                   'holdoutSealed': not args.unseal_holdout,
                   'devCoverage': {'eligibleCases': sum(c['split']=='dev' and c['eligible'] for c in manifest['cases']), 'completedUnion': len(coverage_union), 'completedByASR': {model: len(ids) for model, ids in coverage_by_model.items()}},
                   'runs': summaries, 'pairedComparisons': paired, 'asrDisagreementNotAccuracy': comparisons}
    pointer = root / 'auto-references/latest.json'
    if pointer.exists():
        latest = load(pointer)
        if not re.fullmatch(r'[A-Za-z0-9_-]+', latest.get('version', '')): raise ValueError('Invalid automatic reference pointer')
        subprocess.run([sys.executable, str(REPO / 'scripts/auto_validation.py'), 'report', '--dataset', str(root), '--version', latest['version']], capture_output=True, text=True, check=True)
        leaderboard['machineProxy'] = load(root / 'auto-references' / latest['version'] / 'metrics.json')
    write(root / 'leaderboard.json', leaderboard)
    lines = ['Voxtant — валидационный набор', 'Создано: ' + now(), '',
             f"Отрывки: {len(manifest['cases'])}; длительность: {sum(c['duration'] for c in manifest['cases']):.1f} с.",
             'Разделение по дням: ' + json.dumps(collections.Counter(c['split'] for c in manifest['cases'])),
             f"Подтверждённых человеком эталонов: {leaderboard['humanReviewed']}.",
             f"Уникальных рабочих отрывков с завершённым результатом хотя бы одной модели: {leaderboard['devCoverage']['completedUnion']}/{leaderboard['devCoverage']['eligibleCases']}.",
             'Полное покрытие по ASR: ' + str(leaderboard['devCoverage']['completedByASR']),
             'Отложенная часть: ' + ('закрыта' if leaderboard['holdoutSealed'] else 'открыта явно'), '',
             'MER/WER/CER считаются только по подтверждённым эталонам. Пока эталонов нет, точность неизвестна.',
             'WER английской проекции и CER Han-проекции — диагностика, основной показатель смешанного текста MER.',
             'Нормализация: ' + NORMALIZATION,
             'Задержки — время успешных ответов сервисов в пакетном прогоне, а не микрофонная live-задержка. Таймауты отражаются отдельно и не считаются быстрыми ответами.',
             'Сохранение Han проверяет перевод относительно ASR и не доказывает верность ASR.', '']
    for summary in summaries:
        lines += [f"Прогон {summary['run']}: ASR {summary['config']['asrModel']}, перевод {summary['config']['translationModel']}",
                  f"Готово {summary['completedCases']}/{summary['plannedCases']} отрывков, {summary['completedChunks']}/{summary['chunks']} фрагментов; эталонов {summary['reviewedCases']}.",
                  'ASR P50/P95: ' + str(summary['asrSeconds']), 'Перевод P50/P95: ' + str(summary['translationSeconds']),
                  f"Han сохранены: {summary['hanPreserved']}/{summary['hanSegments']}; сбои попыток: {summary['attemptFailures']}.",
                  'Сигналы для проверки (не измеренная точность): ' + str(summary['reviewSignalCounts']),
                  'Оценка точности: ' + (json.dumps(summary['accuracy'], ensure_ascii=False) if summary['accuracy'] else 'ожидает ручных эталонов'), '']
    if comparisons:
        lines += ['Очередь спорных мест (расхождение моделей, НЕ ошибка ASR):']
        lines += [f'{key}: {value:.1%}' for key, value in sorted(comparisons.items(), key=lambda item: item[1], reverse=True)]
    if 'machineProxy' in leaderboard:
        proxy = leaderboard['machineProxy']
        lines += ['', 'Автоматическая проверка активна.',
                  f"Машинных ориентиров: {proxy['acceptedMachineCases']}/{proxy['totalDevCases']}; спорных: {proxy['quarantinedCases']}.",
                  'Модельные ориентиры и аудиоарбитр работают без обязательной ручной разметки.',
                  'Сравнение с машинным ориентиром — отдельный proxy, не подтверждённая абсолютная точность ASR.',
                  'Автоматический отчёт: auto-references/' + latest['version'] + '/report.txt']
        for model in proxy['models']:
            distance = model['silverReferenceDistance']
            rate = distance['mer']['rate'] if distance else None
            lines += [model['config']['asrModel'] + ': proxy MER distance ' + (f'{rate:.1%}' if rate is not None else 'не определено') + f" на {model['scoredCases']} общих отрывках."]
    else:
        lines += ['', 'Автоматическая проверка: make eval-auto DATASET=<dataset>. Ручная разметка необязательна.',
                  'Машинные ориентиры сохраняются отдельно от человеческих эталонов. До первого автопрогона proxy-оценка отсутствует.']
    lines += ['', 'Человеческие эталоны остаются дополнительной независимой проверкой, если когда-либо появятся.',
              'Не меняйте отложенную выборку при настройке. Группировка по дню не гарантирует разных говорящих.']
    (root / 'report.txt').write_text('\n'.join(lines) + '\n')
    print(json.dumps({'runs': len(summaries), 'humanReviewed': leaderboard['humanReviewed'], 'comparisonCases': len(comparisons), 'report': str(root / 'report.txt')}, ensure_ascii=False))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    subs = parser.add_subparsers(dest='command', required=True)
    for command in ['build', 'run', 'report', 'import-references']:
        p = subs.add_parser(command)
        p.add_argument('--dataset', type=Path, required=True)
        if command == 'build': p.add_argument('--pilot-manifest', type=Path)
        if command == 'run':
            p.add_argument('--asr-model', default='elevenlabs/scribe-v2')
            p.add_argument('--asr-language-hint', choices=['en','zh','ru','de','fr','es','it','pt','ja','ko'])
            p.add_argument('--asr-only', action='store_true', help='Native ASR-only replay, continuing after clip failures')
            p.add_argument('--translation-model', default='openai/gpt-4.1-mini')
            p.add_argument('--split', choices=['dev', 'holdout'], default='dev')
            p.add_argument('--limit', type=int)
            p.add_argument('--case-ids')
            p.add_argument('--run-id')
        if command in ['run', 'report']: p.add_argument('--unseal-holdout', action='store_true')
        if command == 'import-references': p.add_argument('--file', type=Path, required=True)
    args = parser.parse_args()
    try:
        result = {'build': build, 'run': run, 'report': report, 'import-references': import_references}[args.command](args)
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        parser.exit(1, 'Validation: ' + str(error) + '\n')
    return result or 0


if __name__ == '__main__':
    sys.exit(main())
