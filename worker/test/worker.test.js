import test from 'node:test';
import assert from 'node:assert/strict';
import worker from '../src/index.js';

const validPayload = {
  event: 'app_started',
  application: 'LinkScanner',
  version: '1.1.0',
};

function makeEnv({ allowed = true } = {}) {
  return {
    TELEGRAM_BOT_TOKEN: '12345678901234567890:TEST_TOKEN_VALUE',
    TELEGRAM_CHAT_ID: '123456789',
    NOTIFY_RATE_LIMITER: {
      async limit({ key }) {
        assert.equal(key, '203.0.113.10');
        return { success: allowed };
      },
    },
  };
}

function post(body, headers = {}) {
  return new Request('https://worker.test/api/notify', {
    method: 'POST',
    headers: {
      'content-type': 'application/json',
      'cf-connecting-ip': '203.0.113.10',
      ...headers,
    },
    body,
  });
}

test('health endpoint returns a minimal status without secrets', async () => {
  const response = await worker.fetch(
    new Request('https://worker.test/health'),
    makeEnv(),
  );
  assert.equal(response.status, 200);
  assert.deepEqual(await response.json(), {
    ok: true,
    service: 'LinkScanner notifier',
  });
});

test('unknown routes are rejected', async () => {
  const response = await worker.fetch(
    new Request('https://worker.test/other'),
    makeEnv(),
  );
  assert.equal(response.status, 404);
});

test('notification route rejects methods other than POST', async () => {
  const response = await worker.fetch(
    new Request('https://worker.test/api/notify', { method: 'GET' }),
    makeEnv(),
  );
  assert.equal(response.status, 405);
  assert.equal(response.headers.get('allow'), 'POST');
});

test('notification route requires JSON', async () => {
  const response = await worker.fetch(
    post('hello', { 'content-type': 'text/plain' }),
    makeEnv(),
  );
  assert.equal(response.status, 415);
});

test('malformed JSON is rejected', async () => {
  const response = await worker.fetch(post('{'), makeEnv());
  assert.equal(response.status, 400);
  assert.equal((await response.json()).error, 'invalid_json');
});

test('extra client-controlled message fields are rejected', async () => {
  const response = await worker.fetch(
    post(JSON.stringify({ ...validPayload, text: 'arbitrary text' })),
    makeEnv(),
  );
  assert.equal(response.status, 400);
  assert.equal((await response.json()).error, 'invalid_event');
});

test('oversized request bodies are rejected', async () => {
  const response = await worker.fetch(
    post(' '.repeat(1100)),
    makeEnv(),
  );
  assert.equal(response.status, 413);
});

test('rate-limited requests never reach Telegram', async () => {
  const originalFetch = globalThis.fetch;
  let telegramCalled = false;
  globalThis.fetch = async () => {
    telegramCalled = true;
    return new Response(JSON.stringify({ ok: true }), { status: 200 });
  };
  try {
    const response = await worker.fetch(
      post(JSON.stringify(validPayload)),
      makeEnv({ allowed: false }),
    );
    assert.equal(response.status, 429);
    assert.equal(telegramCalled, false);
  } finally {
    globalThis.fetch = originalFetch;
  }
});

test('valid event sends only a server-defined Telegram message', async () => {
  const originalFetch = globalThis.fetch;
  let capturedUrl;
  let capturedBody;
  globalThis.fetch = async (url, options) => {
    capturedUrl = String(url);
    capturedBody = JSON.parse(options.body);
    return new Response(JSON.stringify({ ok: true }), { status: 200 });
  };
  try {
    const response = await worker.fetch(
      post(JSON.stringify(validPayload)),
      makeEnv(),
    );
    assert.equal(response.status, 200);
    assert.deepEqual(await response.json(), { ok: true });
    assert.match(capturedUrl, /^https:\/\/api\.telegram\.org\/bot.*\/sendMessage$/);
    assert.equal(capturedBody.chat_id, '123456789');
    assert.equal(capturedBody.text, 'LinkScanner: app started\nVersion: 1.1.0\nEvent: app_started');
    assert.equal('parse_mode' in capturedBody, false);
  } finally {
    globalThis.fetch = originalFetch;
  }
});

test('Telegram failures are returned without exposing upstream details', async () => {
  const originalFetch = globalThis.fetch;
  globalThis.fetch = async () => new Response('private upstream error', { status: 500 });
  try {
    const response = await worker.fetch(
      post(JSON.stringify(validPayload)),
      makeEnv(),
    );
    assert.equal(response.status, 502);
    assert.deepEqual(await response.json(), { ok: false, error: 'upstream_rejected' });
  } finally {
    globalThis.fetch = originalFetch;
  }
});
