#!/usr/bin/env python3
"""HTTP integration checks against a local CMS. Uses a dedicated test inquiry."""
import html
import http.cookiejar
import json
import os
from pathlib import Path
import re
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
ROOT=Path(__file__).resolve().parents[1]
BASE=sys.argv[1].rstrip('/')
if not re.fullmatch(r'http://127\.0\.0\.1:\d+',BASE): raise SystemExit('Localhost URL required')
password=(ROOT/'verification-artifacts/admin-credentials.txt').read_text().strip().split(': ',1)[1]
results=[]
def client(): return urllib.request.build_opener(urllib.request.HTTPCookieProcessor(http.cookiejar.CookieJar()))
public=client(); manager=client(); anonymous=client()
def request(c,path,data=None):
    req=urllib.request.Request(BASE+path,data=urllib.parse.urlencode(data).encode() if data is not None else None)
    try: r=c.open(req,timeout=15)
    except urllib.error.HTTPError as ex: r=ex
    return r.code,r.read().decode(),r.headers
def token(body): return html.unescape(re.search(r'name="csrf" value="([^"]+)"',body).group(1))
def check(name,condition):
    results.append({'name':name,'passed':bool(condition)})
    print(('PASS ' if condition else 'FAIL ')+name,flush=True)
    if not condition: raise AssertionError(name)
def run():
    for slug in ('home','features','benefits','about','inquiries'):
        code,body,headers=request(public,'/index.php?page='+slug)
        check('Public page '+slug,code==200 and '<h1>' in body and '<html lang="ko">' in body)
        check('Security headers '+slug,headers.get('X-Content-Type-Options')=='nosniff' and "script-src 'none'" in headers.get('Content-Security-Policy',''))
    check('Unknown page returns 404',request(public,'/index.php?page=missing')[0]==404)
    check('Source outside document root',request(public,'/src/content.json')[0]==404)
    check('Database outside document root',request(public,'/var/cms.sqlite')[0]==404)
    code,body,_=request(public,'/index.php?page=inquiries')
    csrf=token(body)
    check('CSRF blocks inquiry',request(public,'/index.php?page=inquiries',{'csrf':'bad','name':'tester','title':'bad','message':'bad'})[0]==403)
    marker='검증 문의 '+str(time.time_ns())
    payload='<script>alert("test")</script> SQL: \' OR 1=1 --'
    for attempt in range(65):
        code,body,_=request(public,'/index.php?page=inquiries',{'csrf':csrf,'name':'통합 테스트','title':marker,'message':payload})
        if code!=422 or '1분 후' not in body: break
        time.sleep(1)
    check('Inquiry accepted pending moderation',code==200 and '문의가 접수되었습니다' in body and marker not in body)
    check('Inquiry throttled',request(public,'/index.php?page=inquiries',{'csrf':csrf,'name':'tester','title':'again','message':'again'})[0]==422)
    code,body,_=request(anonymous,'/admin.php')
    check('Anonymous cannot moderate',request(anonymous,'/admin.php',{'csrf':token(body),'action':'moderate','id':1,'status':'published'})[0]==403)
    code,body,_=request(manager,'/admin.php')
    code,body,_=request(manager,'/admin.php',{'csrf':token(body),'action':'login','password':password})
    check('Admin login',code==200 and '소개 페이지 편집' in body)
    check('Pending inquiry visible to admin',marker in body)
    match=re.search(r'<article class="note"><h3>'+re.escape(marker)+r'</h3>.*?name="id" value="(\d+)"',body,re.S)
    check('Inquiry has stored ID',match is not None)
    post_id=match.group(1)
    check('Pending detail not public',request(public,'/index.php?page=inquiries&id='+post_id)[0]==404)
    request(manager,'/admin.php',{'csrf':token(body),'action':'moderate','id':post_id,'status':'published'})
    code,body,_=request(public,'/index.php?page=inquiries&id='+post_id)
    check('Published inquiry visible',code==200 and marker in body)
    check('Stored XSS escaped',html.escape(payload,quote=True).replace('&#x27;','&#039;') in body and '<script>' not in body)
    code,body,_=request(manager,'/admin.php?edit=home')
    original={k:html.unescape(re.search(r'<textarea[^>]*name="'+k+r'"[^>]*>(.*?)</textarea>',body,re.S).group(1)) for k in ('headline','lead','body_title','body')}
    edited=dict(original,headline='CMS 저장 검증 <b>일반 텍스트</b>')
    request(manager,'/admin.php',dict(edited,csrf=token(body),action='page',slug='home'))
    code,public_body,_=request(public,'/index.php')
    check('CMS edits reflected and escaped',code==200 and 'CMS 저장 검증 &lt;b&gt;일반 텍스트&lt;/b&gt;' in public_body)
    _,body,_=request(manager,'/admin.php')
    request(manager,'/admin.php',dict(original,csrf=token(body),action='page',slug='home'))
    _,body,_=request(manager,'/admin.php')
    request(manager,'/admin.php',{'csrf':token(body),'action':'moderate','id':post_id,'status':'archived'})
    check('Archived inquiry hidden',request(public,'/index.php?page=inquiries&id='+post_id)[0]==404)
    _,body,_=request(manager,'/admin.php')
    request(manager,'/admin.php',{'csrf':token(body),'action':'logout'})
    check('Admin logout', '관리자 로그인' in request(manager,'/admin.php')[1])
try: run()
finally:
    out=Path(os.environ.get('WG_CMS_VERIFY_OUTPUT',str(ROOT/'verification-artifacts/results.json')));out.write_text(json.dumps(results,ensure_ascii=False,indent=2))
    print(f'Result: {sum(x["passed"] for x in results)}/{len(results)}; {out}')
