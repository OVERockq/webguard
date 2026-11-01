#!/usr/bin/env python3
"""Apply WebGuard only to an isolated copy of the current introduction CMS."""
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import time

HERE=Path(__file__).resolve().parent
ROOT=HERE.parents[2]
SOURCE=ROOT/'legacy/webpage'
LAB=Path(tempfile.mkdtemp(prefix='webguard-cms-patch-'))
PROJECT='wgcmslab'+str(int(time.time()))
ENV=dict(os.environ,WG_PATCH_LAB=str(LAB))
DC=['docker','compose','-p',PROJECT,'-f',str(HERE/'compose.yml')]
LIVE=['docker','compose','-p','webguard-intro','-f',str(SOURCE/'compose.yml')]
checks=[]
def run(cmd,check=True):
    r=subprocess.run(cmd,env=ENV,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=600)
    if check and r.returncode: raise RuntimeError(str(cmd)+':\n'+r.stdout.decode(errors='replace'))
    return r

def ex(*args,check=True): return run(DC+['exec','-T','cms',*args],check)
def record(name,ok,detail=''):
    checks.append(dict(name=name,passed=bool(ok),detail=detail))
    print(('PASS ' if ok else 'FAIL ')+name,flush=True)
    if not ok: raise RuntimeError(name+': '+detail)
def manifest(directory):
    return {str(p.relative_to(directory)):hashlib.sha256(p.read_bytes()).hexdigest() for p in directory.rglob('*') if p.is_file()}
def db_snapshot(live=False):
    code='$d=new PDO("sqlite:/var/lib/webguard-cms/cms.sqlite"); $out=[]; foreach(["pages","inquiries","page_defaults"] as $t) {$out[$t]=$d->query("SELECT * FROM ".$t." ORDER BY 1")->fetchAll(PDO::FETCH_ASSOC);} echo json_encode($out);'
    cmd=(LIVE if live else DC)+['exec','-T','cms','php','-r',code]
    return hashlib.sha256(run(cmd).stdout).hexdigest()
def fetch(path,label):
    r=ex('curl','-sS','--max-time','15','-w','\n%{http_code}','http://localhost'+path)
    body,code=r.stdout.rsplit(b'\n',1)
    (LAB/'responses'/label).write_bytes(body)
    return body,code.decode()
def wg(args,label):
    r=ex('env','WG_NO_COLOR=1','/opt/webguard/webguard',*args,check=False)
    (LAB/(label+'.log')).write_bytes(r.stdout)
    record(label+' exit',r.returncode==0,str(r.returncode))
def security_headers():
    lines=ex('curl','-sSI','--max-time','15','http://localhost/').stdout.decode().splitlines()
    selected={}
    for line in lines:
        if ':' in line:
            key,value=line.split(':',1)
            if key.lower() in ('content-security-policy','referrer-policy','x-content-type-options','cache-control'):
                selected[key.lower()]=value.strip()
    return selected

def normalized(body): return re.sub(rb'name="csrf" value="[^"]+"',b'name="csrf" value="TOKEN"',body)

