"""Observe Apple's external CI check without storing Apple credentials in GitHub."""
import json, os, subprocess, time
repo=os.environ['GITHUB_REPOSITORY'];sha=os.environ['SOURCE_COMMIT']
assert repo=='shaoyou11/Aidoku' and len(sha)==40 and all(c in '0123456789abcdef' for c in sha)
context='Aidoku | AidokuT 内部 TestFlight'
deadline=time.monotonic()+1800;last=None
while time.monotonic()<deadline:
    result=subprocess.run(['gh','api',f'repos/{repo}/commits/{sha}/status'],capture_output=True,text=True,check=True)
    data=json.loads(result.stdout)
    status=next((s for s in data.get('statuses',[]) if s.get('context')==context),None)
    state=status.get('state') if status else 'waiting-for-cloud'
    if state!=last:print('Xcode Cloud:',state,flush=True);last=state
    if state=='success':
        print('Cloud流程已成功；家庭内部组沿用已启用的自动分发配置。');break
    if state in ('error','failure'):raise SystemExit('Xcode Cloud 未通过，停止本次发布验收。')
    time.sleep(30)
else:raise SystemExit('30分钟内未确认云端流程完成；请检查Cloud状态，不能视为已发布。')
