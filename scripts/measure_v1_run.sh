#!/usr/bin/env bash
set -euo pipefail

id="" audio="" resume="" root="" output="" low_heat=0 keep_session=0
while (($#)); do
  case "$1" in
    --id|--audio|--resume-session|--sessions-root|--output)
      (($# >= 2)) || { echo "missing value for $1" >&2; exit 2; }
      case "$1" in
        --id) id="$2" ;;
        --audio) audio="$2" ;;
        --resume-session) resume="$2" ;;
        --sessions-root) root="$2" ;;
        --output) output="$2" ;;
      esac
      shift 2 ;;
    --low-heat) low_heat=1; shift ;;
    --keep-session) keep_session=1; shift ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

[[ -n "$id" && -n "$output" ]] || { echo "--id and --output required" >&2; exit 2; }
[[ "$id" =~ ^[a-zA-Z0-9_-]+$ ]] || { echo "invalid id" >&2; exit 2; }
if [[ -n "$resume" ]]; then
  [[ -z "$audio" && -n "$root" ]] || { echo "resume requires --sessions-root and no --audio" >&2; exit 2; }
else
  [[ -n "$audio" && -n "$root" && "$keep_session" == 1 ]] || { echo "import requires --audio, --sessions-root, and --keep-session" >&2; exit 2; }
fi

repo="$(cd "$(dirname "$0")/.." && pwd)"
available_bytes="$(python3 -c 'import shutil,sys;print(shutil.disk_usage(sys.argv[1]).free)' "$repo")"
if (( available_bytes < 4 * 1024 * 1024 * 1024 )); then
  echo "at least 4 GiB of free disk space is required for a measured run" >&2
  exit 1
fi
bin_dir="$(swift build --package-path "$repo/app/MacAmbientJev" -c release --show-bin-path)"
bin="$bin_dir/MacAmbientJevProcessRecording"
[[ -x "$bin" ]] || { echo "build the release CLI before measuring" >&2; exit 2; }
run_id="${id}-$(date -u +%Y%m%dT%H%M%SZ)"
output="$(python3 -c 'import os,sys;print(os.path.abspath(sys.argv[1]))' "$output")"
run_dir="$(dirname "$output")/$run_id"
mkdir "$run_dir"
tar -czf "$run_dir/source-snapshot.tar.gz" -C "$repo" \
  app/MacAmbientJev/Sources app/MacAmbientJev/Package.swift \
  app/MacAmbientJev/Package.resolved scripts/measure_v1_run.sh

args=(--run-id "$run_id" --metrics-output "$run_dir/engine-metrics.json" --thermal-output "$run_dir/thermal.jsonl" --memory-output "$run_dir/memory.jsonl")
if [[ -n "$resume" ]]; then
  args+=(--resume-session "$resume" --sessions-root "$root")
else
  args+=(--sessions-root "$root" --keep-session "$audio")
fi
if (( low_heat )); then args+=(--low-heat); fi
args+=("$output")

started="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
set +e
/usr/bin/time -l "$bin" "${args[@]}" > "$run_dir/stdout.log" 2> "$run_dir/stderr.log"
exit_code=$?
set -e
finished="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

python3 - "$repo" "$run_dir" "$id" "$run_id" "$audio" "$resume" "$root" "$output" "$started" "$finished" "$exit_code" "$available_bytes" "${args[@]}" <<'PY'
import datetime, hashlib, json, pathlib, platform, re, statistics, subprocess, sys, shutil, unicodedata, uuid
repo, folder, recording, run, audio, resume, root, output, started, finished, exit_code, disk_before, *args = sys.argv[1:]
folder = pathlib.Path(folder)
def command(*argv):
    return subprocess.check_output(argv, cwd=repo).decode().strip()
def digest(path):
    h = hashlib.sha256()
    with open(path, 'rb') as f:
        for block in iter(lambda: f.read(1024 * 1024), b''): h.update(block)
    return h.hexdigest()
def fail(message):
    print(f'{message} (CLI exit code {exit_code}, log {folder / "stderr.log"})', file=sys.stderr)
    sys.exit(1)
def read_json(path):
    try: return json.loads(path.read_text())
    except (OSError, ValueError) as error: fail(f'{path.name} is unreadable: {error}')
def read_jsonl(path):
    try: return [json.loads(line) for line in path.read_text().splitlines()]
    except (OSError, ValueError) as error: fail(f'{path.name} is unreadable: {error}')
