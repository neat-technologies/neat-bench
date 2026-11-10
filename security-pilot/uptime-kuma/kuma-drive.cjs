// Drive uptime-kuma's socket.io API like its UI does: first-run setup (only if
// needed), login, add an HTTP monitor (its pings are outbound CLIENT calls), and
// read lists back. Every call has a timeout; a fresh server can accept the
// websocket before its handlers are registered, so needSetup is retried first.
// Usage: node kuma-drive.cjs <kuma src dir> [port] [hold seconds]
const { io } = require(process.argv[2] + '/node_modules/socket.io-client')
const port = process.argv[3] || '3105'
const hold = Number(process.argv[4] || 45)
const s = io('http://127.0.0.1:' + port, { transports: ['websocket'] })
const call = (ev, ...a) => new Promise((res) => {
  const t = setTimeout(() => res('TIMEOUT'), 8000)
  s.emit(ev, ...a, (r) => { clearTimeout(t); res(r) })
})
const log = (k, v) => console.log(k, JSON.stringify(v).slice(0, 150))
s.on('connect', async () => {
  let need = 'TIMEOUT'
  for (let i = 0; i < 10 && need === 'TIMEOUT'; i++) need = await call('needSetup')
  log('needSetup', need)
  if (need === true) log('setup', await call('setup', 'admin', 'changeme'))
  log('login', await call('login', { username: 'admin', password: 'changeme', token: '' }))
  log('add', await call('add', {
    type: 'http', name: 'example', url: 'https://example.com', method: 'GET', interval: 20, retryInterval: 20,
    maxretries: 0, timeout: 10, accepted_statuscodes: ['200-299'], notificationIDList: {}, ignoreTls: false,
    upsideDown: false, expiryNotification: false, maxredirects: 10, dns_resolve_type: 'A',
    dns_resolve_server: '1.1.1.1', kafkaProducerBrokers: [], kafkaProducerSaslOptions: { mechanism: 'None' }, conditions: [],
  }))
  log('getSettings', await call('getSettings'))
  log('getTags', await call('getTags'))
  log('getMonitorChartData', await call('getMonitorChartData', 1, 24))
  setTimeout(() => process.exit(0), hold * 1000)
})
s.on('connect_error', (e) => { console.error('connect_error', e.message); process.exit(1) })
