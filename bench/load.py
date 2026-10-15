#!/usr/bin/env python3
"""Separate-process, real TCP session load. Flat creative preview only; no survival TPS claims."""
import argparse, asyncio, json, math, os, pathlib, socket, struct, subprocess, tempfile, time, zlib, hashlib, platform, datetime
ROOT = pathlib.Path(__file__).resolve().parent.parent
PACKETS = json.loads((ROOT / 'priv/protocol/packets.json').read_text())
NAMES = {phase:{v['protocol_id']:k[10:] for k,v in directions.get('clientbound',{}).items()} for phase,directions in PACKETS.items()}
def packet_id(phase, direction, name):
    return PACKETS[phase][direction]['minecraft:' + name]['protocol_id']
def vi(n):
    n &= 0xffffffff
    out = bytearray()
    while n >= 128:
        out.append((n & 127) | 128); n >>= 7
    out.append(n)
    return bytes(out)
def text(s):
    b = s.encode(); return vi(len(b)) + b
def decode_vi(data, offset=0):
    value = 0
    for shift in range(0,35,7):
        b = data[offset]; offset += 1; value |= (b & 127) << shift
        if not b & 128: return value,offset
    raise ValueError('Invalid VarInt')
async def stream_vi(reader):
    value = 0
    for shift in range(0,35,7):
        b = (await reader.readexactly(1))[0]; value |= (b & 127) << shift
        if not b & 128: return value
    raise ValueError('Invalid VarInt')

class Client:
    def __init__(self, index, args):
        self.index = index; self.args = args; self.threshold = None
        self.chunks = 0; self.loaded = asyncio.Event(); self.received = 0; self.error = None
    async def send(self, phase, name, payload=b''):
        raw = vi(packet_id(phase,'serverbound',name)) + payload
        if self.threshold is None: body = raw
        elif len(raw) < self.threshold: body = b'\x00' + raw
        else: body = vi(len(raw)) + zlib.compress(raw)
        self.writer.write(vi(len(body))+body); await self.writer.drain()
    async def read(self, phase):
        length = await stream_vi(self.reader)
        data = await self.reader.readexactly(length)
        if self.threshold is not None:
            expected,offset = decode_vi(data)
            data = zlib.decompress(data[offset:]) if expected else data[offset:]
        pid,offset = decode_vi(data); self.received += 1
        name = NAMES[phase][pid]
        return name,data[offset:]
    async def login(self, port):
        started = time.perf_counter()
        self.reader,self.writer = await asyncio.open_connection('127.0.0.1',port)
        await self.send('handshake','intention',vi(777)+text('localhost')+struct.pack('>H',port)+b'\x02')
        await self.send('login','hello',text('Bench'+str(self.index))+bytes(16))
        while True:
            name,body = await self.read('login')
            if name=='login_compression': self.threshold,_=decode_vi(body)
            elif name=='login_finished': break
            elif name=='login_disconnect': raise RuntimeError('Login rejected')
        await self.send('login','login_acknowledged')
        while True:
            name,body = await self.read('configuration')
            if name=='select_known_packs': await self.send('configuration',name,body)
            elif name=='finish_configuration':
                await self.send('configuration',name); break
            elif name=='disconnect': raise RuntimeError('Configuration rejected')
        self.task = asyncio.create_task(self.pump())
        await asyncio.wait_for(self.loaded.wait(),10)
        self.login_ms=(time.perf_counter()-started)*1000
        return self
    async def pump(self):
        try:
            while True:
                name,body=await self.read('play')
                if name=='player_position':
                    pid,offset=decode_vi(body)
                    pos=body[offset:offset+24]; rotation=body[offset+48:offset+56]
                    await self.send('play','accept_teleportation',vi(pid)+pos+rotation)
                elif name=='chunk_batch_finished': await self.send('play','chunk_batch_received',struct.pack('>f',8))
                elif name=='level_chunk_with_light':
                    self.chunks+=1
                    if self.chunks>=9: self.loaded.set()
                elif name=='keep_alive': await self.send('play','keep_alive',body)
                elif name=='disconnect': raise RuntimeError('Server disconnected client')
        except (asyncio.IncompleteReadError,ConnectionError,RuntimeError) as error:
            self.error=type(error).__name__
    async def move(self, step):
        x=(self.index*128+64.5 if self.args.scatter else 0.5)+math.sin(step/8)*0.2
        z=64.5 if self.args.scatter else 0.5
        try:
            await self.send('play','move_player_pos',struct.pack('>dddB',x,64,z,1))
            await self.send('play','client_tick_end')
        except ConnectionError as error: self.error=type(error).__name__
    async def close(self):
        self.task.cancel(); self.writer.close()
        await self.writer.wait_closed()