reason = {}
metric = read_json(folder / 'engine-metrics.json')
if metric.get('runID') != run: fail('engine-metrics.json run ID mismatch')
status = metric.get('disposition')
if status not in ('completed', 'failed', 'paused'): fail(f'engine-metrics.json has no valid disposition: {status!r}')
asr_keys = ('modelLoadSeconds', 'asrCallSeconds', 'processedAudioSeconds', 'pacingWaitSeconds',
            'pacingWaitCount', 'initialPendingCount', 'maximumPendingCount', 'oldestPendingAgeSeconds')
if 'asr' in metric:
    asr = metric['asr']
    missing = [k for k in asr_keys if not isinstance(asr.get(k), (int, float))]
    if missing: fail(f'engine-metrics.json asr lacks {", ".join(missing)}')
else:
    asr = None
    reason['asr'] = f'the engine measured no ASR batch in this {status} invocation'
time_output = (folder / 'stderr.log').read_text(errors='replace')
def value(pattern):
    match = re.search(pattern, time_output)
    return int(match.group(1)) if match else None
peak = value(r'(\d+)\s+peak memory footprint')
rss = value(r'(\d+)\s+maximum resident set size')
if peak is None: reason['peak_memory_mb'] = 'not reported by /usr/bin/time -l'
def asr_value(key):
    return asr[key] if asr is not None else None
rtf = asr['asrCallSeconds'] / asr['processedAudioSeconds'] if asr is not None and asr['processedAudioSeconds'] > 0 else None
if asr is not None and rtf is None: reason['asr_rtf'] = 'no ASR audio was processed in this invocation'
samples = read_jsonl(folder / 'memory.jsonl')
thermal_samples = read_jsonl(folder / 'thermal.jsonl')
if not samples: fail('memory.jsonl has no samples')
if not thermal_samples: fail('thermal.jsonl has no samples')
if any(s.get('run_id') != run for s in samples): fail('memory.jsonl run ID mismatch')
if any(s.get('run_id') != run for s in thermal_samples): fail('thermal.jsonl run ID mismatch')
footprint_errors = sorted({s['footprint_error'] for s in samples if 'footprint_error' in s})
if footprint_errors: reason['footprint_bytes'] = '; '.join(footprint_errors)
asr_samples = [s['footprint_bytes'] for s in samples if s.get('phase') == 'asr' and isinstance(s.get('footprint_bytes'), int)]
asr_timed = [(datetime.datetime.fromisoformat(s['timestamp'].replace('Z', '+00:00')), s['footprint_bytes']) for s in samples if s.get('phase') == 'asr' and isinstance(s.get('footprint_bytes'), int)]
growth = None
memory_verdict = 'INCONCLUSIVE'
if len(asr_timed) >= 96 and (asr_timed[-1][0] - asr_timed[0][0]).total_seconds() >= 600:
    first_end = asr_timed[0][0] + datetime.timedelta(minutes=5)
    last_start = asr_timed[-1][0] - datetime.timedelta(minutes=5)
    first = [v for t, v in asr_timed if t < first_end]
    last = [v for t, v in asr_timed if t > last_start]
    if len(first) >= 48 and len(last) >= 48 and first_end <= last_start:
        growth = (statistics.median(last) - statistics.median(first)) / (1024 * 1024)
        if int(exit_code) == 0 and peak is not None:
            memory_verdict = 'VERIFIED' if growth <= 512 and peak <= 12 * 1024**3 else 'FAILED'
