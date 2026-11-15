#!/usr/bin/env python3
import json, os, pathlib, shutil, subprocess, tempfile, unittest
SOURCE = pathlib.Path(os.environ['EZR_SOURCE']).resolve()
DOCKER = '''#!/usr/bin/python3
import os,sys,json,pathlib
p=pathlib.Path(os.environ['FAKE_STATE']); s=json.loads(p.read_text()); a=sys.argv[1:]
s.setdefault('calls',[]).append(a)
def out(code=0,text=''):
 p.write_text(json.dumps(s)); print(text); sys.exit(code)
if a[0]=='info': out()
if a[0]=='build':
 if s.get('build_fail'): out(1)
 if '--iidfile' in a: pathlib.Path(a[a.index('--iidfile')+1]).write_text('sha256:'+'a'*64)
 out()
if a[0]=='compose':
 a=a[1:]
 while a and a[0] in ('-p','-f'): a=a[2:]
 cmd=a[0]
 if cmd in ['run','up']: out()
 if cmd=='port': out(text='127.0.0.1:8877')
 if cmd=='ps' and '--status' in a:
  n=s.get('running_n',0); s['running_n']=n+1
  value=s.get('running',[]); value=value[n] if n<len(value) else 1
  out(text='running-container' if value else '')
 if cmd in ['exec','down','ps']:
  key=cmd+'_n'; n=s.get(key,0); s[key]=n+1
  value=s.get(cmd,[]); value=value[n] if n<len(value) else 0
  if cmd=='ps': out(text='remaining-container' if value else '')
  out(value)
out(99,'UNEXPECTED MOCK COMMAND')
'''
class Worker(unittest.TestCase):
 def run_case(self, state=None, commands='stop\n', locked=False):
  with tempfile.TemporaryDirectory(prefix='ezr-worker-test-') as d:
   root=pathlib.Path(d); stage=root/'日本語 space'; stage.mkdir(); bin=root/'bin';bin.mkdir()
   shutil.copy2(SOURCE/'start_mac.command',stage/'start_mac.command')
   (stage/'launcher').mkdir();shutil.copy2(SOURCE/'launcher'/'start_messages.txt',stage/'launcher'/'start_messages.txt')
   for f in ['docker-compose.yml','Dockerfile']: (stage/f).write_text('test')
   (stage/'TEMPLATE_VERSION.txt').write_text('template candidate test\n')
   statefile=root/'state.json';statefile.write_text(json.dumps(state or {}))
   for name,body in {'docker':DOCKER,'sleep':'#!/bin/sh\nexit 0\n','curl':'#!/bin/sh\nexit 0\n','sysctl':'#!/bin/sh\necho 1\n'}.items():
    p=bin/name;p.write_text(body);p.chmod(0o755)
   if locked:
    (stage/'.ezr-launcher-lock').mkdir();(stage/'.ezr-launcher-lock/pid').write_text(str(os.getpid()))
   env=dict(os.environ,PATH=str(bin)+':/usr/bin:/bin:/usr/sbin:/sbin',FAKE_STATE=str(statefile))
   result=subprocess.run(['/bin/bash',str(stage/'start_mac.command'),'--gui-worker'],input=commands,text=True,capture_output=True,env=env,timeout=15)
   events=[]
   for p in (stage/'outputs').glob('runtime_*.jsonl'): events.extend(json.loads(x) for x in p.read_text().splitlines())
   self.assertNotIn('UNEXPECTED MOCK',result.stdout+result.stderr)
   return result,json.loads(statefile.read_text()),events
 def test_normal(self):
  r,s,e=self.run_case();self.assertEqual(r.returncode,0,r.stdout+r.stderr);self.assertEqual(s['down_n'],1);self.assertEqual(e[-1]['exit_code'],0)
 def test_pending_records(self):
  r,s,e=self.run_case({'exec':[2,0]},'stop\nstop\n');self.assertEqual(r.returncode,0,r.stdout+r.stderr);self.assertIn('WAIT_RECORDS',r.stdout);self.assertEqual(s['down_n'],1)
 def test_engine_error_is_not_pending_records(self):
  r,s,e=self.run_case({'exec':[125,0]},'stop\nstop\n');self.assertEqual(r.returncode,0);self.assertIn('STOP_FAILED',r.stdout);self.assertNotIn('WAIT_RECORDS',r.stdout)
 def test_failed_stop_can_retry(self):
  r,s,e=self.run_case({'down':[1,0]},'stop\nstop\n');self.assertEqual(r.returncode,0);self.assertIn('STOP_FAILED',r.stdout);self.assertEqual(s['down_n'],2);self.assertTrue(any(x.get('phase')=='container_stop_remove' and x.get('exit_code')==1 for x in e))
 def test_remaining_container_is_failure(self):
  r,s,e=self.run_case({'ps':[1,0]},'stop\nstop\n');self.assertEqual(r.returncode,0);self.assertIn('STOP_FAILED',r.stdout);self.assertEqual(s['down_n'],2)
 def test_closed_control_pipe_is_failure(self):
  r,s,e=self.run_case(commands='');self.assertEqual(r.returncode,1);self.assertNotIn('down_n',s);self.assertEqual(e[-1]['exit_code'],1)
 def test_duplicate_worker_does_not_touch_docker(self):
  r,s,e=self.run_case(locked=True);self.assertEqual(r.returncode,1);self.assertFalse(s.get('calls'))
 def test_forced_stop_skips_the_records_check(self):
  r,s,e=self.run_case({'exec':[2]},'stop\nforce-stop\n');self.assertEqual(r.returncode,0,r.stdout+r.stderr);self.assertIn('WAIT_RECORDS',r.stdout);self.assertEqual(s['exec_n'],1);self.assertEqual(s['down_n'],1);self.assertTrue(any(x.get('event')=='requested' and x.get('phase')=='forced_shutdown' for x in e))
 def test_address_is_shown(self):
  r,s,e=self.run_case();self.assertTrue(any('http://localhost:8877' in x and not x.startswith('EZR_UI') for x in r.stdout.splitlines()),r.stdout)
 def test_missing_container_skips_the_records_check(self):
  r,s,e=self.run_case({'running':[0]});self.assertEqual(r.returncode,0,r.stdout+r.stderr);self.assertNotIn('exec_n',s);self.assertEqual(s['down_n'],1);self.assertTrue(any(x.get('event')=='skipped' and x.get('phase')=='records_check' for x in e))
 def test_entry_removes_the_download_mark_only_in_its_folder(self):
  with tempfile.TemporaryDirectory(prefix='ezr-entry-test-') as d:
   root=pathlib.Path(d); stage=root/'日本語 space'; (stage/'projects'/'study').mkdir(parents=True); outside=root/'outside.txt'; outside.write_text('x')
   (stage/'launcher').mkdir();shutil.copy2(SOURCE/'launcher'/'start_messages.txt',stage/'launcher'/'start_messages.txt')
   shutil.copy2(SOURCE/'start_mac.command',stage/'start_mac.command'); inside=[stage/'start_mac.command',stage/'projects'/'study'/'data.csv']; inside[1].write_text('a\n')
   marked=lambda f: subprocess.run(['/usr/bin/xattr','-p','com.apple.quarantine',str(f)],capture_output=True).returncode==0
   for f in inside+[outside]: subprocess.run(['/usr/bin/xattr','-w','com.apple.quarantine','0083;00000000;Safari;',str(f)],check=True)
   r=subprocess.run(['/bin/bash',str(stage/'start_mac.command')],capture_output=True,text=True,timeout=15)
   self.assertEqual(r.returncode,1,r.stdout+r.stderr);self.assertIn('Start EZR.app',r.stderr)
   self.assertFalse(any(marked(f) for f in inside));self.assertTrue(marked(outside))
 def test_build_error_is_failure(self):
  r,s,e=self.run_case({'build_fail':True});self.assertEqual(r.returncode,1);self.assertNotIn('down_n',s)
if __name__=='__main__': unittest.main(verbosity=2)