async def benchmark(port,metrics,args):
    before=json.loads(metrics.read_text())
    semaphore=asyncio.Semaphore(16)
    async def join(i):
        async with semaphore: return await Client(i,args).login(port)
    clients=await asyncio.gather(*(join(i) for i in range(args.players)))
    await asyncio.sleep(0.15)
    loaded=json.loads(metrics.read_text())
    started=time.perf_counter(); moves=0
    try:
        for step in range(args.seconds*20):
            tick=time.perf_counter()
            active=[c for c in clients if c.error is None]
            await asyncio.gather(*(c.move(step) for c in active))
            moves+=len(active)
            await asyncio.sleep(max(0,0.05-(time.perf_counter()-tick)))
        after=json.loads(metrics.read_text())
        latencies=sorted(c.login_ms for c in clients)
        digest=hashlib.sha256()
        files=sorted(list((ROOT/'lib').rglob('*.ex'))+list((ROOT/'config').glob('*.exs'))+list((ROOT/'priv/protocol').glob('*.json')))
        for path in files: digest.update(str(path.relative_to(ROOT)).encode()+b'\0'+path.read_bytes())
        result={'measured_at_utc':datetime.datetime.now(datetime.timezone.utc).isoformat(),
                'platform':platform.platform(),'implementation_sha256':digest.hexdigest(),
                'elixir':'1.20.4','erlang_otp':'29.1.1','minecraft':'26.3','view_distance':1,
                'scenario':'spread' if args.scatter else 'dense','clients':len(clients),
                'disconnected':sum(c.error is not None for c in clients),'movement_packets_sent':moves,
                'client_tick_end_packets_sent':moves,
                'driver_sha256':hashlib.sha256(pathlib.Path(__file__).read_bytes()).hexdigest(),
                'duration_seconds':round(time.perf_counter()-started,3),
                'login_p50_ms':round(latencies[len(latencies)//2],2),
                'login_p95_ms':round(latencies[min(len(latencies)-1,int(len(latencies)*.95))],2),
                'server_before':before,'server_loaded':loaded,'server_after':after,
                'scope':'Separate Python load generator, loopback TCP, 9 flat spawn chunks, creative movement; no survival/AI/redstone workload.'}
        print(json.dumps(result,indent=2))
        if args.output:
            path=pathlib.Path(args.output);path.parent.mkdir(parents=True,exist_ok=True);path.write_text(json.dumps(result,indent=2)+'\n')
        if result['disconnected']: raise RuntimeError('Load disconnected clients')
    finally:
        await asyncio.gather(*(c.close() for c in clients),return_exceptions=True)

def main():
    parser=argparse.ArgumentParser()
    parser.add_argument('--players',type=int,default=128);parser.add_argument('--seconds',type=int,default=5)
    parser.add_argument('--scatter',action='store_true');parser.add_argument('--output')
    args=parser.parse_args()
    if not 1<=args.players<=512 or not 1<=args.seconds<=60: parser.error('Use 1–512 players and 1–60 seconds')
    with tempfile.TemporaryDirectory(prefix='valimc-load-') as temp:
        metrics=pathlib.Path(temp)/'metrics.json'
        with socket.socket() as probe:
            probe.bind(('127.0.0.1',0));port=probe.getsockname()[1]
        env=dict(os.environ,MIX_ENV='test',VALIMC_PORT=str(port),VALIMC_WORLD=temp,VALIMC_METRICS_FILE=str(metrics))
        log_path=pathlib.Path(temp)/'server.log'
        with log_path.open('w') as log:
            server=subprocess.Popen(['mix','run','bench/server.exs'],cwd=ROOT,env=env,stdin=subprocess.PIPE,stdout=log,stderr=subprocess.STDOUT)
            try:
                for _ in range(200):
                    if server.poll() is not None: raise RuntimeError(log_path.read_text())
                    if metrics.exists(): break
                    time.sleep(.05)
                asyncio.run(benchmark(port,metrics,args))
            finally:
                if server.poll() is None:
                    server.stdin.write(b'stop\n');server.stdin.flush()
                    try:server.wait(timeout=20)
                    except subprocess.TimeoutExpired:server.kill();server.wait()
                if server.returncode:print(log_path.read_text())
if __name__=='__main__':main()
