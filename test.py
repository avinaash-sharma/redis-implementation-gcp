import asyncio, json, os, urllib.request, websockets, redis
aud = os.environ.get('WS_TOKEN_AUDIENCE')
print('audience:', aud)
req = urllib.request.Request(
    'http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/identity?audience=' + aud,
    headers={'Metadata-Flavor': 'Google'})
tok = urllib.request.urlopen(req).read().decode()
async def m():
    async with websockets.connect(f'ws://localhost:8080/ws?conversation_id=t1&token={tok}') as ws:
        print('joined:', await ws.recv())
        r = redis.Redis(host='100.72.86.38', decode_responses=True)
        sid = r.get('conv-t1'); print('server_id:', sid)
        r.publish(f'{sid}:t1', json.dumps({'type':'test','text':'hello'}))
        print('received:', await asyncio.wait_for(ws.recv(), 5))
asyncio.run(m())
