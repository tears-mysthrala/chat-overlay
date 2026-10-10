from pathlib import Path
import json, hashlib, statistics, sys
p = Path(sys.argv[1])
d = json.loads(p.read_text(encoding='utf-8-sig'))
seconds = d['duration_seconds']
if (seconds not in (14400, 86400) or d['actual_elapsed_ms'] < seconds * 1000
    or d['emitted'] <= 0 or d['received_samples'] != d['expected_samples']
    or d['expected_samples'] != d['emitted'] * 10 or d['errors'] != 0
    or not 0 <= d['p95_local_to_sse_ms'] < 100
    or (d['profiles'], d['sources'], d['readers']) != (10, 30, 100)):
    raise SystemExit('Incomplete run, delivery mismatch or failed load gate')
active = [x for x in d['resource_samples'] if x['elapsed_ms'] < seconds * 1000]
slots = [x['elapsed_ms'] // 60000 for x in active]
if slots != list(range(seconds // 60)) or any(x['errors'] != 0 for x in active):
    raise SystemExit('Missing/duplicate/out-of-order resource slot or resource error')
hours = []
for hour in range(seconds // 3600):
    xs = [x['memory_total_bytes'] for x in active
          if hour * 3600000 <= x['elapsed_ms'] < (hour + 1) * 3600000]
    hours.append({'hour': hour + 1, 'samples': len(xs),
                  'mean_MB': round(statistics.mean(xs) / 1e6, 3),
                  'min_MB': round(min(xs) / 1e6, 3),
                  'max_MB': round(max(xs) / 1e6, 3)})
summary = {k: d[k] for k in ['duration_seconds', 'actual_elapsed_ms', 'source_commit',
    'emitted', 'received_samples', 'expected_samples', 'errors', 'p95_local_to_sse_ms',
    'memory_peak_sampled_bytes']}
summary.update(sha256=hashlib.sha256(p.read_bytes()).hexdigest(), active_samples=len(active),
               active_process_counts=sorted(set(x['process_count'] for x in active)),
               resource_sample_errors=sum(x['errors'] for x in active), hours=hours)
# Resource statistics still require a reasoned conclusion; exit 0 alone is not
# proof of stability or acceptance of a different deployment/candidate.
print(json.dumps(summary, indent=2))
