// drive.js — settle-based E2E driver for pos2.sol
const WebSocket = require('ws')
const ws = new WebSocket('ws://127.0.0.1:8084/ws')
let last = '', fails = 0, timer = null, step = 0
const has = (s) => last.includes(s)
const chk = (n, c) => { console.log((c ? 'ok ' : 'FAIL ') + n); if (!c) fails++ }
const send = (ev, val) => ws.send(JSON.stringify({ ev, val: String(val) }))

const steps = [
  () => { chk('login screen', has('Sign in to open the register') && has('hero-card')); send('register', 'sam pw123') },
  () => { chk('registered -> dashboard', has('navtab') && has('Current sale')); chk('cashier badge', has('sam')); send('buy', '0') },
  () => { chk('flat white x1', has('flat white') && has('x1')); send('buy', '0') },
  () => { chk('groups to x2 / $10', has('x2') && has('$10')); send('buy', '3') },
  () => { chk('total 16', has('Charge $16')); send('checkout', '') },
  () => { chk('cart cleared', has('Cart is empty')); chk('revenue banked', has('revenue $16')); send('tab', 'receipts') },
  () => { chk('receipts tab', has('1 sales, $16 all-time')); chk('receipt row', has('#1') && has('flat white, flat white, brownie')); send('tab', 'inventory') },
  () => { chk('inventory tab', has('Inventory') && has('restock')); chk('stock decremented', has('10 in stock')); send('restock', '0') },
  () => { chk('restocked to 20', has('20 in stock')); send('logout', '') },
  () => { chk('back to login', has('Sign in to open the register')); send('login', 'sam wrongpw') },
  () => { chk('wrong password note', has('wrong password')); send('login', 'sam pw123') },
  () => { chk('re-login + revenue persists', has('revenue $16')); done() },
]
function done() { console.log(fails ? 'DRIVER FAILURES' : 'DRIVER ALL GREEN'); process.exit(fails ? 1 : 0) }
function settle() { clearTimeout(timer); timer = setTimeout(() => { const f = steps[step++]; if (f) f() }, 600) }
ws.on('open', () => ws.send(JSON.stringify({ hello: null })))
ws.on('message', (d) => { last = d.toString(); settle() })
setTimeout(() => { console.log('TIMEOUT at step ' + step); process.exit(1) }, 40000)