if growth is None: reason['memory_growth_mb'] = 'two nonoverlapping five-minute ASR windows with 48 samples each are required'
def session_directory(sessions_root, session_id):
    try:
        if not re.fullmatch(r'[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}', session_id):
            raise ValueError('expected a full UUID')
        identity = uuid.UUID(session_id)
        directories = sorted(sessions_root.iterdir())
    except (OSError, ValueError) as error:
        fail(f'cannot discover session {session_id}: {error}')
    matches = []
    for directory in directories:
        if not directory.is_dir(): continue
        try:
            manifest = json.loads((directory / 'session.json').read_text())
            if not isinstance(manifest, dict) or not isinstance(manifest.get('session_id'), str): continue
            decoded_id = uuid.UUID(manifest['session_id'])
        except (OSError, ValueError):
            continue
        if decoded_id == identity: matches.append((directory, manifest))
    if len(matches) != 1:
        fail(f'session {identity} has {len(matches)} matching folders: {[p.name for p, _ in matches]}')
    directory, manifest = matches[0]
    try:
        name = directory.name
        if len(name.encode('utf-8')) > 255 or '\0' in name or '/' in name or ':' in name:
            raise ValueError('illegal folder name or UTF-8 byte limit')
        parsed = re.fullmatch(r'([0-9]{4}-[0-9]{2}-[0-9]{2}_[0-9]{2}-[0-9]{2}-[0-9]{2})_(.+)_([0-9a-f]{8})', name)
        if not parsed: raise ValueError('invalid folder grammar')
        timestamp, stem, suffix = parsed.groups()
        datetime.datetime.strptime(timestamp, '%Y-%m-%d_%H-%M-%S')
        if suffix != str(identity)[:8]: raise ValueError('UUID suffix mismatch')
        if manifest['source_kind'] == 'recording':
            if manifest['capture_source'] not in ('microphone', 'systemAudio'):
                raise ValueError('invalid capture source')
            original_stem = '録音'
        elif manifest['source_kind'] == 'imported':
            filename = manifest['original_filename']
            if not isinstance(filename, str) or not filename or '\0' in filename:
                raise ValueError('invalid original filename')
            dot = filename.rfind('.')
            original_stem = filename[:dot] if dot > 0 else filename
        else:
            raise ValueError('invalid source kind')
        sanitized = original_stem.replace('/', '-').replace(':', '-')
        if sanitized.startswith('.'): sanitized = '-' + sanitized[1:]
        # Extended grapheme clusters preserve Swift Character truncation boundaries.
        try:
            import regex
        except ImportError as error:
            fail(f'folder validation requires the Python regex package: {error}')
        expected = ''
        byte_count = 0
        for character in regex.findall(r'\X', sanitized):
            size = len(character.encode('utf-8'))
            if byte_count + size > 226: break
            expected += character
            byte_count += size
        if not expected or unicodedata.normalize('NFC', stem) != unicodedata.normalize('NFC', expected):
            raise ValueError('source stem mismatch')
    except (KeyError, TypeError, ValueError) as error:
        fail(f'invalid matching session folder {directory}: {error}')
    return directory
events = None
directory = None
session = resume
if resume:
    directory = session_directory(pathlib.Path(root), resume)
else:
    match = re.search(r'^session_id: (\S+)\s*$', (folder / 'stdout.log').read_text(), re.MULTILINE)
    if match:
        session = match.group(1)
        directory = session_directory(pathlib.Path(root), session)
if directory:
    events = directory / 'events.jsonl'
    originals = sorted(p for p in (directory / 'audio').glob('*')
                       if p.is_file() and (p.name == 'original' or p.name.startswith('original.')))
    if len(originals) > 1: fail(f'session {session} has multiple original audio files: {[p.name for p in originals]}')
    if originals: audio = str(originals[0])
duration = None
if audio:
    probe = subprocess.run(['ffprobe','-v','error','-show_entries','format=duration','-of','default=noprint_wrappers=1:nokey=1',audio], capture_output=True, text=True)
    if probe.returncode == 0:
        try: duration = float(probe.stdout.strip())
        except ValueError: reason['recording_duration_seconds'] = f'ffprobe printed no duration: {probe.stdout.strip()!r}'
    else:
        reason['recording_duration_seconds'] = f'ffprobe could not read the audio: {probe.stderr.strip()}'
else:
    reason['recording_duration_seconds'] = 'the session has no single original audio file'
event_lines = []
if events and events.exists():
    try: event_lines = [json.loads(line) for line in events.read_text().splitlines() if line.strip()]
    except ValueError as error: reason['event_log'] = str(error)
else:
    reason['event_log'] = 'no session event log was found'
session_dir = directory
metadata = session_dir / 'processing_metadata.json' if session_dir else None
checkpoint = session_dir / 'audio/processing/checkpoint.json' if session_dir else None
active_runs = {}
sample_rate = None
if metadata and metadata.exists():
    active_runs = json.loads(metadata.read_text()).get('active_runs') or {}
if checkpoint and checkpoint.exists():
    sample_rate = read_json(checkpoint)['sampleRate']
