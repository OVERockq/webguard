#!/usr/bin/env python3
"""Diagnosis checks in a network-isolated Apache container. Container stops on completion."""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time
ROOT=Path(__file__).resolve().parents[3]
WORK=Path(tempfile.mkdtemp(prefix='webguard-diagnose-'))
NAME='wgdiagnose'+str(time.time_ns())
checks=[]
def run(args,check=True):
    r=subprocess.run(args,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=180)
    if check and r.returncode: raise RuntimeError(r.stdout.decode(errors='replace'))
    return r
def ex(*args,check=True): return run(['docker','exec',NAME,*args],check)
def record(name,ok):
    checks.append(dict(name=name,passed=bool(ok)))
    print(('PASS ' if ok else 'FAIL ')+name,flush=True)
    if not ok: raise RuntimeError(name)
def manifest():
    return {str(p.relative_to(WORK/'site')):hashlib.sha256(p.read_bytes()).hexdigest() for p in (WORK/'site').rglob('*') if p.is_file()}
def main():
    site=WORK/'site';site.mkdir()
    (site/'index.php').write_text('<?php file_put_contents("/tmp/diagnosis-http-hit", "hit\\n", FILE_APPEND); echo "diagnosis fixture";')
    (site/'backup.sql').write_text('-- synthetic diagnostic fixture\n')
    for d in ('wp-includes','wp-admin','wp-content/uploads'): (site/d).mkdir(parents=True)
    (site/'wp-includes/version.php').write_text("<?php $wp_version = '6.6.2';\n")
    (site/'wp-config.php').write_text("<?php define('DB_NAME','lab'); define('AUTH_KEY','put your unique phrase here');\n")
    before=manifest()
    run(['docker','run','-d','--name',NAME,'--network','none','-v',str(ROOT)+':/opt/webguard:ro','-v',str(site)+':/var/www/html',
         'wglegacy-php83','bash','-c',"a2enmod headers >/dev/null && sed -i 's/AllowOverride None/AllowOverride All/g' /etc/apache2/apache2.conf && exec apache2-foreground"])
    # Apache readiness without generating a site request.
    for _ in range(30):
        if ex('php','-r','$s=@fsockopen("127.0.0.1",80); exit($s?0:1);',check=False).returncode==0: break
        time.sleep(1)
    else: raise RuntimeError('Apache readiness timeout')
    ex('bash','-c','mkdir -p /var/lib/webguard/sites/var_www_html; ln -s /tmp/normal-patch-record /var/lib/webguard/sites/var_www_html/latest')
    for mode in ('passive','active'):
        cmd=['/opt/webguard/webguard','diagnose','--root','/var/www/html','--url','http://localhost','--target-php','8.3']
        if mode=='active':cmd+=['--active']
        r=ex(*cmd,check=False);(WORK/(mode+'.log')).write_bytes(r.stdout)
        record(mode+' diagnosis completes',r.returncode==0)
        record(mode+' leaves site files unchanged',before==manifest())
        state=ex('bash','-c','readlink -f /var/lib/webguard/diagnostics/sites/var_www_html/latest').stdout.decode().strip()
        record(mode+' mode recorded',f'DIAGNOSTIC_MODE={mode}' in ex('cat',state+'/env.sh').stdout.decode())
        record(mode+' report marks diagnostic limitations',b'diagnosis.md' in ex('cat',state+'/report.md').stdout)
        record(mode+' does not create patch or backup records',ex('bash','-c','test ! -e "$1/plan.tsv" && test ! -e "$1/changes" && test ! -e "$1/apply.tsv" && test ! -d /var/backups/webguard','check',state,check=False).returncode==0)
        record(mode+' preserves normal latest context',ex('readlink','/var/lib/webguard/sites/var_www_html/latest').stdout.strip()==b'/tmp/normal-patch-record')
        record(mode+' recognizes WordPress files',b'wordpress' in ex('cat',state+'/cms.tsv').stdout)
        findings=ex('cat',state+'/findings.tsv').stdout
        record(mode+' reports synthetic database dump',b'\tdb_dump\t' in findings)
        record(mode+' reports default WordPress salts',b'\twp_default_salts\t' in findings)
        hit=ex('test','-f','/tmp/diagnosis-http-hit',check=False).returncode==0
        record(mode+' HTTP behavior matches chosen mode',hit==(mode=='active'))
        if mode=='active':
            record('Active captures actual PHP probe',b'PROBE_PHP_VERSION=' in ex('cat',state+'/env.sh').stdout)
            record('Active captures baseline',ex('test','-s',state+'/baseline.tsv',check=False).returncode==0)
        run(['docker','cp',NAME+':'+state,str(WORK/mode)])
    record('Container has no external network',json.loads(run(['docker','inspect',NAME]).stdout)[0]['HostConfig']['NetworkMode']=='none')
    print('Artifacts:',WORK)

error=None
try: main()
except Exception as exc: error=str(exc);print(error,flush=True)
finally:
    (WORK/'results.json').write_text(json.dumps(dict(checks=checks,error=error),ensure_ascii=False,indent=2))
    run(['docker','stop',NAME],check=False)
print(f'Result: {sum(x["passed"] for x in checks)}/{len(checks)}; error={error is not None}')
raise SystemExit(1 if error else 0)
