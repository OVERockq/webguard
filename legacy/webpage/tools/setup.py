#!/usr/bin/env python3
"""Create local-only credentials without printing secrets; preserve existing config."""
import os
from pathlib import Path
import secrets
import subprocess
ROOT=Path(__file__).resolve().parents[1]
if (ROOT/'.env').exists():
    raise SystemExit('.env already exists; existing credentials preserved')
password=secrets.token_urlsafe(24)
result=subprocess.run(['docker','run','--rm','-i','wglegacy-php83','php','-r',
                      'echo password_hash(trim(stream_get_contents(STDIN)), PASSWORD_DEFAULT);'],
                      input=password.encode(),capture_output=True,check=True)
config="WG_CMS_ADMIN_PASSWORD_HASH='"+result.stdout.decode()+"'\nWG_CMS_IP_SALT="+secrets.token_hex(32)+'\n'
fd=os.open(ROOT/'.env',os.O_CREAT|os.O_EXCL|os.O_WRONLY,0o600)
with os.fdopen(fd,'w') as f: f.write(config)
out=ROOT/'verification-artifacts';out.mkdir(exist_ok=True)
fd=os.open(out/'admin-credentials.txt',os.O_CREAT|os.O_EXCL|os.O_WRONLY,0o600)
with os.fdopen(fd,'w') as f: f.write('Admin password: '+password+'\n')
print('Local configuration created; password: verification-artifacts/admin-credentials.txt')
