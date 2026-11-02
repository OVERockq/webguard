#!/usr/bin/env python3
"""Isolated fixture clone comparison. Artifacts and live containers are retained."""
import difflib
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import time

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[2]
LAB = Path(tempfile.mkdtemp(prefix='webguard-lab-'))
PROJECT = 'wgverify' + str(int(time.time()))
ENV = dict(os.environ, WG_LAB=str(LAB))
COMPOSE = ['docker', 'compose', '-p', PROJECT, '-f', str(HERE / 'compose.yml')]
checks = []
warnings = []


def run(args, check=True):
    result = subprocess.run(args, env=ENV, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    if check and result.returncode:
        raise RuntimeError(f'{args}:\n{result.stdout.decode(errors="replace")}')
    return result


def dc(*args, check=True):
    return run(COMPOSE + list(args), check)


def ex(service, *args, check=True):
    return dc('exec', '-T', service, *args, check=check)


def record(name, passed, detail=''):
    checks.append(dict(name=name, passed=bool(passed), detail=detail))
    print(('PASS ' if passed else 'FAIL ') + name, flush=True)


def capture(service, path, label):
    result = ex(service, 'curl', '-sS', '--max-time', '15', '-w', '\n%{http_code}', 'http://localhost' + path)
    body, status = result.stdout.rsplit(b'\n', 1)
    out = LAB / 'responses' / label
    out.parent.mkdir(exist_ok=True)
    out.write_bytes(body)
    return body, status.decode()


def wg(command, label):
    r = ex('work', 'env', 'WG_NO_COLOR=1', '/opt/webguard/webguard', *command, check=False)
    (LAB / (label + '.log')).write_bytes(r.stdout)
    record(label + ' exit code', r.returncode == 0, str(r.returncode))
    return r


def db_snapshot():
    return ex('db', 'mariadb', '-uzbuser', '-pzbpass123', '-N', 'zbdb', '-e',
              'SELECT no,HEX(subject),HEX(name) FROM zetyx_board_board1 ORDER BY no; CHECKSUM TABLE zetyx_board_board1;').stdout


def manifest(path):
    return {str(p.relative_to(path)): hashlib.sha256(p.read_bytes()).hexdigest()
            for p in path.rglob('*') if p.is_file()}


def main():
    print(f'LAB={LAB}\nPROJECT={PROJECT}', flush=True)
    for name in ('asis', 'work'):
        shutil.copytree(ROOT / 'tests/fixtures/legacy', LAB / name)
        (LAB / name / 'dot-git').rename(LAB / name / '.git')
    original = manifest(LAB / 'asis')
    dc('up', '-d')
    for attempt in range(60):
        r = ex('db', 'mariadb', '-uzbuser', '-pzbpass123', 'zbdb', '-e', 'SELECT 1', check=False)
        if r.returncode == 0:
            break
        time.sleep(1)
    else:
        raise RuntimeError('database readiness timeout')
    for service in ('asis', 'work', 'tobe'):
        for attempt in range(30):
            if ex(service, 'curl', '-fsS', '--max-time', '2', 'http://localhost/', check=False).returncode == 0:
                break
            time.sleep(1)
        else:
            raise RuntimeError(service + ' HTTP readiness timeout')
    (LAB / 'images.json').write_bytes(run(['docker', 'image', 'inspect', 'wglegacy-php56', 'wglegacy-php83', 'mariadb:10.6']).stdout)
    before_db = db_snapshot()
    (LAB / 'db-before.tsv').write_bytes(before_db)
    paths = ['/legacy/list.php', '/legacy/view.php?no=1', '/bbs/zboard.php?id=board1', '/style.css']
    baseline = {}
    for i, path in enumerate(paths):
        baseline[path] = capture('asis', path, f'asis-{i}.body')
        record('AS-IS HTTP 200 ' + path, baseline[path][1] == '200')
    broken, status = capture('tobe', paths[0], 'unconverted-php83.body')
    record('Unconverted PHP 8.3 fails', status == '500' or b'Parse error' in broken or b'Fatal error' in broken, status)
    wg(['run', '--root', '/var/www/html', '--url', 'http://localhost', '--target-php', '8.3', '--offline'], 'analyze-backup-scan-plan')
    wg(['apply', '--root', '/var/www/html', '--yes'], 'apply')
    for i, path in enumerate(paths):
        patched, code56 = capture('work', path, f'patched56-{i}.body')
        migrated, code83 = capture('tobe', path, f'tobe83-{i}.body')
        record('Patched PHP 5.6 HTTP 200 ' + path, code56 == '200')
        record('TO-BE PHP 8.3 HTTP 200 ' + path, code83 == '200')
        record('PHP 5.6 / 8.3 identical output ' + path, patched == migrated)
        record('TO-BE no PHP errors ' + path, not any(x in migrated for x in (b'Fatal error', b'Parse error', b'Warning:', b'Deprecated:')))
        record('AS-IS clone unchanged ' + path, capture('asis', path, f'asis-after-{i}.body') == baseline[path])
        if baseline[path][0] != patched:
            (LAB / f'asis-to-patched-{i}.diff').write_text('\n'.join(difflib.unified_diff(
                baseline[path][0].decode('euc-kr').splitlines(), patched.decode('euc-kr').splitlines(),
                fromfile='AS-IS', tofile='Patched PHP 5.6')), encoding='utf-8')
            record('Known EUC-KR baseline defect ' + path, b'htmlspecialchars(): charset' in baseline[path][0] and b'Warning' not in patched)
    body = (LAB / 'responses/tobe83-0.body').read_bytes().decode('euc-kr')
    record('Korean database content preserved', '안녕하세요 첫 글입니다 (관리자)' in body)
    record('HTML escaping preserved', '두번째 &lt;b&gt;게시물&lt;/b&gt;' in body)
    record('Removed PHP APIs work', 'first=a c=h keys=xy up=OK num mq=off' in body and 'count=2 sel=y' in body)
    for service in ('work', 'tobe'):
        for path in ('/.git/HEAD', '/backup.sql', '/bbs/config.php', '/legacy/view.php?no=1&GLOBALS=x'):
            _, status = capture(service, path, service + '-blocked-' + str(len(checks)) + '.body')
            record(service + ' blocks ' + path, status == '403', status)
        _, status = capture(service, '/bbs/data/board1/shell.php', service + '-shell.body')
        record(service + ' webshell unavailable', status in ('403', '404'), status)
    after_db = db_snapshot()
    (LAB / 'db-after.tsv').write_bytes(after_db)
    record('Database rows and checksum unchanged', before_db == after_db)
    wg(['verify', '--root', '/var/www/html'], 'verify')
    wg(['datacheck', 'target', '--root', '/var/www/html', '--target-url', 'http://tobe'], 'datacheck-target')
    record('AS-IS files unchanged', original == manifest(LAB / 'asis'))
    reads = {}
    for service in ('work', 'tobe'):
        reads[service] = ex(service, 'env', 'WG_DB_HOST=db', 'WG_DB_USER=zbuser',
            'WG_DB_PASS=zbpass123', 'WG_DB_NAME=zbdb', 'WG_MB_ENCODING=UTF-8',
            'php', '-d', 'default_charset=EUC-KR', '-d', 'internal_encoding=ISO-8859-1',
            '/opt/webguard/assets/php/datacheck.php', 'dbread', '100',
            '/opt/webguard/assets/runtime/compat.php').stdout
        (LAB / ('dbread-' + service + '.tsv')).write_bytes(reads[service])
    if reads['work'] != reads['tobe']:
        warnings.append('PHP 5.6/8.3 mb_* results differ for EUC-KR bytes interpreted as UTF-8; see dbread.diff. Full function equivalence is not established.')
    filtered = {k: b'\n'.join(x for x in v.splitlines() if b':mb_' not in x) for k, v in reads.items()}
    record('Cross-version DB reads and non-mb string functions identical',
           len(reads['work'].splitlines()) > 10 and filtered['work'] == filtered['tobe'])
    (LAB / 'dbread.diff').write_text('\n'.join(difflib.unified_diff(
        reads['work'].decode().splitlines(), reads['tobe'].decode().splitlines(),
        fromfile='PHP 5.6', tofile='PHP 8.3')))
    wg(['rollback', '--root', '/var/www/html', '--yes'], 'rollback')
    record('Rollback restores original file bytes', original == manifest(LAB / 'work'))
    wg(['apply', '--root', '/var/www/html', '--yes'], 'reapply-for-preview')
    record('Reapplied PHP 8.3 output restored', capture('tobe', paths[0], 'reapplied83.body')[0] == (LAB / 'responses/tobe83-0.body').read_bytes())
    dc('cp', 'work:/var/lib/webguard', str(LAB / 'webguard-state'))
    (LAB / 'endpoints.txt').write_text('\n'.join(service + ': http://' + dc('port', service, '80').stdout.decode().strip() for service in ('asis', 'work', 'tobe')) + '\n')
    dc('ps')


if __name__ == '__main__':
    error = None
    try:
        main()
    except Exception as exc:
        error = str(exc)
        print(error, flush=True)
        record('Harness completed', False, error)
    finally:
        report = dict(project=PROJECT, lab=str(LAB), checks=checks, warnings=warnings, error=error,
                      compose_command=COMPOSE, environment={'WG_LAB': str(LAB)})
        (LAB / 'results.json').write_text(json.dumps(report, ensure_ascii=False, indent=2))
        for warning in warnings:
            print('WARNING ' + warning, flush=True)
        print(f'Result: {sum(c["passed"] for c in checks)}/{len(checks)}; artifacts: {LAB}', flush=True)
    raise SystemExit(0 if checks and all(c['passed'] for c in checks) else 1)