def main():
    print(f'LAB={LAB}\nPROJECT={PROJECT}',flush=True)
    original_files={folder:manifest(SOURCE/folder) for folder in ('public','src')}
    original_db=db_snapshot(live=True)
    for folder in ('public','src'): shutil.copytree(SOURCE/folder,LAB/folder)
    (LAB/'data').mkdir();(LAB/'responses').mkdir()
    # SQLite creates a consistent snapshot while the original stays online.
    tmp='/tmp/'+PROJECT+'.sqlite'
    code='$d=new PDO("sqlite:/var/lib/webguard-cms/cms.sqlite"); $d->exec("VACUUM INTO ".$d->quote($argv[1]));'
    run(LIVE+['exec','-T','cms','php','-r',code,tmp])
    run(LIVE+['cp','cms:'+tmp,str(LAB/'data/cms.sqlite')])
    # Harmless defects are injected only into the disposable clone.
    samples={'backup.sql':'-- LAB ONLY: synthetic dump, no real data\n',
             'index.php.bak':'LAB ONLY: synthetic source backup\n',
             '.env':'LAB_ONLY=synthetic-not-a-secret\n',
             '.git/HEAD':'ref: refs/heads/lab-only\n',
             'phpinfo.php':'<?php phpinfo();\n',
             'uploads/test.php':'<?php echo "WG-LAB-EXEC";\n',
             'uploads/readme.txt':'LAB ONLY: static upload\n'}
    for name,text in samples.items():
        p=LAB/'public'/name;p.parent.mkdir(parents=True,exist_ok=True);p.write_text(text)
    seeded_files=manifest(LAB/'public')
    run(DC+['up','-d'])
    for _ in range(30):
        if ex('curl','-fsS','--max-time','2','http://localhost/',check=False).returncode==0: break
        time.sleep(1)
    else: raise RuntimeError('HTTP readiness timeout')
    paths=['/index.php?page='+slug for slug in ('home','features','benefits','about','inquiries')]+['/assets/site.css','/admin.php']
    before={}
    for i,path in enumerate(paths):
        before[path]=fetch(path,f'before-{i}.body')
        record('Baseline 200 '+path,before[path][1]=='200')
    for name in samples:
        _,status=fetch('/'+name,'exposed-'+name.replace('/','_')+'.body')
        record('Seed exposed '+name,status=='200',status)
    before_headers=security_headers()
    (LAB/'headers-before.json').write_text(json.dumps(before_headers,indent=2))
    before_db=db_snapshot()
    wg(['run','--root','/var/www/html','--url','http://localhost','--offline'],'scan-plan')
    run(DC+['cp','cms:/var/lib/webguard',str(LAB/'state-before')])
    plans=list((LAB/'state-before/runs').glob('*/plan.tsv'))
    if len(plans)!=1: raise RuntimeError('Unexpected run count')
    plan=plans[0];rows=plan.read_text().splitlines()
    allowed={'quarantine','deny_files','deny_dir','noexec_dir','htaccess_options','php_ini','security_headers','chmod_list'}
    selected=[];enabled=[]
    for row in rows:
        if row.startswith('#') or not row.strip(): selected.append(row);continue
        cells=row.split('\t')
        if cells[0]=='y' and cells[2] in allowed: enabled.append(cells[2])
        else: cells[0]='n'
        selected.append('\t'.join(cells))
    record('Bounded patch actions selected',len(enabled)>0,','.join(enabled))
    (LAB/'selected-plan.tsv').write_text('\n'.join(selected)+'\n')
    run(DC+['cp',str(LAB/'selected-plan.tsv'),'cms:/var/lib/webguard/sites/var_www_html/latest/plan.tsv'])
    wg(['apply','--root','/var/www/html','--dry-run'],'dry-run')
    wg(['apply','--root','/var/www/html','--yes'],'apply')
    for i,path in enumerate(paths):
        after=fetch(path,f'after-{i}.body')
        record('Page unchanged '+path,after[1]=='200' and normalized(after[0])==normalized(before[path][0]))
    for name in samples:
        body,status=fetch('/'+name,'patched-'+name.replace('/','_')+'.body')
        if name.endswith('readme.txt'): record('Static upload preserved',status=='200')
        else: record('Exposure blocked '+name,status in ('403','404'),status)
    record('Patch leaves SQLite data unchanged',before_db==db_snapshot())
    after_headers=security_headers()
    (LAB/'headers-after.json').write_text(json.dumps(after_headers,indent=2))
    record('Existing CSP and security policies preserved',before_headers==after_headers)
    wg(['verify','--root','/var/www/html'],'verify')
    # Full existing CMS flows run only on the clone, using its copied administrator hash.
    endpoint=run(DC+['port','cms','80']).stdout.decode().strip()
    ENV['WG_CMS_VERIFY_OUTPUT']=str(LAB/'cms-functional-results.json')
    r=run(['python3',str(SOURCE/'tools/verify.py'),'http://'+endpoint],check=False)
    ENV.pop('WG_CMS_VERIFY_OUTPUT',None)
    (LAB/'cms-functional.log').write_bytes(r.stdout)
    record('CMS functional and security checks',r.returncode==0,r.stdout.decode()[-300:])
    wg(['report','--root','/var/www/html'],'report')
    run(DC+['cp','cms:/var/lib/webguard',str(LAB/'state-after')])
    wg(['rollback','--root','/var/www/html','--yes'],'rollback')
    record('Rollback restores seeded clone file bytes',manifest(LAB/'public')==seeded_files)
    run(DC+['cp','cms:/var/lib/webguard',str(LAB/'state-rollback')])
    # Retain a working patched preview after proving restoration.
    wg(['apply','--root','/var/www/html','--yes'],'reapply')
    _,status=fetch('/backup.sql','reapply-dump.body');record('Reapplied protection active',status in ('403','404'))
    record('Original source files unchanged',all(manifest(SOURCE/k)==v for k,v in original_files.items()))
    record('Original CMS database unchanged',original_db==db_snapshot(live=True))
    (LAB/'endpoint.txt').write_text('http://'+endpoint+'\n')
    (LAB/'images.json').write_bytes(run(['docker','image','inspect','wglegacy-php83']).stdout)

if __name__=='__main__':
    error=None
    try: main()
    except Exception as exn:
        error=str(exn);print(error,flush=True)
    finally:
        (LAB/'results.json').write_text(json.dumps(dict(project=PROJECT,lab=str(LAB),checks=checks,error=error),ensure_ascii=False,indent=2))
        print(f'Result: {sum(x["passed"] for x in checks)}/{len(checks)}; error={error is not None}; artifacts={LAB}',flush=True)
    raise SystemExit(1 if error or not checks or not all(x['passed'] for x in checks) else 0)
