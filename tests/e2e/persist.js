// persist.js — after a restart WITHOUT wiping .solkv/.soldata:
// a brand-new session (second cashier) must see the shared store state.
const WebSocket = require('ws')
const ws = new WebSocket('ws://127.0.0.1:8084/ws')
let last = '', fails = 0, timer = null, step = 0
const has = (s) => last.includes(s)
const chk = (n, c) => { console.log((c ? 'ok ' : 'FAIL ') + n); if (!c) fails++ }
const send = (ev, val) => ws.send(JSON.stringify({ ev, val: String(val) }))
const steps = [
  () => { send('register', 'ana pw456') },
  () => {
    chk('second cashier sees banked revenue', has('revenue $16'))
    chk('sees ana badge', has('ana')); send('tab', 'receipts')
  },
  () => { chk('sees sam\'s receipt', has('1 sales, $16 all-time') && has('sam')); send('tab', 'inventory') },
  () => {
    chk('sees restocked=20 + decremented=11 stock', has('20 in stock') && has('11 in stock'))
    console.log(fails ? 'PERSIST FAILURES' : 'PERSIST ALL GREEN'); process.exit(fails ? 1 : 0)
  },
]
function settle() { clearTimeout(timer); timer = setTimeout(() => { const f = steps[step++]; if (f) f() }, 600) }
ws.on('open', () => ws.send(JSON.stringify({ hello: null })))
ws.on('message', (d) => { last = d.toString(); settle() })
setTimeout(() => { console.log('TIMEOUT at ' + step); process.exit(1) }, 25000)