completed = [e for e in event_lines if e.get('event_type') == 'processing.run.completed' and e.get('payload', {}).get('succeeded') is True]
diarization = next((e for e in reversed(completed) if e.get('processing_run_id') == active_runs.get('diarization') and e.get('payload', {}).get('stage') == 'diarization'), None)
if not diarization: reason['diarization_completed_at'] = 'no successful active diarization run was observed'
scene_changes = [e for e in event_lines if e.get('event_type') == 'scene.changed' and e.get('processing_run_id') == active_runs.get('scene')]
oscillations = None
if sample_rate and active_runs.get('scene'):
    ordered = sorted(scene_changes, key=lambda e: e['source_start_frame'])
    oscillations = sum(a['payload'] == c['payload'] != b['payload'] and
                       c['source_start_frame'] - a['source_start_frame'] <= 30 * sample_rate
                       for a, b, c in zip(ordered, ordered[1:], ordered[2:]))
else:
    reason['scene_oscillation_count'] = 'no active scene run or checkpoint sample rate'
for key in ('capture_dropout_count', 'jev_success_count', 'jev_failure_count', 'jev_retry_pending_count', 'crash_recovery_loss_window_seconds'):
    reason[key] = 'file import or offline session recovery cannot measure this live-session value'
report = {
 'run_id': run, 'recording_id': recording, 'session_id': session,
 'metric_scope': 'this_invocation', 'started_at': started, 'finished_at': finished,
 'wall_seconds': (datetime.datetime.fromisoformat(finished.replace('Z','+00:00')) - datetime.datetime.fromisoformat(started.replace('Z','+00:00'))).total_seconds(),
 'exit_code': int(exit_code), 'status': status,
 'command': ['MacAmbientJevProcessRecording', *args],
 'build_configuration': 'release', 'output_path': output,
 'environment': {'os': platform.platform(), 'machine': platform.machine(),
                 'mac_model': command('sysctl', '-n', 'hw.model'),
                 'physical_memory_bytes': int(command('sysctl', '-n', 'hw.memsize'))},
 'disk_available_bytes_before': int(disk_before),
 'commit': command('git', 'rev-parse', 'HEAD'),
 'tracked_diff_sha256': hashlib.sha256(subprocess.check_output(['git','diff','--binary'], cwd=repo)).hexdigest(),
 'source_snapshot_sha256': digest(folder / 'source-snapshot.tar.gz'),
 'package_resolved_sha256': digest(pathlib.Path(repo) / 'app/MacAmbientJev/Package.resolved'),
 'working_tree_status': command('git', 'status', '--porcelain'),
 'input_sha256': digest(audio) if audio else None,
 'recording_duration_seconds': duration,
 'event_log_sha256': digest(events) if events and events.exists() else None,
 'asr_call_seconds': asr_value('asrCallSeconds'),
 'model_load_seconds': asr_value('modelLoadSeconds'),
 'processed_audio_seconds': asr_value('processedAudioSeconds'),
 'pacing_wait_seconds': asr_value('pacingWaitSeconds'),
 'asr_rtf': rtf,
 'maximum_pending_count': asr_value('maximumPendingCount'),
 'oldest_pending_age_ms': round(asr['oldestPendingAgeSeconds'] * 1000) if asr is not None else None,
 'peak_memory_mb': peak / (1024 * 1024) if peak is not None else None,
 'max_rss_bytes': rss,
 'memory_growth_mb': growth, 'memory_verdict': memory_verdict,
 'memory_sample_count': len(asr_samples),
 'thermal_sample_count': len(thermal_samples),
 'diarization_completed_at': diarization.get('created_at') if diarization else None,
 'scene_change_count': len(scene_changes) if active_runs.get('scene') else None,
 'scene_oscillation_count': oscillations,
 'capture_dropout_count': None, 'jev_success_count': None,
 'jev_failure_count': None, 'jev_retry_pending_count': None,
 'crash_recovery_loss_window_seconds': None,
 'unavailable_reason': reason
}
if int(exit_code) == 0 and pathlib.Path(output).exists():
    shutil.copy2(output, folder / 'segments.json')
(folder / 'run.json').write_text(json.dumps(report, ensure_ascii=False, indent=2, sort_keys=True) + '\n')
print(folder / 'run.json')
if status != 'completed': fail(f'processing did not complete: {status}')
if memory_verdict == 'FAILED': fail('memory verdict FAILED')
PY

exit "$exit_code"
